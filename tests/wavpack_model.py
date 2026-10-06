"""Test-only WavPack decoder model.

Mirrors FFmpeg 6.1's WavPack decoder (lossless, hybrid lossy, float, extra
bits, shifts, false stereo and multichannel blocks), the reference for
tests/verify-wavpack.py. Bit reads carry labels so the stream writer
(tests/wavpack_vectors.py) can drive the same code with chosen values.
The exp2/log2 tables are formula-derived as in src/wavpack.s.
"""
import math
import struct

MONO, HYBRID, JOINT, CROSS, SHAPE, FLOAT, INT32 = 4, 8, 0x10, 0x20, 0x40, 0x80, 0x100
HYBRID_BITRATE, HYBRID_BALANCE, INITIAL, FINAL = 0x200, 0x400, 0x800, 0x1000
FALSE_STEREO, DSD = 0x40000000, 0x80000000
RATES = [6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000]
EXP2 = [round(256 * 2 ** (i / 256)) - 256 for i in range(256)]
LOG2 = [round(256 * math.log2(1 + i / 256)) for i in range(256)]
# A value above 255 in LOG2[255] would not fit a byte; the formula gives 255.
assert max(EXP2) <= 255 and max(LOG2) <= 255


class DecodeError(Exception):
    pass


def i32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v


def wp_exp2(val):
    """FFmpeg wp_exp2 of a signed 16-bit value (the argument is int16_t)."""
    val &= 0xffff
    val = val - 0x10000 if val & 0x8000 else val
    neg = val < 0
    if neg:
        val = -val
    res = EXP2[val & 0xff] | 0x100
    val >>= 8
    if val > 31:
        return -(1 << 31)
    res = res << (val - 9) if val > 9 else res >> (9 - val)
    return i32(-res if neg else res)


def wp_log2(val):
    val &= 0xffffffff
    if not val:
        return 0
    if val == 1:
        return 256
    val += val >> 9
    val &= 0xffffffff
    bits = val.bit_length()
    if bits < 9:
        return (bits << 8) + LOG2[(val << (9 - bits)) & 0xff]
    return (bits << 8) + LOG2[(val >> (bits - 9)) & 0xff]


def level_decay(a):
    return (a + 0x80) >> 8


class Bits:
    """LSB-first reader (WavPack bitstreams). get(n, label) for the writer."""

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.size = len(data) * 8

    def left(self):
        return self.size - self.pos

    def bit(self, label=None):
        byte = self.pos >> 3
        value = (self.data[byte] >> (self.pos & 7)) & 1 if byte < len(self.data) else 0
        self.pos += 1
        return value

    def get(self, n, label=None):
        value = 0
        for k in range(n):
            value |= self.bit(label) << k
        return value

    def unary(self, label=None):
        """FFmpeg get_unary_0_33: ones before a zero, at most 33."""
        n = 0
        while n < 33 and self.bit(label):
            n += 1
        return n


class Channel:
    def __init__(self):
        self.median = [0, 0, 0]
        self.slow_level = 0
        self.bitrate_acc = 0
        self.bitrate_delta = 0
        self.error_limit = 0


class Decorr:
    def __init__(self):
        self.value = 0
        self.delta = 0
        self.weightA = 0
        self.weightB = 0
        self.samplesA = [0] * 8
        self.samplesB = [0] * 8


