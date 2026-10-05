"""Random valid MPEG audio Layer I/II bitstreams for decoder comparisons.

Frames follow ISO/IEC 11172-3 and 13818-3: random bit allocations within each
allocation table, scalefactor selection patterns, scalefactors 0..62, samples
that avoid the forbidden all-ones codes, joint stereo bounds and optional
CRC-16. Ancillary bits fill each frame. Every frame of a stream keeps the
mode, rate, layer and flags that FFmpeg's demuxer requires to stay constant;
bitrate, padding, mode extension and CRC protection vary.
"""
import random

RATES = {1: (44100, 48000, 32000), 2: (22050, 24000, 16000)}
BITRATES = {(1, 1): (0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),
            (1, 2): (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
            (2, 1): (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),
            (2, 2): (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)}
# Allocation code -> quantizer: 0 none, 2..16 bits, 17/18/19 grouped 3/5/9 levels.
CODES = [0, 17, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
         0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
         0, 17, 18, 3, 19, 4, 5, 16,
         0, 17, 18, 16,
         0, 17, 18, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
         0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
         0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]


class Bits:
    def __init__(self):
        self.bits = []

    def put(self, value, count):
        for i in range(count - 1, -1, -1):
            self.bits.append((value >> i) & 1)

    def data(self):
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            chunk = self.bits[i:i + 8] + [0] * (8 - len(self.bits[i:i + 8]))
            out.append(int(''.join(map(str, chunk)), 2))
        return bytes(out)


def crc16(bits):
    crc = 0xffff
    for bit in bits:
        top = (crc >> 15) & 1
        crc = (crc << 1) & 0xffff
        if top ^ bit:
            crc ^= 0x8005
    return crc


def table(layer, version, rate_index, kbps, mode):
    """(rows of (code offset, allocation bits, subbands), subband limit)."""
    if layer == 1:
        return [(76, 4, 32)], 32
    if version == 2:
        return [(60, 4, 4), (44, 3, 7), (44, 2, 19)], 30
    per_channel = kbps if mode == 3 else kbps // 2
    if per_channel < 56:
        return [(44, 4, 2), (44, 3, 10)], 12 if rate_index == 2 else 8
    if per_channel >= 96 and rate_index != 1:
        return [(0, 4, 3), (16, 4, 8), (32, 3, 12), (40, 2, 7)], 30
    return [(0, 4, 3), (16, 4, 8), (32, 3, 12), (40, 2, 7)], 27


def quantizer_bits(quantizer, layer):
    """Bits per transmitted sample group: Layer I one sample; Layer II three."""
    if quantizer >= 17:
        return {17: 5, 18: 7, 19: 10}[quantizer]
    return quantizer if layer == 1 else 3 * quantizer


def frame(rng, layer, version, rate_index, bitrate_index, mode, mode_ext, crc, padding, density):
    kbps = BITRATES[(version, layer)][bitrate_index]
    rate = RATES[version][rate_index]
    if layer == 1:
        size = (12000 * kbps // rate + padding) * 4
    else:
        size = 144000 * kbps // rate + padding
    rows, limit = table(layer, version, rate_index, kbps, mode)
    channels = 1 if mode == 3 else 2
    bound = 0 if mode == 3 else (mode_ext * 4 + 4 if mode == 1 else 32)
    bound = min(bound, limit)
    # Per-subband allocation field width and code table.
    widths, offsets, row = [], [], 0
    remaining = rows[0][2]
    for band in range(limit):
        if remaining == 0:
            row += 1
            remaining = rows[row][2]
        widths.append(rows[row][1])
        offsets.append(rows[row][0])
        remaining -= 1
    groups = 12                         # transmitted sample groups per subband and channel
    fixed = 32 + (16 if crc else 0) + sum(widths[b] * (channels if b < bound else 1) for b in range(limit))
    if fixed > size * 8:
        return None                     # allocation alone exceeds this bitrate

    def choose():
        codes = {}
        for band in range(limit):
            for ch in range(channels if band < bound else 1):
                code = 0
                if rng.random() < density:
                    choices = [c for c in range(1, 1 << widths[band]) if CODES[offsets[band] + c]]
                    if layer == 1:
                        choices = [c for c in choices if c != 15]   # forbidden
                    code = rng.choice(choices) if choices else 0
                codes[(band, ch)] = code
        return codes

    for _ in range(64):
        codes = choose()
        entries = []                     # (band, channel) with scalefactors
        for band in range(limit):
            for ch in range(channels):
                shared = band >= bound and channels == 2
                code = codes[(band, 0 if shared else ch)]
                if CODES[offsets[band] + code]:
                    entries.append((band, ch))
        header_bits = 32 + (16 if crc else 0)
        allocation_bits = sum(widths[b] * (channels if b < bound else 1) for b in range(limit))
        scfsi = {e: (rng.randrange(4) if layer == 2 else 2) for e in entries}
        scf_count = {0: 3, 1: 2, 2: 1, 3: 2}
        scf_bits = sum(6 * scf_count[scfsi[e]] for e in entries) + (2 * len(entries) if layer == 2 else 0)
        sample_bits = 0
        for band in range(limit):
            for ch in range(channels if band < bound else 1):
                q = CODES[offsets[band] + codes[(band, ch)]]
                if q:
                    sample_bits += groups * quantizer_bits(q, layer)
        if header_bits + allocation_bits + scf_bits + sample_bits <= size * 8:
            break
        density *= 0.7
    else:
        raise RuntimeError('no allocation fits the frame')
    bits = Bits()
    header = (0xfff << 20) | ((1 if version == 1 else 0) << 19) | ((4 - layer) << 17) | ((0 if crc else 1) << 16)
    header |= (bitrate_index << 12) | (rate_index << 10) | (padding << 9) | (mode << 6) | (mode_ext << 4)
    bits.put(header, 32)
    if crc:
        bits.put(0, 16)
    protected_start = len(bits.bits)
    for band in range(limit):
        for ch in range(channels if band < bound else 1):
            bits.put(codes[(band, ch)], widths[band])
    if layer == 2:
        for e in entries:
            bits.put(scfsi[e], 2)
    protected_end = len(bits.bits)
    for e in entries:
        for _ in range(scf_count[scfsi[e]]):
            bits.put(rng.randrange(63), 6)
    # Samples: Layer I twelve slots of one sample; Layer II twelve granules of three.
    for _ in range(12):
        for band in range(limit):
            for ch in range(channels if band < bound else 1):
                q = CODES[offsets[band] + codes[(band, ch)]]
                if not q:
                    continue
                if q >= 17:
                    levels = {17: 3, 18: 5, 19: 9}[q]
                    value = 0
                    for k in range(3):
                        value += rng.randrange(levels) * levels ** k
                    bits.put(value, quantizer_bits(q, layer))
                else:
                    for _ in range(1 if layer == 1 else 3):
                        bits.put(rng.randrange((1 << q) - 1), q)
    while len(bits.bits) < size * 8:
        bits.bits.append(rng.randrange(2))
    if crc:
        value = crc16(bits.bits[16:32] + bits.bits[protected_start:protected_end])
        for i in range(16):
            bits.bits[32 + i] = (value >> (15 - i)) & 1
    data = bits.data()
    assert len(data) == size
    return data


def stream(seed, layer, version, rate_index, mode, frames=24, crc=None, bitrates=None, density=0.75):
    rng = random.Random(seed)
    choices = bitrates or list(range(1, 15))
    out = []
    while len(out) < frames:
        index = rng.choice(choices)
        ext = rng.randrange(4) if mode == 1 else 0
        protect = rng.randrange(2) if crc is None else crc
        data = frame(rng, layer, version, rate_index, index, mode, ext, protect, rng.randrange(2), density)
        if data:
            out.append(data)
    return b''.join(out)
