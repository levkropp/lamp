#!/usr/bin/env python3
"""Generate src/ac3_tables.inc for the AC-3 (ATSC A/52) decoder.

usage: python3 tests/generate-ac3-tables.py [--check]

Source, fetched at a pinned commit into tests/reference/ and checked against
tests/reference/ac3-reference-hashes.json:
- codec-ac3 (MIT License): the A/52 hearing threshold table (7.15), the
  log-addition table (7.14), the band boundaries (7.12), the bap table (7.16),
  the frame size table (5.18) and the bit allocation parameter tables
  (7.6-7.11). codec-ac3 stores the threshold, floor and decibels-per-bit
  values as 3072 minus the standard's, the log-addition table negated and the
  bap table as mantissa sizes indexed backwards; they are converted back here
  and cross-checked against the standard's formulas where those exist.
Mantissa levels (7.3), the dynamic range gains (7.7), the KBD window (alpha 5),
IMDCT twiddles and the CRC table are computed. The dither generator state is
FFmpeg's lagged Fibonacci generator seeded with 0, so dithered coefficients
compare closely with FFmpeg's decoder.
No reference code is linked into either player.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / 'tests'
TARGET = ROOT / 'src' / 'ac3_tables.inc'
BAP_SIZES = {0: 0, -1: 1, -2: 2, 3: 3, -3: 4, 4: 5, 5: 6, 6: 7, 7: 8, 8: 9, 9: 10, 10: 11, 11: 12, 12: 13, 14: 14, 16: 15}


def fetch():
    spec = json.loads((TESTS / 'reference' / 'ac3-reference-hashes.json').read_text())
    paths = {}
    for source in spec['sources']:
        directory = TESTS / 'reference' / source['directory']
        for name, digest in source['files'].items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                url = source['url'].format(commit=source['commit'], file=name)
                with urllib.request.urlopen(url, timeout=60) as response:
                    path.write_bytes(response.read())
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise SystemExit(f'{path}: SHA-256 differs from {source["commit"]}')
            paths[name] = path
    return paths


def ints(text, name):
    body = re.search(r'\b' + name + r'(?:\[\d+\])+\s*=\s*\{(.*?)\};', text, re.S).group(1)
    body = re.sub(r'//[^\n]*', '', body)
    return [int(v, 0) for v in re.findall(r'-?(?:0x[0-9a-fA-F]+|\d+)', body)]


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def f32_bits(value):
    return '0x%08x' % struct.unpack('<I', struct.pack('<f', value))[0]


def f64_bits(value):
    return '0x%016x' % struct.unpack('<Q', struct.pack('<d', value))[0]


def c_div(a, b):
    """C integer division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def dequant(code, levels):
    return c_div((code - (levels >> 1)) << 24, levels)


