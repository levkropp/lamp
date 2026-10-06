#!/usr/bin/env python3
"""Check src/gsm.s's GSM 06.10 tables against libgsm's.

usage: python3 tests/check-gsm-tables.py
libgsm 1.0.22 (Jutta Degener and Carsten Bormann, Technische Universitaet
Berlin; permissive license, see THIRD_PARTY_NOTICES) is fetched at a pinned
hash into tests/reference/libgsm/. Its src/table.c lists GSM 06.10's tables
4.1-4.6; the B, MIC and INVA columns, the LTP gains QLB and the mantissas FAC
must equal the assembly's (B doubled, as libgsm's decoder inlines it). No
reference code is linked into either player.
"""
import hashlib
import io
from pathlib import Path
import re
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
URL = 'http://archive.ubuntu.com/ubuntu/pool/universe/libg/libgsm/libgsm_1.0.22.orig.tar.gz'
SHA256 = 'f0072e91f6bb85a878b2f6dbf4a0b7c850c4deb8049d554c65340b3bf69df0ac'
CACHE = ROOT / 'tests' / 'reference' / 'libgsm' / 'libgsm_1.0.22.orig.tar.gz'


def reference():
    if not CACHE.exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(URL, timeout=60) as response:
            CACHE.write_bytes(response.read())
    data = CACHE.read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        sys.exit(f'{CACHE}: unexpected hash')
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        member = next(m for m in archive.getmembers() if m.name.endswith('/src/table.c'))
        return archive.extractfile(member).read().decode('latin-1')


def c_table(text, name):
    match = re.search(r'word\s+' + name + r'\s*\[\s*\d+\s*\]\s*=\s*\{([^}]*)\}', text)
    return [int(v) for v in match.group(1).replace('\n', ' ').split(',') if v.strip()]


def asm_table(text, name):
    match = re.search(r'^' + name + r':\s*\.long\s+([^\n]*)', text, re.M)
    return [int(v) for v in match.group(1).split(',')]


def main():
    table = reference()
    source = (ROOT / 'src' / 'gsm.s').read_text()
    pairs = {'gsm_b2': [2 * v for v in c_table(table, 'gsm_B')], 'gsm_mic': c_table(table, 'gsm_MIC'),
             'gsm_inva': c_table(table, 'gsm_INVA'), 'gsm_qlb': c_table(table, 'gsm_QLB'),
             'gsm_fac': c_table(table, 'gsm_FAC')}
    for name, expected in pairs.items():
        if asm_table(source, name) != expected:
            sys.exit(f'{name}: {asm_table(source, name)} differs from libgsm {expected}')
    print(f'{len(pairs)} GSM tables equal libgsm 1.0.22.')


if __name__ == '__main__':
    main()
