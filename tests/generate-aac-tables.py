#!/usr/bin/env python3
"""Generate src/aac_tables.inc from the PacketVideo AAC decoder (Apache 2.0).

usage: python3 tests/generate-aac-tables.py [--check]

The reference files are fetched at a pinned AOSP commit into
tests/reference/pv-aacdec/ and checked against
tests/reference/pv-aacdec-hashes.json. A test-only harness
(tests/aac-huffman-extract.cpp) runs the reference lookup decoder over every
input of each codebook's maximum length, recovering the ISO/IEC 14496-3
codewords; scalefactor band offsets and TNS band limits are read from the
reference tables. No reference code is linked into either player.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / 'tests'
TARGET = ROOT / 'src' / 'aac_tables.inc'
BOOKS = ['scl', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']
SYMBOLS = {'scl': 121, '1': 81, '2': 81, '3': 81, '4': 81, '5': 81, '6': 81, '7': 64, '8': 64, '9': 169,
           '10': 169, '11': 289}
# Sampling-frequency index -> (long table, short table), ISO/IEC 14496-3 table 4.129 grouping.
RATES = [(96000, '96_1024', '64_128'), (88200, '96_1024', '64_128'), (64000, '64_1024', '64_128'),
         (48000, '48_1024', '48_128'), (44100, '48_1024', '48_128'), (32000, '32_1024', '48_128'),
         (24000, '24_1024', '24_128'), (22050, '24_1024', '24_128'), (16000, '16_1024', '16_128'),
         (12000, '16_1024', '16_128'), (11025, '16_1024', '16_128'), (8000, '8_1024', '8_128')]


def reference():
    spec = json.loads((TESTS / 'reference' / 'pv-aacdec-hashes.json').read_text())
    directory = TESTS / 'reference' / spec['directory']
    directory.mkdir(parents=True, exist_ok=True)
    for name, digest in spec['files'].items():
        path = directory / name
        if not path.exists():
            url = spec['url'].format(commit=spec['commit'], file=name)
            with urllib.request.urlopen(url, timeout=60) as response:
                path.write_bytes(response.read())
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit(f'{path}: SHA-256 differs from {spec["commit"]}')
    return directory


def codebooks(directory):
    work = ROOT / 'build' / 'aac-tables'
    work.mkdir(parents=True, exist_ok=True)
    program = work / ('aac-huffman-extract' + ('.exe' if os.name == 'nt' else ''))
    compiler = os.environ.get('CXX') or ('clang++' if os.name == 'nt' else 'g++')
    subprocess.run([compiler, '-O1', '-w', '-I', str(directory), '-o', str(program), str(TESTS / 'aac-huffman-extract.cpp'),
                    str(directory / 'decode_huff_cw_binary.cpp'), str(directory / 'hcbtables_binary.cpp')], check=True)
    output = subprocess.run([str(program)], check=True, capture_output=True, text=True).stdout
    books = {}
    for line in output.splitlines():
        parts = line.split()
        name, count = parts[1], int(parts[2])
        codes = [(int(length), int(code, 16)) for length, code in (p.split(':') for p in parts[4:])]
        if count != SYMBOLS[name] or len(codes) != count:
            raise SystemExit(f'book {name}: {len(codes)} symbols')
        books[name] = codes
    return books


def lookup(codes, bits):
    """Two-level table of 16-bit entries. Leaf: length (bits 0-4), symbol (5-13).
    Subtable: bit 15, extra bits n (0-3), first entry relative to the book (4-14)."""
    table = [None] * (1 << bits)
    subs = {}
    for symbol, (length, code) in enumerate(codes):
        if length <= bits:
            start = code << (bits - length)
            for i in range(1 << (bits - length)):
                assert table[start + i] is None
                table[start + i] = length | symbol << 5
        else:
            subs.setdefault(code >> (length - bits), []).append((symbol, length, code))
    for prefix, entries in sorted(subs.items()):
        extra = max(length for _, length, _ in entries) - bits
        offset = len(table)
        sub = [None] * (1 << extra)
        for symbol, length, code in entries:
            rest = code & ((1 << (length - bits)) - 1)
            start = rest << (extra - (length - bits))
            for i in range(1 << (extra - (length - bits))):
                assert sub[start + i] is None
                sub[start + i] = length | symbol << 5
        assert None not in sub and table[prefix] is None and extra < 16 and offset < 2048
        table[prefix] = 0x8000 | extra | offset << 4
        table.extend(sub)
    assert None not in table
    return table


def c_array(source, name):
    match = re.search(r'\b' + re.escape(name) + r'\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}', source)
    if not match:
        raise SystemExit(f'missing reference array {name}')
    body = re.sub(r'/\*.*?\*/', '', match.group(1), flags=re.S)
    return [int(value) for value in re.findall(r'-?\d+', body)]


def generate():
    directory = reference()
    books = codebooks(directory)
    lines = ['# Generated by tests/generate-aac-tables.py; do not edit.',
             '# AAC Huffman codewords recovered from the PacketVideo AAC decoder (Apache License 2.0)',
             '# by running its lookup decoder over every input; scalefactor band offsets and TNS',
             '# band limits from its ISO/IEC 14496-3 tables. See THIRD_PARTY_NOTICES.', '']

    def emit(name, directive, values, per_line=16):
        lines.append(f'{name}:')
        for i in range(0, len(values), per_line):
            lines.append(f'    {directive} ' + ', '.join(str(v) for v in values[i:i + per_line]))

    # Huffman books: index 0 = scalefactors, 1-11 = spectral books.
    descriptors, entries = [], []
    for name in BOOKS:
        bits = min(range(6, 11), key=lambda b: (len(lookup(books[name], b)), b))
        table = lookup(books[name], bits)
        descriptors += [len(entries), bits]
        entries += table
    lines.append('# Per book: first entry in aac_huff_table, first-level bits.')
    emit('aac_huff_books', '.short', descriptors, 2)
    lines.append('# Leaf: length bits 0-4, symbol bits 5-13. Subtable: bit 15, extra bits 0-3,')
    lines.append('# first entry (relative to the book) bits 4-14.')
    emit('aac_huff_table', '.short', entries)

    sfb = (directory / 'sfb.cpp').read_text()
    tns = (directory / 'get_tns.cpp').read_text()
    counts = re.findall(r'\{\s*(\d+),\s*(\d+),\s*(\d+)\s*\}', sfb[sfb.index('samp_rate_info'):])
    tns_long = c_array(tns, 'tns_max_bands_tbl_long_wndw')
    tns_short = c_array(tns, 'tns_max_bands_tbl_short_wndw')
    offsets, starts, info = [], {}, []
    for index, (rate, long_name, short_name) in enumerate(RATES):
        for name in (long_name, short_name):
            if name not in starts:
                values = c_array(sfb, 'sfb_' + name)
                if values[-1] != (1024 if name.endswith('1024') else 128) or values != sorted(values):
                    raise SystemExit(f'sfb_{name}: not a band table')
                starts[name] = len(offsets)
                offsets += [0] + values
        long_bands = len(c_array(sfb, 'sfb_' + long_name))
        short_bands = len(c_array(sfb, 'sfb_' + short_name))
        if [int(x) for x in counts[index]] != [rate, long_bands, short_bands]:
            raise SystemExit(f'rate index {index}: band counts differ from samp_rate_info')
        info += [rate, starts[long_name], starts[short_name], long_bands, short_bands, tns_long[index], tns_short[index]]
    lines.append('')
    lines.append('# Band offsets, each table starting with 0.')
    emit('aac_swb_offsets', '.short', offsets)
    lines.append('# Per sampling-frequency index 0-11: rate; long and short table starts in')
    lines.append('# aac_swb_offsets; long/short band counts; long/short TNS band limits.')
    lines.append('aac_rate_info:')
    for i in range(0, len(info), 7):
        rate, long_start, short_start, nl, ns, tl, ts = info[i:i + 7]
        lines.append(f'    .long {rate}')
        lines.append(f'    .short {long_start}, {short_start}')
        lines.append(f'    .byte {nl}, {ns}, {tl}, {ts}')
    return '\n'.join(lines) + '\n'


def main():
    text = generate()
    if '--check' in sys.argv[1:]:
        if TARGET.read_text() != text:
            raise SystemExit('src/aac_tables.inc differs from the reference extraction')
        print('Verified AAC tables against the PacketVideo reference.')
    else:
        TARGET.write_text(text)
        print(f'Generated {TARGET}')


if __name__ == '__main__':
    main()
