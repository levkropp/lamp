"""Original synthetic FLAC vectors that force branches an encoder may avoid.

new_flac_vectors(directory) writes the files and returns their paths. No
reference code is copied.
"""
import math
from pathlib import Path


def _crc(data, width):
    crc, poly, mask = 0, 7 if width == 8 else 0x8005, (1 << width) - 1
    for byte in data:
        crc ^= byte << (width - 8)
        for _ in range(8):
            crc <<= 1
            if crc & (1 << width):
                crc ^= poly
        crc &= mask
    return crc


class _Bits:
    def __init__(self):
        self.bits = []

    def add(self, value, width):
        for j in range(width - 1, -1, -1):
            self.bits.append((value >> j) & 1)

    def bytes(self):
        bits = self.bits + [0] * (-len(self.bits) % 8)
        return bytes(int(''.join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8))


SPECS = [
    ('constant', 0, 0, 1, 4, False, 0), ('verbatim', 1, 0, 1, 4, False, 0),
    ('fixed0', 8, 0, 1, 4, False, 0), ('fixed1', 9, 1, 1, 4, False, 0),
    ('fixed2', 10, 2, 1, 4, False, 0), ('fixed3', 11, 3, 1, 4, False, 0),
    ('fixed4', 12, 4, 1, 4, False, 0), ('lpc3', 34, 3, 1, 4, False, 0),
    ('rice5', 10, 2, 1, 5, False, 0), ('escape', 10, 2, 1, 4, True, 0),
    ('escape5', 10, 2, 1, 5, True, 0), ('wasted2', 10, 2, 1, 4, False, 2),
    ('left-side', 10, 2, 8, 4, False, 0), ('side-right', 10, 2, 9, 4, False, 0),
    ('mid-side', 10, 2, 10, 4, False, 0),
]
COEFFICIENTS = {0: [], 1: [1], 2: [2, -1], 3: [3, -3, 1], 4: [4, -6, 4, -1]}


def new_flac_vectors(directory):
    paths = []
    for name, kind, order, mode, rice, escape, wasted in SPECS:
        # round() rounds half to even, as .NET Math.Round did when these were defined.
        left = [round(1000 * math.sin(i * 0.3)) for i in range(32)]
        right = [round(600 * math.cos(i * 0.4)) for i in range(32)]
        if kind == 0:
            left, right = [1337] * 32, [-321] * 32
        if wasted:
            left, right = [x * 4 for x in left], [x * 4 for x in right]
        a, b = list(left), list(right)
        for i in range(32):
            if mode == 8:
                b[i] = left[i] - right[i]
            elif mode == 9:
                a[i] = left[i] - right[i]
            elif mode == 10:
                a[i], b[i] = (left[i] + right[i]) >> 1, left[i] - right[i]
        bits = _Bits()
        for channel in range(2):
            samples = list(a if channel == 0 else b)
            bps = 16 + ((mode == 9 and channel == 0) or (mode in (8, 10) and channel == 1))
            bits.add(0, 1)
            bits.add(kind, 6)
            bits.add(int(wasted > 0), 1)
            if wasted:
                for _ in range(1, wasted):
                    bits.add(0, 1)
                bits.add(1, 1)
                bps -= wasted
                samples = [s >> wasted for s in samples]
            if kind == 0:
                bits.add(samples[0], bps)
                continue
            if kind == 1:
                for sample in samples:
                    bits.add(sample, bps)
                continue
            for i in range(order):
                bits.add(samples[i], bps)
            coeff = COEFFICIENTS[order]
            if kind >= 32:
                bits.add(3, 4)      # 4-bit coefficient precision
                bits.add(0, 5)      # zero right shift
                for c in coeff:
                    bits.add(c, 4)
            bits.add(rice - 4, 2)
            bits.add(1, 4)          # two residual partitions
            for partition in range(2):
                start, end = (order, 16) if partition == 0 else (16, 32)
                parameter = (1 << rice) - 1 if escape else 8
                bits.add(parameter, rice)
                if escape:
                    bits.add(16, 5)
                for i in range(start, end):
                    residual = samples[i] - sum(coeff[j] * samples[i - j - 1] for j in range(order))
                    if escape:
                        bits.add(residual, 16)
                        continue
                    unsigned = -2 * residual - 1 if residual < 0 else 2 * residual
                    for _ in range(unsigned >> parameter):
                        bits.add(0, 1)
                    bits.add(1, 1)
                    bits.add(unsigned & ((1 << parameter) - 1), parameter)
        header = bytes([0xff, 0xf8, 0x60, (mode << 4) | 8, 0, 31])
        header += bytes([_crc(header, 8)])
        frame = header + bits.bytes()
        crc = _crc(frame, 16)
        frame += bytes([crc >> 8, crc & 255])
        metadata = bytearray(34)
        metadata[1] = 32
        metadata[3] = 32
        packed = (48000 << 44) | (1 << 41) | (15 << 36) | 32
        for i in range(8):
            metadata[10 + i] = (packed >> (56 - 8 * i)) & 255
        path = Path(directory) / f'vector-{name}.flac'
        path.write_bytes(bytes([0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34]) + bytes(metadata) + frame)
        paths.append(path)
    return paths
