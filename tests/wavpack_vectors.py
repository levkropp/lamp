"""Test-only WavPack stream writer.

FFmpeg's WavPack encoder writes lossless blocks only: it never sends hybrid
(lossy) data, integer extra bits, the "ones" and "duplicate" shifts, blocks
without decorrelation, custom sample rates or extended channel information,
so tests/verify-wavpack.py also decodes streams written here. The writer
drives the decoder model (tests/wavpack_model.py) with readers that choose
every value they are asked for and record the bits: residuals, zero runs,
error-limit bisections, extra bits and float details are random within the
limits a valid stream keeps, while the history, medians and error limits
evolve as the model computes them, and the CRCs it computes are set in the
block headers. Block metadata (terms, weights, history, medians, bit rates,
shifts) comes from the caller or random_spec().
"""
import math
import random
import struct

import wavpack_model as model

STEREO_TERMS = [1, 2, 3, 4, 5, 6, 7, 8, 17, 18, -1, -2, -3]
MONO_TERMS = [1, 2, 3, 4, 5, 6, 7, 8, 17, 18]
ID_TERMS, ID_WEIGHTS, ID_SAMPLES, ID_ENTROPY, ID_HYBRID = 2, 3, 4, 5, 6
ID_FLOAT, ID_INT32, ID_DATA, ID_EXTRA, ID_CHANNELS, ID_RATE = 8, 9, 0xa, 0xc, 0xd, 0x27


