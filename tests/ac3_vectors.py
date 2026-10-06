"""Test-only AC-3 stream writer.

FFmpeg's AC-3 encoder never uses short blocks, delta bit allocation, dynamic
range words, skip fields, dual mono, phase flags or the half- and quarter-rate
bit stream ids, so tests/verify-ac3.py also decodes streams written here. The
writer drives the decoder model (tests/ac3_model.py) with a reader that
chooses each value it is asked for, within the limits a valid stream keeps,
and records the bits; the bit allocation that sizes every mantissa is
therefore the model's own. Mantissa codes are random, frames are padded to
their size and both CRCs are set.
"""
import copy
import random

import ac3_model as model

RANDOM_FIELDS = {'bsmod', 'dsurmod', 'cmixlev', 'surmixlev', 'dialnorm', 'compr', 'langcod', 'audprod', 'copyright',
                 'timecod1', 'timecod2', 'xbsi1', 'xbsi2', 'addbsi', 'gainrng', 'cplbndstrc', 'mstrcplco', 'cplcoexp',
                 'cplcomant', 'phsflg', 'rematflg', 'sdcycod', 'fdcycod', 'sgaincod', 'dbpbcod', 'floorcod',
                 'fgaincod', 'cplfleak', 'cplsleak', 'deltba', 'dynrng', 'skip', 'mant', 'fsnroffst'}
COIN_FIELDS = {'compre', 'langcode', 'audprodie', 'timecod1e', 'timecod2e', 'xbsi1e', 'xbsi2e', 'phsflginu'}
CODES = {'b1': 27, 'b2': 125, 'b3': 7, 'b4': 121, 'b5': 15}


class Writer(model.Reader):
    def __init__(self, r, config, snr_high, first=False):
        super().__init__(b'', 40)
        self.first = first
        self.r = r
        self.c = config
        self.snr_high = snr_high
        self.bits = []
        self.marks = {}
        self.dba_band = 0
        self.dba_left = 0

    def get(self, n, label=None, *context):
        v = self.choose(n, label, context)
        assert 0 <= v < (1 << n) or n == 0, (label, v, n)
        if n:
            self.bits.append((v, n))
        self.pos += n
        return v

    def mark(self, event, *context):
        self.marks[(event, *context)] = self.pos

    def chance(self, name):
        return int(self.r.random() < self.c.get(name, 0.5))

    def choose(self, n, label, context):
        r, c = self.r, self.c
        if label in ('bsid', 'acmod'):
            return c[label]
        if label == 'lfeon':
            return c['lfe']
        if label in RANDOM_FIELDS:
            return r.getrandbits(n) if n else 0
        if label in COIN_FIELDS:
            return r.randrange(2)
        if label in CODES:
            return r.randrange(CODES[label])
        if label == 'addbsie':
            return self.chance('addbsi')
        if label == 'addbsil':
            return r.randrange(8)
        if label == 'blksw':
            if self.first and context[0] == 0 and c['acmod'] != 1:
                return int(context[1] == 1)              # see stream()
            return self.chance('short')
        if label == 'dithflag':
            return self.chance('dither')
        if label == 'dynrnge':
            return self.chance('drc')
        if label == 'cplstre':
            return 1 if context[0] == 0 else self.chance('cplstre')
        if label == 'cplinu':
            return self.chance('coupling') if context[0] >= 2 else 0
        if label == 'chincpl':
            ch, nf, count = context
            return 1 if ch == nf and count == 0 else self.chance('chincpl')
        if label == 'cplbegf':
            return r.randrange(16)
        if label == 'cplendf':
            return r.randrange(max(0, context[0] - 2), 16)
        if label == 'cplcoe':
            blk, new = context
            return 1 if blk == 0 or new else self.chance('cplcoe')
        if label in ('rematstr', 'baie', 'snroffste'):
            # Block 0 sends every parameter; so does the block where
            # coupling starts for the coupling channel's offsets.
            return 1 if context[0] == 0 else self.chance(label)
        if label == 'cplleake':
            blk, new = context
            return 1 if blk == 0 or new else self.chance('cplleake')
        if label == 'expstr':
            blk, new = context
            if blk == 0 or new:
                return 1 if n == 1 else r.randrange(1, 4)
            if self.chance('reuse'):
                return 0
            return 1 if n == 1 else r.randrange(1, 4)
        if label == 'chbwcod':
            return r.randrange(c.get('bandwidth_low', 0), 61)
        if label == 'absexp':
            return r.randrange(13)
        if label == 'exp':
            value, level = 0, context[0]
            for _ in range(3):
                options = [d for d in range(-2, 3) if 0 <= level + d <= 24]
                if level > 14 and r.random() < 0.3:
                    options = [d for d in options if d < 0] or options
                d = r.choice(options)
                level += d
                value = value * 5 + d + 2
            return value
        if label == 'csnroffst':
            if self.r.random() < c.get('silent', 0.02):
                return 0
            return r.randrange(0, max(1, self.snr_high) + 1)
        if label == 'deltbaie':
            return 1 if context[0] else self.chance('dba')
        if label == 'deltbae':
            return r.choice([1, 2]) if context[0] == 0 or not context[1] else r.choice([0, 1, 1, 2])
        if label == 'deltnseg':
            self.dba_band = context[0]
            count = r.randrange(8)
            self.dba_left = count + 1
            return count
        if label == 'deltoffst':
            offset = r.randrange(min(31, 49 - self.dba_band) + 1)
            self.dba_band += offset
            return offset
        if label == 'deltlen':
            self.dba_left -= 1
            limit = 50 - self.dba_band if self.dba_left == 0 else 49 - self.dba_band
            length = r.randrange(min(15, limit) + 1)
            self.dba_band += length
            return length
        if label == 'skiple':
            return self.chance('skip')
        if label == 'skipl':
            return r.randrange(c.get('skip_max', 24))
        raise AssertionError(f'no choice for {label}')


