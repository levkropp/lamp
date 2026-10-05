#!/usr/bin/env python3
"""Sample-exact WAV/FLAC seeks and byte-exact MP3/Vorbis indexed seeks, then the
Opus reset-reference seek suite.

usage: python3 tests/verify-seek.py [--skip-opus]
Writes <out>/{seek,mp3-seek,vorbis-seek}-verification.json.
"""
from pathlib import Path
import runpy
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import TESTS, build_lamp, build_oracles, exe, lamp_cli, main_guard, node_suite, out_dir, scratch


def main():
    library = build_lamp()
    oracle = build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c'}, library)
    seek = exe('seek-oracle')
    work = scratch('seeking')
    node_suite('seek-fixtures.js', lamp_cli(), seek, work, report=work / 'seek-verification.json')
    node_suite('mp3-seek-fixtures.js', lamp_cli(), seek, work / 'mp3', report=work / 'mp3' / 'mp3-seek-verification.json')
    node_suite('vorbis-seek-fixtures.js', lamp_cli(), seek, work / 'vorbis',
               report=work / 'vorbis' / 'vorbis-seek-verification.json')
    if '--skip-opus' not in sys.argv[1:]:
        sys.argv = [str(TESTS / 'verify-opus-seek.py')]
        runpy.run_path(str(TESTS / 'verify-opus-seek.py'), run_name='__main__')


if __name__ == '__main__':
    main_guard(main)