class Writer(model.Bits):
    """A reader that picks each value it is asked for and records the bits
    (least significant first). For the residual stream it codes the value
    that brings the decoded sample to its target, as far as the medians and
    the holding state allow; extra bits and float details are random."""

    def __init__(self, r, owner, residuals):
        super().__init__(b'')
        self.r = r
        self.owner = owner
        self.residuals = residuals
        self.out = []
        self.d = 0
        self.bisect = None

    def left(self):
        return 1 << 30

    def _put(self, value, n):
        for k in range(n):
            self.out.append(value >> k & 1)
        self.pos += n

    def bit(self, label=None):
        v = self.choose(1, label)
        self._put(v, 1)
        return v

    def get(self, n, label=None):
        v = self.choose(n, label)
        assert 0 <= v < (1 << n) or n == 0, (label, v, n)
        self._put(v, n)
        return v

    def unary(self, label=None):
        n = self.count(label)
        self._put((1 << n) - 1, n)
        if n < 33:
            self._put(0, 1)
        return n

    def want(self, b, channel):
        """Called as each residual is decoded: the value that makes the
        decoded sample (before joint stereo) equal the target."""
        o = self.owner
        s16 = o.fmt == 's16'
        if channel == 0:
            o.advance()
        tl, tr = o.target
        if b.stereo_in:
            # Cross-channel terms make each channel's sample depend a little
            # on the other residual: a few fixed-point rounds solve for both.
            lo, ro = (tl - tr, tr + ((tl - tr) >> 1)) if b.joint else (tl, tr)
            left, right = (0, 0) if channel == 0 else (b.current, 0)
            for _ in range(4):
                if channel == 0:
                    left = clamp(lo - (predict_stereo(b, left, right, s16)[0] - left))
                right = clamp(ro - (predict_stereo(b, left, right, s16)[1] - right))
            d = left if channel == 0 else right
        else:
            d = tl - predict_mono(b, s16)
        self.d = model.i32(d)
        self.m = magnitude(self.d)
        # The next value: this sample's right residual, else (the next
        # sample's left, or mono) about the size of this one.
        if b.stereo_in and channel == 0:
            self.next = magnitude(right), (b.ch[1].median[0] >> 4) + 1
        else:
            self.next = self.m, (b.ch[0].median[0] >> 4) + 1
        self.med = [(x >> 4) + 1 for x in b.ch[channel].median]
        self.one = b.one
        self.t = 0
        self.bisect = None

    def range_of(self, t):
        m0, m1, m2 = self.med
        if t == 0:
            return 0, m0 - 1
        if t == 1:
            return m0, m1 - 1
        return m0 + m1 + m2 * (t - 2), m2 - 1

    def count(self, label):
        r, o = self.r, self.owner
        if label == 'zeros':                           # both medians are tiny
            if self.d == 0 and r.random() < o.policy.get('runs', 0.5):
                return r.randint(1, 7)
            return 0
        if label == 'ones_escape':
            e = self.escape
            if e < 2:
                return e
            self.escape_bits = e - (1 << (e.bit_length() - 1))
            return e.bit_length()
        m0, m1, m2 = self.med
        m = self.m
        if m < m0:
            t = 0
        elif m < m0 + m1:
            t = 1
        else:
            t = 2 + (m - m0 - m1) // max(m2, 1)
        t = min(t, 2 + ((1 << 31) - m0 - m1) // max(m2, 1) - 1)
        # The low bit holds a one when the next value may be nonzero; a held
        # zero forces it below its first median, so err towards the one.
        size, first = self.next
        nxt = int(size >= max(first // 2, 1))
        if self.one:
            t = max(t, 1)
            raw = (t - 1) * 2 + nxt
        else:
            raw = t * 2 + nxt
        self.t = t
        if raw >= 16:
            self.escape = raw - 16
            assert self.escape < 1 << 31
            return 16
        return raw

    def choose(self, n, label):
        r = self.r
        if not self.residuals or label in ('zeros_bits',):
            return r.getrandbits(n) if n else 0
        if label == 'ones_bits':
            return self.escape_bits
        if label == 'tail':
            base, add = self.range_of(self.t)
            tail = min(max(self.m - base, 0), add)
            p = add.bit_length() - 1
            e = (1 << (p + 1)) - add - 1
            self.tail_bit = None
            if tail < e:
                return tail
            self.tail_bit = (tail + e) & 1
            return (tail + e) >> 1
        if label == 'tail_bit':
            return self.tail_bit
        if label == 'bisect':
            if self.bisect is None:
                base, add = self.range_of(self.t)
                self.bisect = [base & 0xffffffff, add & 0xffffffff]
            base, add = self.bisect
            mid = ((base * 2 + add + 1) & 0xffffffff) >> 1
            v = int(self.m >= mid)
            if v:
                self.bisect = [mid, (add - (mid - base)) & 0xffffffff]
            else:
                self.bisect = [base, (mid - base - 1) & 0xffffffff]
            return v
        if label == 'sign':
            return int(self.d < 0)
        raise AssertionError(label)

    def payload(self):
        data = bytearray((len(self.out) + 7) // 8)
        for i, v in enumerate(self.out):
            data[i >> 3] |= v << (i & 7)
        return bytes(data)


def magnitude(d):
    return min(d if d >= 0 else -d - 1, 1 << 29)


def clamp(v):
    return max(min(model.i32(v), 1 << 30), -(1 << 30))


def predict_stereo(b, L, R, s16):
    """Samples after decorrelation for residuals L and R, without changing
    the block's state (the model's unpack_stereo, read only)."""
    pos = b.pos
    for d in b.decorr:
        t = d.value
        if t > 0:
            if t > 8:
                if t & 1:
                    A = model.i32(2 * d.samplesA[0] - d.samplesA[1])
                    B = model.i32(2 * d.samplesB[0] - d.samplesB[1])
                else:
                    A = model.i32(3 * d.samplesA[0] - d.samplesA[1]) >> 1
                    B = model.i32(3 * d.samplesB[0] - d.samplesB[1]) >> 1
            else:
                A, B = d.samplesA[pos], d.samplesB[pos]
            L = model._apply(d.weightA, A, L, s16)
            R = model._apply(d.weightB, B, R, s16)
        elif t == -1:
            L = model._apply(d.weightA, d.samplesA[0], L, s16)
            R = model._apply(d.weightB, L, R, s16)
        else:
            R = model._apply(d.weightB, d.samplesB[0], R, s16)
            R2 = d.samplesA[0] if t == -3 else R
            L = model._apply(d.weightA, R2, L, s16)
    return L, R


def predict_mono(b, s16):
    S = 0
    pos = b.pos
    for d in b.decorr:
        t = d.value
        if t > 8:
            if t & 1:
                A = model.i32(2 * d.samplesA[0] - d.samplesA[1])
            else:
                A = model.i32(3 * d.samplesA[0] - d.samplesA[1]) >> 1
        else:
            A = d.samplesA[pos]
        S = model._apply(d.weightA, A, S, s16)
    return S


class Readers:
    """The writer's residual and extra-bit readers and the target signal:
    two sines and noise per channel, with silent stretches."""

    def __init__(self, r, fmt, policy):
        self.r = r
        self.fmt = fmt
        self.policy = policy
        self.block = None
        self.data = Writer(r, self, True)
        self.extra = Writer(r, self, False)
        self.amplitude = policy['amplitude']
        self.tones = [[(r.uniform(0.002, 0.2), r.uniform(0, 6.3), r.uniform(0.2, 0.6)) for _ in range(2)]
                      for _ in range(2)]
        self.n = 0
        self.silent = 0
        self.target = (0, 0)

    def advance(self):
        r, a = self.r, self.amplitude
        self.n += 1
        if self.silent:
            self.silent -= 1
            self.target = (0, 0)
            return
        if r.random() < self.policy.get('silence', 0.002):
            self.silent = r.randint(100, 600)
        values = []
        for tones in self.tones:
            v = sum(g * math.sin(f * self.n + phase) for f, phase, g in tones) + r.uniform(-0.2, 0.2)
            values.append(int(a * v))
        self.target = tuple(values)


def subblock(ident, payload, long=False):
    """Sub-block with its id, word count (24-bit when long) and padding."""
    size = len(payload)
    words = (size + 1) // 2
    head = ident | (0x40 if size & 1 else 0)
    if long or words > 255:
        out = bytes([head | 0x80, words & 0xff, words >> 8 & 0xff, words >> 16 & 0xff])
    else:
        out = bytes([head, words])
    return out + payload + (b'\0' if size & 1 else b'')


def words(values):
    return struct.pack(f'<{len(values)}H', *[v & 0xffff for v in values])


def history_words(r, terms, stereo_in, low, high):
    """DECSAMPLES words for each term, in the order the decoder reads them
    (last term first)."""
    out = []
    for value, _ in reversed(terms):
        if value > 8:
            n = 4 if stereo_in else 2
        elif value < 0:
            n = 2
        else:
            n = value * (2 if stereo_in else 1)
        out += [r.choice((1, -1)) * r.randint(low, high) for _ in range(n)]
    return out


def random_spec(r, stereo=True, false_stereo=False, bytes_=2, float_=False, hybrid=False, bitrate=False,
                terms=None, delta=3, int32=None, float_info=None, extra=False, shift=0, joint=None):
    """Block metadata chosen at random within stable limits: weights within
    about +-0.3, moderate history and medians, small adaptation steps."""
    stereo_in = stereo and not false_stereo
    if terms is None:
        choices = STEREO_TERMS if stereo_in else MONO_TERMS
        terms = [(r.choice(choices), r.randint(0, delta)) for _ in range(r.randint(1, 16))]
    s32 = bytes_ > 2 or float_
    spec = dict(stereo=stereo, false_stereo=false_stereo, bytes=bytes_, float=float_, shift=shift,
                joint=r.random() < 0.5 if joint is None else joint, terms=terms,
                weights=[(r.randint(-40, 40), r.randint(-40, 40)) for _ in terms],
                history=history_words(r, terms, stereo_in, 0, 0x0c00 if s32 else 0x0900),
                entropy=[r.randint(0x0500, 0x0e00 if s32 else 0x0a00) for _ in range(6 if stereo_in else 3)],
                int32=int32, float_info=float_info, extra=extra, hybrid=None)
    if hybrid:
        channels = 2 if stereo_in else 1
        spec['hybrid'] = dict(bitrate=bitrate,
                              slow=[r.randint(0x0800, 0x1200) for _ in range(channels)] if bitrate else [],
                              acc=[r.randint(0x0100, 0x0900) for _ in range(channels)],
                              delta=[r.randint(0x0100, 0x0b00) for _ in range(channels)]
                              if r.random() < 0.7 else None)
    return spec


def block_flags(spec, rate_code):
    flags = (spec['bytes'] - 1) | (spec.get('shift', 0) << 13) | (rate_code << 23)
    if not spec['stereo']:
        flags |= model.MONO
    if spec['false_stereo']:
        flags |= model.FALSE_STEREO
    if spec['joint']:
        flags |= model.JOINT
    if spec['float']:
        flags |= model.FLOAT
    if spec['int32']:
        flags |= model.INT32
    if spec['hybrid']:
        flags |= model.HYBRID
        if spec['hybrid']['bitrate']:
            flags |= model.HYBRID_BITRATE
    return flags | spec.get('extra_flags', 0)


def metadata(spec):
    """Sub-blocks before the bit streams, as (id, payload)."""
    stereo_in = spec['stereo'] and not spec['false_stereo']
    terms = spec['terms']
    out = [(ID_TERMS, bytes(((v + 5) & 0x1f) | d << 5 for v, d in reversed(terms)))]
    weight_bytes = bytearray()
    for a, b in reversed(spec['weights']):
        weight_bytes.append(a & 0xff)
        if stereo_in:
            weight_bytes.append(b & 0xff)
    out.append((ID_WEIGHTS, bytes(weight_bytes)))
    out.append((ID_SAMPLES, words(spec['history'])))
    out.append((ID_ENTROPY, words(spec['entropy'])))
    if spec['hybrid']:
        h = spec['hybrid']
        out.append((ID_HYBRID, words(h['slow'] + h['acc'] + (h['delta'] or []))))
    if spec['int32']:
        out.append((ID_INT32, bytes(spec['int32'])))
    if spec['float_info']:
        out.append((ID_FLOAT, bytes(list(spec['float_info']) + [0])))
    if spec.get('channel_info') is not None:
        out.append((ID_CHANNELS, bytes(spec['channel_info'])))
    if spec.get('rate') is not None:
        out.append((ID_RATE, spec['rate'].to_bytes(3, 'little')))
    out += spec.get('unknown', [])
    return out


def encode_block(r, spec, samples, flags, policy):
    """-> (body, CRC, decoded channels, model block) for one block."""
    meta = metadata(spec)
    fmt = model.sample_format(flags)
    placeholder = b''.join(subblock(i, p) for i, p in meta) + subblock(ID_DATA, b'\0\0')
    if spec['extra']:
        placeholder += subblock(ID_EXTRA, bytes(6))
    # Targets at about a third of full scale of the coded values (before
    # the INT32INFO and header shifts).
    bits = 24 if spec['float'] else ((flags & 3) + 1) * 8
    bits -= (flags >> 13 & 0x1f) + (max(spec['int32'][1:]) if spec['int32'] else 0)
    policy = dict(policy, amplitude=policy.get('amplitude', 1 << max(min(bits, 24) - 3, 2)))
    readers = Readers(r, fmt, policy)
    out, b = model.decode_block(samples, flags, 0, placeholder, fmt, readers)
    long = spec.get('long', False)
    body = b''.join(subblock(i, p, long) for i, p in meta)
    body += subblock(ID_DATA, readers.data.payload(), long)
    if spec['extra']:
        body += subblock(ID_EXTRA, struct.pack('<I', b.crc_extra) + readers.extra.payload(), long)
    # The written block decodes, CRCs included, to the same samples.
    check, _ = model.decode_block(samples, flags, b.crc_value, body, fmt)
    assert check == out
    return body, b.crc_value, out, b


def header(body, version, index, total, samples, flags, crc):
    return (b'wvpk' + struct.pack('<IHBBIIIII', len(body) + 24, version, index >> 32 & 0xff, total >> 32 & 0xff,
                                  total & 0xffffffff, index & 0xffffffff, samples, flags, crc) + body)


def stream(seed, frames, rate_code=9, version=0x410, policy=None):
    """frames: list of (samples, [block spec, ...]); a frame's first block is
    initial and its last final. -> (.wv bytes, the presented channels as
    FFmpeg's float32 output, channel count, coverage tags)."""
    r = random.Random(seed)
    policy = policy or {}
    total = sum(n for n, _ in frames)
    out = bytearray()
    pcm, used, channels, index = [], set(), None, 0
    for samples, specs in frames:
        decoded = []
        for k, spec in enumerate(specs):
            flags = block_flags(spec, rate_code)
            if k == 0:
                flags |= model.INITIAL
            if k == len(specs) - 1:
                flags |= model.FINAL
            body, crc, chans, b = encode_block(r, spec, samples, flags, policy.get(model.sample_format(flags), policy))
            used |= b.used
            decoded.append((chans, model.sample_format(flags)))
            out += header(body, version, index, total, samples, flags, crc)
        count = specs[0].get('channels', sum(len(c) for c, _ in decoded))
        channels = channels or count
        present = [(c, fmt) for chans, fmt in decoded for c in chans][:count]
        pcm.append(model.present([c for c, _ in present], present[0][1]))
        index += samples
    return bytes(out), b''.join(pcm), channels, used