_CRC1 = {}


def _crc1(frame, end):
    """crc1 making the CRC of bytes 2 .. end zero (A/52 crc1)."""
    length = end - 2
    if length not in _CRC1:
        columns = []
        for bit in range(16):
            probe = bytearray(length)
            probe[0], probe[1] = (1 << bit) >> 8, (1 << bit) & 0xff
            columns.append(model.crc16(probe))
        _CRC1[length] = columns
    columns = _CRC1[length]
    target = model.crc16(bytes(2) + bytes(frame[4:end]))
    # Solve XOR of columns[bit] for set bits = target over GF(2).
    rows = [(columns[b], 1 << b) for b in range(16)]
    basis = {}
    for value, combo in rows:
        for top in range(15, -1, -1):
            if not value >> top & 1:
                continue
            if top in basis:
                value ^= basis[top][0]
                combo ^= basis[top][1]
            else:
                basis[top] = (value, combo)
                break
    combo = 0
    for top in range(15, -1, -1):
        if target >> top & 1:
            target ^= basis[top][0]
            combo ^= basis[top][1]
    assert target == 0
    return combo


def recrc(frame):
    """The frame with both CRCs recomputed (after a payload change)."""
    frame = bytearray(frame)
    size = len(frame)
    end = ((size >> 2) + (size >> 4)) << 1
    c1 = _crc1(frame, end)
    frame[2], frame[3] = c1 >> 8, c1 & 0xff
    c2 = model.crc16(frame[2:size - 2])
    frame[size - 2], frame[size - 1] = c2 >> 8, c2 & 0xff
    return bytes(frame)


def assemble(header, bits):
    size = header['bytes']
    frame = bytearray(size)
    frame[0], frame[1] = 0x0b, 0x77
    frame[4] = header['fscod'] << 6 | header['frmsizecod']
    value, count = 0, 0
    for v, n in bits:
        value = (value << n) | v
        count += n
    assert 40 + count <= size * 8 - 18, 'frame overflow'
    tail = (size - 5) * 8 - count
    frame[5:] = (value << tail).to_bytes(size - 5, 'big')
    end = ((size >> 2) + (size >> 4)) << 1
    c1 = _crc1(frame, end)
    frame[2], frame[3] = c1 >> 8, c1 & 0xff
    c2 = model.crc16(frame[2:size - 2])
    frame[size - 2], frame[size - 1] = c2 >> 8, c2 & 0xff
    assert model.crc16(frame[2:end]) == 0 and model.crc16(frame[2:]) == 0
    return bytes(frame)


def stream(seed, frames, acmod, lfe=0, fscod=0, bsid=8, frmsizecod=36, mutate=None, **probabilities):
    """Random valid frames -> (bytes, coverage tags of the writer's decoder).

    The first block of the stream mixes long and short transforms: FFmpeg 6.1
    starts as if its overlap buffers held a downmix and, at the first block
    whose channels use different transforms, "upmixes" them (copying or
    clearing channels' delays). While the delays are still zero that is
    harmless, so later mixed blocks compare cleanly."""
    r = random.Random(seed)
    config = dict(acmod=acmod, lfe=lfe, bsid=bsid, short=0.3, dither=0.7, drc=0.3, cplstre=0.25, coupling=0.8,
                  chincpl=0.75, cplcoe=0.4, rematstr=0.4, baie=0.3, snroffste=0.3, cplleake=0.3, reuse=0.5,
                  dba=0.25, skip=0.15, addbsi=0.2)
    config.update(probabilities)
    header = dict(fscod=fscod, frmsizecod=frmsizecod, bsid=bsid, acmod=acmod,
                  bytes=model.T['frame_words'][fscod * 38 + frmsizecod] * 2, shift=max(bsid, 8) - 8)
    decoder = model.Decoder()
    out = bytearray()
    snr = 40
    for f in range(frames):
        for attempt in range(80):
            trial = copy.deepcopy(decoder)
            writer = Writer(r, config, snr, f == 0)
            trial.decode_frame(writer, header, strict=True)
            size = header['bytes'] * 8
            first = writer.marks.get(('block', 2), writer.pos)
            if writer.pos <= size - 18 and first <= (((header['bytes'] >> 2) + (header['bytes'] >> 4)) << 4):
                break
            snr = max(0, snr - 3)
        else:
            raise AssertionError('no frame fits')
        decoder = trial
        frame = assemble(header, writer.bits)
        if mutate:
            frame = mutate(f, frame) or frame
        out += frame
        if writer.pos < size * 3 // 4:
            snr = min(63, snr + 2)
    return bytes(out), decoder.used
