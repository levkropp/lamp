#!/usr/bin/env python3
"""Opus indexed seeks against an independent Ogg packet reader and a reset
RFC 8251 reference decoder.

usage: python3 tests/verify-opus-seek.py
Writes <out>/opus-seek-verification.json.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (GENERATED, TESTS, build_lamp, compile_c, exe, lamp_cli, main_guard, node_suite, opus_defines,
                       opus_reference, scratch, silk_float_sources)


def main():
    reference = opus_reference()
    library = build_lamp()
    work = GENERATED / 'opus' / 'seek'
    includes = [reference / d for d in ('include', 'celt', 'src', 'silk', 'silk/float')]
    defines = opus_defines('SMALL_FOOTPRINT')
    precise = compile_c(work / 'precise', [reference / 'celt/quant_bands.c', *silk_float_sources(reference)],
                        defines=defines, includes=includes, fp='precise', compile_only=True)
    sources = [TESTS / 'opus-seek-oracle.c']
    sources += [reference / f'celt/{n}.c' for n in ('bands', 'cwrs', 'entcode', 'entdec', 'entenc', 'kiss_fft', 'laplace',
                                                    'mathops', 'mdct', 'modes', 'pitch', 'celt_lpc', 'rate', 'vq')]
    sources += [reference / f'src/{n}.c' for n in ('opus', 'opus_encoder', 'repacketizer')]
    oracle = compile_c(exe('opus-seek-oracle'), sources, objects=precise, defines=defines, includes=includes,
                       fp='strict', libraries=[library])
    work = scratch('seeking', 'opus')
    node_suite('opus-seek-fixtures.js', lamp_cli(), oracle, work, report=work / 'opus-seek-verification.json')


if __name__ == '__main__':
    main_guard(main)
