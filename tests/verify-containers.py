#!/usr/bin/env python3
"""Container, precision and layout suites built from original fixture
constructors, guarded-output oracles and independent references.

usage: python3 tests/verify-containers.py [aiff] [rf64] [wav-layouts] [flac-layouts] [vorbis-multichannel]
With no arguments every suite runs. Writes <out>/<suite>-verification.json.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, TESTS, WINDOWS, build_lamp, build_oracles, compile_c, lamp_cli, main_guard,
                       node_suite, out_dir, scratch, vorbis_reference)

SUITES = ('aiff', 'rf64', 'wav-layouts', 'flac-layouts', 'vorbis-multichannel')


def oracle_path(directory, name):
    return Path(directory) / (name + ('.exe' if WINDOWS else ''))


def main():
    selected = sys.argv[1:] or list(SUITES)
    unknown = set(selected) - set(SUITES)
    if unknown:
        raise Failure('Unknown suite: ' + ', '.join(sorted(unknown)))
    library = build_lamp()
    out = out_dir()
    common = {'seek-oracle': 'seek-oracle.c', 'pcm-bounds-oracle': 'pcm-bounds-oracle.c'}
    if 'aiff' in selected:
        oracle = build_oracles(out / 'aiff-oracle', {**common, 'aiff-sparse-oracle': 'aiff-sparse-oracle.c'}, library)
        work = scratch('aiff')
        node_suite('aiff-fixtures.js', lamp_cli(), oracle, work, report=work / 'aiff-verification.json')
    if 'rf64' in selected:
        oracle = build_oracles(out / 'rf64-oracle', {**common, 'rf64-sparse-oracle': 'rf64-sparse-oracle.c'}, library)
        work = scratch('rf64')
        node_suite('rf64-fixtures.js', lamp_cli(), oracle, work, report=work / 'rf64-verification.json')
    if 'wav-layouts' in selected:
        oracle = build_oracles(out / 'wav-layout-oracle', common, library)
        work = scratch('wav-layouts')
        node_suite('wav-layout-fixtures.js', lamp_cli(), oracle_path(oracle, 'seek-oracle'), work,
                   oracle_path(oracle, 'pcm-bounds-oracle'), report=work / 'wav-layout-verification.json')
    if 'flac-layouts' in selected:
        oracle = build_oracles(out / 'flac-layout-oracle', {'seek-oracle': 'seek-oracle.c',
                                                            'flac-bounds-oracle': 'pcm-bounds-oracle.c'}, library)
        work = scratch('flac-layouts')
        node_suite('flac-layout-fixtures.js', lamp_cli(), oracle_path(oracle, 'seek-oracle'), work,
                   oracle_path(oracle, 'flac-bounds-oracle'), report=work / 'flac-layout-verification.json')
    if 'vorbis-multichannel' in selected:
        vorbis, ogg, includes = vorbis_reference()
        oracle = out / 'vorbis-multichannel-oracle'
        sources = [vorbis / f'lib/{n}.c' for n in ('mdct', 'smallft', 'block', 'envelope', 'window', 'lsp', 'lpc',
                                                    'analysis', 'synthesis', 'psy', 'info', 'floor1', 'floor0', 'res0',
                                                    'mapping0', 'registry', 'codebook', 'sharedbook', 'lookup', 'bitrate',
                                                    'vorbisfile')]
        sources += [ogg / f'src/{n}.c' for n in ('bitwise', 'framing')]
        references = compile_c(oracle / 'reference', sources, defines=['_CRT_SECURE_NO_WARNINGS'], includes=includes,
                               compile_only=True)
        build_oracles(oracle, {'seek-oracle': 'seek-oracle.c', 'vorbis-native-oracle': 'vorbis-native-oracle.c'},
                      library, includes=includes)
        compile_c(oracle_path(oracle, 'vorbis-native-reference'), [TESTS / 'vorbis-native-reference.c'],
                  objects=references, includes=includes)
        work = scratch('vorbis-multichannel')
        node_suite('vorbis-multichannel-fixtures.js', lamp_cli(), oracle, work,
                   report=work / 'vorbis-multichannel-verification.json')


if __name__ == '__main__':
    main_guard(main)