class Block:
    """One block's decoding context (FFmpeg WavpackFrameContext)."""

    def __init__(self, flags, samples):
        self.flags = flags
        self.samples = samples
        self.stereo = not flags & MONO
        self.stereo_in = 0 if flags & FALSE_STEREO else int(self.stereo)
        self.joint = flags & JOINT
        self.hybrid = flags & HYBRID
        self.hybrid_bitrate = flags & HYBRID_BITRATE
        self.decorr = []
        self.ch = [Channel(), Channel()]
        self.extra_bits = 0
        self.and_ = self.or_ = self.shift = 0
        self.got_extra_bits = False
        self.float_flag = self.float_shift = self.float_max_exp = 0
        self.one = self.zero = self.zeroes = 0
        self.used = set()

    # Entropy decoding (FFmpeg wv_get_value).
    def get_value(self, g, channel):
        c = self.ch[channel]
        if hasattr(g, 'want'):                         # the stream writer
            g.want(self, channel)
        if self.ch[0].median[0] < 2 and self.ch[1].median[0] < 2 and not self.zero and not self.one:
            if self.zeroes:
                self.zeroes -= 1
                if self.zeroes:
                    c.slow_level -= level_decay(c.slow_level)
                    return 0, False
            else:
                t = g.unary('zeros')
                if t >= 2:
                    if t >= 32 or g.left() < t - 1:
                        return 0, True
                    t = g.get(t - 1, 'zeros_bits') | (1 << (t - 1))
                elif g.left() < 0:
                    return 0, True
                self.zeroes = t
                if self.zeroes:
                    self.used.add('zero run')
                    self.ch[0].median = [0, 0, 0]
                    self.ch[1].median = [0, 0, 0]
                    c.slow_level -= level_decay(c.slow_level)
                    return 0, False
        if self.zero:
            t = 0
            self.zero = 0
        else:
            t = g.unary('ones')
            if g.left() < 0:
                return 0, True
            if t == 16:
                self.used.add('escaped ones')
                t2 = g.unary('ones_escape')
                if t2 < 2:
                    if g.left() < 0:
                        return 0, True
                    t += t2
                else:
                    if t2 >= 32 or g.left() < t2 - 1:
                        return 0, True
                    t += g.get(t2 - 1, 'ones_bits') | (1 << (t2 - 1))
            if self.one:
                self.one = t & 1
                t = (t >> 1) + 1
            else:
                self.one = t & 1
                t >>= 1
            self.zero = int(not self.one)
        if self.hybrid and not channel:
            if not self.update_error_limit():
                return 0, True

        def med(n):
            return (c.median[n] >> 4) + 1

        def div(a, d):                                 # C division of an int
            a = i32(a)
            return -(-a // d) if a < 0 else a // d

        def dec(n):
            d = 128 >> n
            c.median[n] = i32(c.median[n] - div(c.median[n] + d - 2, d) * 2)

        def inc(n):
            d = 128 >> n
            c.median[n] = i32(c.median[n] + div(c.median[n] + d, d) * 5)

        if t == 0:
            base, add = 0, med(0) - 1
            dec(0)
        elif t == 1:
            base, add = med(0), med(1) - 1
            inc(0)
            dec(1)
        else:
            base = med(0) + med(1)
            inc(0)
            inc(1)
            if t == 2:
                add = med(2) - 1
                dec(2)
            else:
                base += med(2) * (t - 2)
                add = med(2) - 1
                inc(2)
        base &= 0xffffffff
        add &= 0xffffffff
        if not c.error_limit:
            if add >= 0x2000000:
                return 0, True
            ret = (base + self.tail(g, add)) & 0xffffffff
            if g.left() <= 0:
                return 0, True
        else:
            self.used.add('error limit')
            mid = ((base * 2 + add + 1) & 0xffffffff) >> 1
            while i32(add) > i32(c.error_limit):          # signed in FFmpeg
                if g.left() <= 0:
                    return 0, True
                if g.bit('bisect'):
                    add = (add - (mid - base)) & 0xffffffff
                    base = mid
                else:
                    add = (mid - base - 1) & 0xffffffff
                mid = ((base * 2 + add + 1) & 0xffffffff) >> 1
            ret = mid
        sign = g.bit('sign')
        if self.hybrid_bitrate:
            c.slow_level = i32(c.slow_level + wp_log2(ret) - level_decay(c.slow_level))
        ret = i32(ret)
        return (~ret if sign else ret), False

    @staticmethod
    def tail(g, k):
        if k < 1:
            return 0
        p = k.bit_length() - 1
        e = (1 << (p + 1)) - k - 1
        res = g.get(p, 'tail')
        if res >= e:
            res = (res << 1) - e + g.bit('tail_bit')
        return res

    def update_error_limit(self):
        br, sl = [0, 0], [0, 0]
        for i in range(self.stereo_in + 1):
            c = self.ch[i]
            if c.bitrate_acc > 0xffffffff - c.bitrate_delta:
                return False
            c.bitrate_acc += c.bitrate_delta
            br[i] = c.bitrate_acc >> 16
            sl[i] = level_decay(c.slow_level)
        if self.stereo_in and self.hybrid_bitrate:
            balance = (sl[1] - sl[0] + br[1] + 1) >> 1
            if balance > br[0]:
                br[1] = br[0] * 2
                br[0] = 0
            elif -balance > br[0]:
                br[0] *= 2
                br[1] = 0
            else:
                br[1] = br[0] + balance
                br[0] = br[0] - balance
        for i in range(self.stereo_in + 1):
            c = self.ch[i]
            if self.hybrid_bitrate:
                c.error_limit = wp_exp2(sl[i] - br[i] + 0x100) if sl[i] - br[i] > -0x100 else 0
            else:
                c.error_limit = wp_exp2(br[i])
            c.error_limit &= 0xffffffff
        return True

    # Output conversion.
    def integer(self, extra, S):
        S &= 0xffffffff
        if self.extra_bits:
            S = (S << self.extra_bits) & 0xffffffff
            if self.got_extra_bits and extra.left() >= self.extra_bits:
                S |= extra.get(self.extra_bits, 'extra')
                self.crc_extra = (self.crc_extra * 9 + (S & 0xffff) * 3 + (S >> 16)) & 0xffffffff
        bit = (S & self.and_) | self.or_
        bit = ((((S + bit) & 0xffffffff) << self.shift) - bit) & 0xffffffff
        if self.hybrid:
            bit = min(max(i32(bit), self.minclip), self.maxclip) & 0xffffffff
        return i32((bit << self.post_shift) & 0xffffffff)

    def float_value(self, extra, S):
        exp = self.float_max_exp
        if self.got_extra_bits:
            if extra.left() + 8 * 64 < 1 + 23 + 8 + 1:
                return 0
        if S:
            S = (S << self.float_shift) & 0xffffffff
            S = i32(S)
            sign = S < 0
            if sign:
                S = (-S) & 0xffffffff
            if S >= 0x1000000:
                self.used.add('float beyond 24 bits')
                S = extra.get(23, 'float_big') if self.got_extra_bits and extra.bit('float_big_flag') else 0
                exp = 255
            elif exp:
                shift = 23 - max(S.bit_length() - 1, 0)   # av_log2(0) = 0
                exp = self.float_max_exp
                if exp <= shift:
                    exp -= 1
                    shift = exp
                exp -= shift
                if shift:
                    S = (S << shift) & 0xffffffff
                    if self.float_flag & 1:
                        self.used.add('float shift with ones')
                    elif self.got_extra_bits and self.float_flag & 2:
                        self.used.add('float shift with the same bits')
                    elif self.got_extra_bits and self.float_flag & 4:
                        self.used.add('float shift with sent bits')
                    if (self.float_flag & 1) or (self.got_extra_bits and self.float_flag & 2 and extra.bit('shift_same')):
                        S |= (1 << shift) - 1
                    elif self.got_extra_bits and self.float_flag & 4:
                        S |= extra.get(shift, 'shift_sent')
            else:
                exp = self.float_max_exp
            S &= 0x7fffff
        else:
            sign = 0
            exp = 0
            if self.got_extra_bits and self.float_flag & 8:
                self.used.add('float zeros sent')
                if extra.bit('zero_flag'):
                    S = extra.get(23, 'zero_mant')
                    if self.float_max_exp >= 25:
                        exp = extra.get(8, 'zero_exp')
                    sign = extra.bit('zero_sign')
                elif self.float_flag & 0x10:
                    sign = extra.bit('zero_sign')
        self.crc_extra = (self.crc_extra * 27 + S * 9 + exp * 3 + int(sign)) & 0xffffffff
        return (int(sign) << 31) | (exp << 23) | S          # the float's bits


def subblocks(data):
    """(id, payload) for each metadata sub-block of a block body."""
    pos = 0
    while pos < len(data):
        if pos + 2 > len(data):
            break
        ident, size = data[pos], data[pos + 1]
        pos += 2
        if ident & 0x80:
            if pos + 2 > len(data):
                break
            size |= (data[pos] | data[pos + 1] << 8) << 8
            pos += 2
        size <<= 1
        ssize = size
        if ident & 0x40:
            size -= 1
        if size < 0 or len(data) - pos < ssize:
            break
        yield ident & 0x3f, data[pos:pos + size], ident
        pos += ssize


def decode_block(header_samples, flags, crc, body, sample_fmt, readers=None):
    """One block -> (channels: list of int lists or float lists, block).
    readers (the stream writer's) replaces the DATA and EXTRABITS readers
    after the sub-blocks are parsed; the CRCs are then computed, not
    checked (block.crc_value, block.crc_extra)."""
    b = Block(flags, header_samples)
    b.crc_expected = crc
    b.check = readers is None
    bpp = 4 if sample_fmt != 's16' else 2
    if sample_fmt == 'flt':
        bpp = 4
    orig_bpp = ((flags & 3) + 1) * 8
    b.post_shift = bpp * 8 - orig_bpp + ((flags >> 13) & 0x1f)
    if not 0 <= b.post_shift <= 31:
        raise DecodeError('post shift')
    b.maxclip = (1 << (orig_bpp - 1)) - 1
    b.minclip = -(1 << (orig_bpp - 1))
    got = set()
    data = extra = None
    for ident, payload, raw_id in subblocks(body):
        size = len(payload)
        if ident == 2:
            if size > 16:
                b.decorr = []
                continue
            b.decorr = [Decorr() for _ in range(size)]
            for i in range(size):
                v = payload[i]
                b.decorr[size - i - 1].value = (v & 0x1f) - 5
                b.decorr[size - i - 1].delta = v >> 5
            got.add('terms')
            b.used.update(f'term {d.value}' for d in b.decorr)
        elif ident == 3:
            if 'terms' not in got:
                continue
            weights = size >> b.stereo_in
            if weights > 16 or weights > len(b.decorr):
                continue
            p = 0
            for i in range(weights):
                d = b.decorr[len(b.decorr) - i - 1]
                t = payload[p] - 256 if payload[p] > 127 else payload[p]
                p += 1
                d.weightA = t * 8
                if d.weightA > 0:
                    d.weightA += (d.weightA + 64) >> 7
                if b.stereo_in:
                    t = payload[p] - 256 if payload[p] > 127 else payload[p]
                    p += 1
                    d.weightB = t * 8
                    if d.weightB > 0:
                        d.weightB += (d.weightB + 64) >> 7
            got.add('weights')
        elif ident == 4:
            if 'terms' not in got:
                continue
            p = 0
            t = 0

            def le16():
                nonlocal p
                v = payload[p] | payload[p + 1] << 8 if p + 1 < size else 0
                p += 2
                return v
            for i in range(len(b.decorr) - 1, -1, -1):
                if t >= size:
                    break
                d = b.decorr[i]
                if d.value > 8:
                    d.samplesA[0] = wp_exp2(le16())
                    d.samplesA[1] = wp_exp2(le16())
                    if b.stereo_in:
                        d.samplesB[0] = wp_exp2(le16())
                        d.samplesB[1] = wp_exp2(le16())
                        t += 4
                    t += 4
                elif d.value < 0:
                    d.samplesA[0] = wp_exp2(le16())
                    d.samplesB[0] = wp_exp2(le16())
                    t += 4
                else:
                    for j in range(d.value):
                        d.samplesA[j] = wp_exp2(le16())
                        if b.stereo_in:
                            d.samplesB[j] = wp_exp2(le16())
                    t += d.value * 2 * (b.stereo_in + 1)
            got.add('samples')
        elif ident == 5:
            if size != 6 * (b.stereo_in + 1):
                continue
            p = 0
            for j in range(b.stereo_in + 1):
                for i in range(3):
                    b.ch[j].median[i] = wp_exp2(payload[p] | payload[p + 1] << 8)
                    p += 2
            got.add('entropy')
        elif ident == 6:
            p = 0
            left = size

            def le16h():
                nonlocal p
                v = payload[p] | payload[p + 1] << 8 if p + 1 < size else 0
                p += 2
                return v
            if b.hybrid_bitrate:
                for i in range(b.stereo_in + 1):
                    b.ch[i].slow_level = wp_exp2(le16h())
                    left -= 2
            for i in range(b.stereo_in + 1):
                b.ch[i].bitrate_acc = le16h() << 16
                left -= 2
            if left > 0:
                for i in range(b.stereo_in + 1):
                    b.ch[i].bitrate_delta = wp_exp2(le16h()) & 0xffffffff
            else:
                for i in range(b.stereo_in + 1):
                    b.ch[i].bitrate_delta = 0
            got.add('hybrid')
        elif ident == 9:
            if size != 4:
                continue
            v = payload
            if v[0] > 30:
                continue
            elif v[0]:
                b.extra_bits = v[0]
                b.used.add('integer extra bits')
            elif v[1]:
                b.shift = v[1]
                b.used.add('shift with zeros')
            elif v[2]:
                b.and_ = b.or_ = 1
                b.shift = v[2]
                b.used.add('shift with ones')
            elif v[3]:
                b.and_ = 1
                b.shift = v[3]
                b.used.add('shift duplicating the low bit')
            if b.shift > 31:
                b.and_ = b.or_ = b.shift = 0
                continue
            if b.hybrid and bpp == 4 and b.post_shift < 8 and b.shift > 8:
                b.used.add('lossy 32-bit clipped as 24-bit')
                b.post_shift += 8
                b.shift -= 8
                b.maxclip >>= 8
                b.minclip >>= 8
            b.used.add('int32 info')
        elif ident == 8:
            if size != 4:
                continue
            b.float_flag, b.float_shift, b.float_max_exp = payload[0], payload[1], payload[2]
            if b.float_shift > 31:
                b.float_shift = 0
                continue
            got.add('float')
        elif ident == 0xa:
            data = payload
            got.add('data')
        elif ident == 0xc:
            if size <= 4:
                continue
            extra = Bits(payload)
            b.crc_extra_expected = extra.get(32)
            b.got_extra_bits = True
            b.used.add('extra bits')
        elif ident == 0xd:
            if size <= 1:
                raise DecodeError('channel info')
            b.used.add('channel info')
            b.chan = payload[0]
            b.chmask = int.from_bytes(payload[1:size], 'little') if size - 2 <= 3 else 0
        elif ident == 0x27:
            if size != 3:
                raise DecodeError('sample rate')
            b.rate = int.from_bytes(payload, 'little')
            b.used.add('custom sample rate')
        elif ident == 0xe:
            raise DecodeError('DSD')
    if data is None:
        raise DecodeError('no samples')
    for need in ('terms', 'weights', 'samples', 'entropy'):
        if need not in got:
            raise DecodeError(f'no {need}')
    if b.hybrid and 'hybrid' not in got:
        raise DecodeError('no hybrid')
    if sample_fmt == 'flt' and 'float' not in got:
        raise DecodeError('no float info')
    if readers is not None:
        readers.block = b
        if extra is not None:
            extra = readers.extra
    if b.got_extra_bits and sample_fmt != 'flt':
        if extra.left() < header_samples * b.extra_bits << b.stereo_in:
            b.got_extra_bits = False
    if extra is None:
        extra = Bits(b'')
    g = Bits(data) if readers is None else readers.data
    b.crc_extra = 0xffffffff
    if b.stereo_in:
        out = unpack_stereo(b, g, extra, sample_fmt)
    else:
        out = unpack_mono(b, g, extra, sample_fmt)
    if b.stereo and not b.stereo_in:
        out = [out[0], list(out[0])]
        b.used.add('false stereo')
    if b.joint:
        b.used.add('joint stereo')
    if b.hybrid:
        b.used.add('hybrid')
    if b.hybrid_bitrate:
        b.used.add('hybrid bitrate')
    if b.shift:
        b.used.add('shift')
    if (flags >> 13) & 0x1f:
        b.used.add('header shift')
    return out, b


def _weight(weight, delta, sample, value, clip):
    if sample and value:
        if (sample ^ value) < 0:
            weight -= delta
            if clip and weight < -1024:
                weight = -1024
        else:
            weight += delta
            if clip and weight > 1024:
                weight = 1024
    return weight


def _apply(weight, sample, value, s16):
    if s16:
        return i32(value + i32((i32(weight * sample) + 512) >> 10))
    return i32(value + ((weight * sample + 512) >> 10))


def unpack_stereo(b, g, extra, fmt):
    left, right = [], []
    crc = 0xffffffff
    pos = 0
    s16 = fmt == 's16'
    count = 0
    while count < b.samples:
        b.pos = pos
        L, last = b.get_value(g, 0)
        if last:
            break
        b.current = L
        R, last = b.get_value(g, 1)
        if last:
            break
        for d in b.decorr:
            t = d.value
            if t > 0:
                if t > 8:
                    if t & 1:
                        A = i32(2 * d.samplesA[0] - d.samplesA[1])
                        B = i32(2 * d.samplesB[0] - d.samplesB[1])
                    else:
                        A = i32(3 * d.samplesA[0] - d.samplesA[1]) >> 1
                        B = i32(3 * d.samplesB[0] - d.samplesB[1]) >> 1
                    d.samplesA[1] = d.samplesA[0]
                    d.samplesB[1] = d.samplesB[0]
                    j = 0
                else:
                    A = d.samplesA[pos]
                    B = d.samplesB[pos]
                    j = (pos + t) & 7
                L2 = _apply(d.weightA, A, L, s16)
                R2 = _apply(d.weightB, B, R, s16)
                if A and L:
                    d.weightA = i32(d.weightA - ((((L ^ A) >> 30) & 2) - 1) * d.delta)
                if B and R:
                    d.weightB = i32(d.weightB - ((((R ^ B) >> 30) & 2) - 1) * d.delta)
                d.samplesA[j] = L = L2
                d.samplesB[j] = R = R2
            elif t == -1:
                L2 = _apply(d.weightA, d.samplesA[0], L, s16)
                d.weightA = _weight(d.weightA, d.delta, d.samplesA[0], L, True)
                L = L2
                R2 = _apply(d.weightB, L2, R, s16)
                d.weightB = _weight(d.weightB, d.delta, L2, R, True)
                R = R2
                d.samplesA[0] = R
            else:
                R2 = _apply(d.weightB, d.samplesB[0], R, s16)
                d.weightB = _weight(d.weightB, d.delta, d.samplesB[0], R, True)
                R = R2
                if t == -3:
                    R2 = d.samplesA[0]
                    d.samplesA[0] = R
                L2 = _apply(d.weightA, R2, L, s16)
                d.weightA = _weight(d.weightA, d.delta, R2, L, True)
                L = L2
                d.samplesB[0] = L
        if s16 and abs(L) + abs(R) > (1 << 19):
            raise DecodeError('sample too large')
        pos = (pos + 1) & 7
        if b.joint:
            R = i32(R - (L >> 1))
            L = i32(L + R)
        crc = (((crc * 3 + L) & 0xffffffff) * 3 + R) & 0xffffffff
        if fmt == 'flt':
            left.append(b.float_value(extra, L))
            right.append(b.float_value(extra, R))
        else:
            left.append(b.integer(extra, L))
            right.append(b.integer(extra, R))
        count += 1
    _finish(b, last, count, crc)
    return [left, right]


def unpack_mono(b, g, extra, fmt):
    out = []
    crc = 0xffffffff
    pos = 0
    s16 = fmt == 's16'
    count = 0
    last = False
    while count < b.samples:
        b.pos = pos
        T, last = b.get_value(g, 0)
        S = 0
        if last:
            break
        for d in b.decorr:
            t = d.value
            if t > 8:
                if t & 1:
                    A = i32(2 * d.samplesA[0] - d.samplesA[1])
                else:
                    A = i32(3 * d.samplesA[0] - d.samplesA[1]) >> 1
                d.samplesA[1] = d.samplesA[0]
                j = 0
            else:
                A = d.samplesA[pos]
                j = (pos + t) & 7
            S = _apply(d.weightA, A, T, s16)
            if A and T:
                d.weightA = i32(d.weightA - ((((T ^ A) >> 30) & 2) - 1) * d.delta)
            d.samplesA[j] = T = S
        if not b.decorr:
            S = T
        pos = (pos + 1) & 7
        crc = (crc * 3 + S) & 0xffffffff
        if fmt == 'flt':
            out.append(b.float_value(extra, S))
        else:
            out.append(b.integer(extra, S))
        count += 1
    _finish(b, last, count, crc)
    return [out]


def _finish(b, last, count, crc):
    if last and count < b.samples:
        raise DecodeError('ran out of bits')
    b.crc_value = crc
    if not b.check:
        return
    if crc != b.crc_expected:
        raise DecodeError('CRC')
    if b.got_extra_bits and b.crc_extra != b.crc_extra_expected:
        raise DecodeError('extra bits CRC')


def blocks(data):
    """(header dict, body) for each block of a .wv file."""
    pos = 0
    while pos + 32 <= len(data) and data[pos:pos + 4] == b'wvpk':
        size, version, index_hi, total_hi, total, index, samples, flags, crc = \
            struct.unpack('<IHBBIIIII', data[pos + 4:pos + 32])
        yield dict(size=size, version=version, samples=samples, flags=flags, crc=crc,
                   index=index | index_hi << 32, total=total | total_hi << 32), data[pos + 32:pos + 8 + size]
        pos += 8 + size


def sample_format(flags):
    if flags & (FLOAT | DSD):
        return 'flt'
    return 's16' if (flags & 3) <= 1 else 's32'


def present(channels, fmt):
    """Decoded channels -> interleaved float32 bytes as FFmpeg presents them
    (int16 / 2^15, int32 / 2^31, float bits unchanged)."""
    out = bytearray()
    for i in range(len(channels[0])):
        for c in channels:
            v = c[i]
            if fmt == 'flt':
                out += struct.pack('<I', v)
            elif fmt == 's16':
                out += struct.pack('<f', (((v + 32768) & 0xffff) - 32768) / 32768.0)
            else:
                out += struct.pack('<f', i32(v) / 2147483648.0)
    return bytes(out)


def decode(data):
    """A .wv file -> (interleaved float32 bytes as FFmpeg presents them,
    channel count, rate, coverage tags)."""
    frames, used = [], set()
    current = []
    rate = None
    for h, body in blocks(data):
        if not h['samples']:
            continue
        fmt = sample_format(h['flags'])
        out, ctx = decode_block(h['samples'], h['flags'], h['crc'], body, fmt)
        used |= ctx.used
        if h['flags'] & INITIAL:
            current = []
            code = (h['flags'] >> 23) & 0xf
            rate = getattr(ctx, 'rate', None) if code == 15 else RATES[code]
        current += out
        if h['flags'] & FINAL:
            frames.append((current, fmt))
    pcm = b''.join(present(chans, fmt) for chans, fmt in frames)
    return pcm, len(frames[0][0]) if frames else 0, rate, used