def kbd_window(alpha, n):
    """FFmpeg's ff_kbd_window_init: rising half of n values."""
    alpha2 = 4 * (alpha * math.pi / n) ** 2
    temp = []
    scale = 0.0
    for i in range(n // 2 + 1):
        x2 = alpha2 * i * (n - i) / 4                    # (x/2)^2 for I0(x)
        term, value = 1.0, 1.0
        for k in range(1, 60):
            term *= x2 / (k * k)
            value += term
        temp.append(value)
        scale += value * (1 + (0 < i < n // 2))
    scale = 1.0 / (scale + 1)
    window, total = [], 0.0
    for i in range(n):
        total += temp[i] if i <= n // 2 else temp[n - i]
        window.append(math.sqrt(total * scale))
    return window


def lfg_state(seed=0):
    """FFmpeg av_lfg_init: state words 8..63 from a chain of MD5 sums."""
    state = [0] * 64
    tmp = bytearray(16)
    for i in range(8, 64, 4):
        tmp[0:4] = struct.pack('<I', seed)
        tmp[4] = i
        tmp = bytearray(hashlib.md5(bytes(tmp)).digest())
        state[i:i + 4] = struct.unpack('<4I', bytes(tmp))
    return state


def tables():
    """The decoder's tables as Python values (also used by tests/ac3_model.py)."""
    paths = fetch()
    text = paths['src/decoder/AC3Tables.h'].read_text()
    alloc = paths['src/decoder/AC3BitAllocation.h'].read_text()
    t = {}
    words = ints(text, 'kAc3FrameSizeWords')
    rates = [48000, 44100, 32000]
    kbps = ints(text, 'kAc3BitRateKbps')
    for s, rate in enumerate(rates):
        for code in range(38):
            exact = kbps[code >> 1] * 1000 * 1536 // (16 * rate)
            expected = exact + (code & 1 if rate == 44100 else 0)
            if words[s * 38 + code] != expected:
                raise SystemExit(f'frame size {s} {code} disagrees with the bit rate')
    t['frame_words'] = words
    band_ends = ints(text, 'kBandTab')
    starts = list(range(21)) + band_ends
    sizes = [starts[b + 1] - starts[b] for b in range(50)]
    if len(starts) != 51 or sizes != [1] * 28 + [3] * 7 + [6] * 6 + [12] * 4 + [24] * 5:
        raise SystemExit('band table disagrees with the band sizes of 7.12')
    t['band_start'] = starts
    t['bin_band'] = [max(b for b in range(50) if starts[b] <= k) for k in range(256)]
    latab = [-v for v in ints(text, 'kLogAddTab')]
    # 128 units per 6 dB; entry i adds powers 2i units apart, truncated.
    if latab != [math.floor(128 / 6 * 10 * math.log10(1 + 10 ** (-0.09375 * i / 10))) for i in range(256)]:
        raise SystemExit('log-addition table disagrees with its formula')
    t['latab'] = latab
    hth = [3072 - v for v in ints(text, 'kHearingThreshold')]
    if len(hth) != 150 or hth[0] != 0x4d0:
        raise SystemExit('hearing threshold table: wrong size')
    t['hth'] = hth                                        # [fscod][band]
    codes = ints(text, 'kBapTab')
    bap = [BAP_SIZES[codes[156 - a]] for a in range(64)]
    runs = [1, 5, 2, 3, 2, 2] + [4] * 8 + [8, 9]
    if bap != [b for b, n in enumerate(runs) for _ in range(n)]:
        raise SystemExit('bap table disagrees with 7.16')
    if any(BAP_SIZES[c] != 15 for c in codes[:93]) or any(c for c in codes[157:]):
        raise SystemExit('bap table clamps differ')
    t['baptab'] = bap
    t['slow_gain'] = ints(alloc, 'kSlowGainTab')
    t['db_per_bit'] = [3072 - v for v in ints(alloc, 'kDbPerBitTab')]
    t['floor'] = [(3072 - v) & 0xffff for v in ints(alloc, 'kFloorTab')]
    if t['db_per_bit'] != [0, 0x700, 0x900, 0xb00] or t['floor'][-1] != 0xf800:
        raise SystemExit('bit allocation parameters differ from 7.9-7.10')
    t['slow_decay'] = [15 + 2 * i for i in range(4)]
    t['fast_decay'] = [63 + 20 * i for i in range(4)]
    t['fast_gain'] = [128 + 128 * i for i in range(8)]
    t['b1'] = [[dequant(i // 9, 3), dequant(i % 9 // 3, 3), dequant(i % 3, 3)] for i in range(32)]
    t['b2'] = [[dequant(i // 25, 5), dequant(i % 25 // 5, 5), dequant(i % 5, 5)] for i in range(128)]
    t['b3'] = [dequant(i, 7) for i in range(7)] + [0]
    t['b4'] = [[dequant(i // 11, 11), dequant(i % 11, 11)] for i in range(128)]
    t['b5'] = [dequant(i, 15) for i in range(15)] + [0]
    t['quant_bits'] = [0, 3, 5, 7, 11, 15, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16]
    dynrng = []
    for i in range(256):
        v = (i >> 5) - ((i >> 7) << 3) - 5
        dynrng.append(f32(2.0 ** v * ((i & 0x1f) | 0x20)))
    t['dynrng'] = dynrng
    t['window'] = [f32(v) for v in kbd_window(5.0, 256)]
    t['lfg'] = lfg_state(0)
    crc = []
    for i in range(256):
        c = i << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x8005 if c & 0x8000 else c << 1) & 0xffff
        crc.append(c)
    t['crc'] = crc
    return t


def twiddles(entries, m, offset, scale):
    """Entry i: s exp(-i pi (i + offset) / m) as (wr, wr), (-wi, wi)."""
    rows = []
    for i in range(entries):
        theta = math.pi * (i + offset) / m
        c, s = scale * math.cos(theta), scale * math.sin(theta)
        rows.append((c, c, s, -s))
    return rows


def reverse(bits):
    return [int(format(i, f'0{bits}b')[::-1], 2) for i in range(1 << bits)]


def generate():
    t = tables()
    lines = ['# Generated by tests/generate-ac3-tables.py; do not edit.',
             '# A/52 frame sizes and bit allocation tables from codec-ac3 (MIT License),',
             '# converted to the standard\'s values. See THIRD_PARTY_NOTICES.', '']

    def emit(label, directive, values, width=16, comment=None):
        if comment:
            lines.append('# ' + comment)
        lines.append(label + ':')
        for i in range(0, len(values), width):
            lines.append(f'    .{directive} ' + ', '.join(str(v) for v in values[i:i + width]))

    emit('ac3_frame_words', 'short', t['frame_words'], 19, 'Frame sizes in 16-bit words, [fscod][frmsizecod].')
    emit('ac3_band_start', 'byte', t['band_start'], 17, 'First bin of each of the 50 bit allocation bands, and 253.')
    emit('ac3_bin_band', 'byte', t['bin_band'], 16, 'Band of each bin.')
    emit('ac3_latab', 'byte', t['latab'], 16, 'Log-addition table.')
    emit('ac3_baptab', 'byte', t['baptab'], 16, 'Bit allocation pointers by (psd - mask) >> 5.')
    emit('ac3_quant_bits', 'byte', t['quant_bits'], 16, 'Mantissa bits by bap (groups for 1, 2 and 4).')
    lines.append('.p2align 2')
    emit('ac3_hth', 'short', t['hth'], 10, 'Hearing threshold, [fscod][band].')
    emit('ac3_slow_decay', 'short', t['slow_decay'])
    emit('ac3_fast_decay', 'short', t['fast_decay'])
    emit('ac3_slow_gain', 'short', t['slow_gain'])
    emit('ac3_db_per_bit', 'short', t['db_per_bit'])
    emit('ac3_floor', 'short', t['floor'])
    emit('ac3_fast_gain', 'short', t['fast_gain'])
    emit('ac3_crc_table', 'short', t['crc'], 16, 'CRC-16, x^16 + x^15 + x^2 + 1, most significant bit first.')
    lines.append('.p2align 2')
    emit('ac3_b1', 'long', [v for row in t['b1'] for v in row], 12,
         'Mantissa levels, 24-bit fixed point: grouped bap 1 (3 in 5 bits), 2 (3 in 7), 4 (2 in 7);')
    lines.append('# bap 3 and 5 single. Codes above the levels follow the grouping formula.')
    emit('ac3_b2', 'long', [v for row in t['b2'] for v in row], 12)
    emit('ac3_b3', 'long', t['b3'], 8)
    emit('ac3_b4', 'long', [v for row in t['b4'] for v in row], 12)
    emit('ac3_b5', 'long', t['b5'], 8)
    emit('ac3_dynrng', 'long', [f32_bits(v) for v in t['dynrng']], 8, 'Dynamic range gains (floats).')
    emit('ac3_window', 'long', [f32_bits(v) for v in t['window']], 8, 'Kaiser-Bessel-derived window, alpha 5, rising half (floats).')
    emit('ac3_lfg_init', 'long', ['0x%08x' % v for v in t['lfg']], 8,
         'Dither generator state: FFmpeg\'s lagged Fibonacci generator seeded with 0.')
    lines.append('.p2align 4')
    lines.append('# DCT-IV of 256 and 128 coefficients through 128- and 64-point complex FFTs:')
    lines.append('# pre-twiddles exp(-i pi (n + 1/4) / M), post-twiddles exp(-i pi k / M) and')
    lines.append('# FFT twiddles exp(-2 pi i j / 128), each as (wr, wr), (-wi, wi) doubles.')
    for label, rows in (('ac3_pre_long', twiddles(128, 256, 0.25, 1.0)), ('ac3_post_long', twiddles(128, 256, 0.0, 1.0)),
                        ('ac3_pre_short', twiddles(64, 128, 0.25, 1.0)), ('ac3_post_short', twiddles(64, 128, 0.0, 1.0)),
                        ('ac3_fft_tw', twiddles(64, 64, 0.0, 1.0))):
        lines.append(label + ':')
        for row in rows:
            lines.append('    .quad ' + ', '.join(f64_bits(v) for v in row))
    emit('ac3_rev128', 'short', reverse(7), 16, 'Bit reversal of 7 and 6 bits.')
    emit('ac3_rev64', 'short', reverse(6), 16)
    return '\n'.join(lines) + '\n'


def main():
    text = generate()
    if '--check' in sys.argv[1:]:
        if TARGET.read_text() != text:
            raise SystemExit('src/ac3_tables.inc differs from the reference extraction')
        print('Verified AC-3 tables against the codec-ac3 reference and the A/52 formulas.')
    else:
        TARGET.write_text(text)
        print(f'Generated {TARGET}')


if __name__ == '__main__':
    main()
