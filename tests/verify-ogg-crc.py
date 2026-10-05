#!/usr/bin/env python3
"""Independent bit-at-a-time Ogg CRC oracle with guarded mapped ends.

usage: python3 tests/verify-ogg-crc.py
Writes <out>/ogg-crc-verification.json.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import TESTS, build_lamp, compile_c, exe, main_guard, out_dir, run


def main():
    library = build_lamp()
    oracle = compile_c(exe('ogg-crc-oracle'), [TESTS / 'ogg-crc-oracle.c'], libraries=[library])
    result = run([oracle])
    print(result)
    (out_dir() / 'ogg-crc-verification.json').write_text(result + '\n', encoding='utf-8')


if __name__ == '__main__':
    main_guard(main)
