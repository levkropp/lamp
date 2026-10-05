#!/usr/bin/env python3
"""Official RFC 8251 Opus vectors: packet final ranges and native PCM/history
against the patched normative decoder, then unmodified opus_compare acceptance.

usage: python3 tests/verify-opus-conformance.py [--rates 8000,48000] [--channels 1,2] [--vectors 1-12]
Downloads the hash-pinned vector archive on first use (test input only).
Writes <out>/opus-conformance-verification.json.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (GENERATED, GENERATED_INCLUDE, TESTS, Failure, build_lamp, compile_c, exe, main_guard, node,
                       opus_defines, opus_reference, out_dir, run, sha1, silk_float_sources, write_report)


def official_vectors():
    manifest = json.loads((TESTS / 'reference/opus-rfc8251-vector-hashes.json').read_text(encoding='utf-8'))
    parent = out_dir() / 'reference'
    parent.mkdir(parents=True, exist_ok=True)
    archive = parent / 'opus-vectors-rfc8251.tar.gz'
    vectors = parent / 'opus-vectors-rfc8251'
    if not archive.exists():
        try:
            with urllib.request.urlopen(manifest['archive_url'], timeout=120) as response:
                data = response.read()
        except OSError as error:
            raise Failure(f"Cannot download the official vectors from {manifest['archive_url']} ({error}). "
                          f'Place the archive at {archive} to run offline.')
        archive.write_bytes(data)
    if not (vectors / 'testvector12m.dec').exists():
        vectors.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as tar:
            members = []
            for member in tar.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts or '..' in parts:
                    continue
                member.name = str(Path(*parts))
                members.append(member)
            tar.extractall(vectors, members=members)
    for name, digest in manifest['files'].items():
        if sha1(vectors / name) != digest:
            raise Failure(f'Official Opus vector hash differs from RFC8251: {name}')
    return vectors


def numbers(text, allowed):
    values = []
    for part in text.split(','):
        if '-' in part:
            low, high = map(int, part.split('-'))
            values += range(low, high + 1)
        else:
            values.append(int(part))
    if not values or any(v not in allowed for v in values):
        raise Failure('Invalid conformance rate/channel/vector selection')
    return list(dict.fromkeys(values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rates', default='8000,12000,16000,24000,48000')
    parser.add_argument('--channels', default='1,2')
    parser.add_argument('--vectors', default='1-12')
    args = parser.parse_args()
    rates = numbers(args.rates, (8000, 12000, 16000, 24000, 48000))
    channel_counts = numbers(args.channels, (1, 2))
    vector_numbers = numbers(args.vectors, range(1, 13))
    reference = opus_reference()
    node('generate-celt-tables.js', reference, '--check')
    node('generate-silk-packet-reference.js', reference, '--check')
    for stage in ('stereo', 'resampler', 'lpc', 'nlsf', 'indices', 'parameters'):
        node(f'generate-silk-{stage}-tables.js', reference, '--check')
    library = build_lamp()
    work = GENERATED / 'opus' / 'conformance'
    includes = [reference / d for d in ('include', 'celt', 'src', 'silk', 'silk/float')] + [GENERATED_INCLUDE]
    defines = opus_defines('SMALL_FOOTPRINT')
    precise = compile_c(work / 'precise', [reference / 'celt/quant_bands.c', *silk_float_sources(reference)],
                        defines=defines, includes=includes, fp='precise', compile_only=True)
    sources = [TESTS / 'opus-conformance-oracle.c']
    sources += [reference / f'celt/{n}.c' for n in ('bands', 'cwrs', 'entcode', 'entdec', 'entenc', 'kiss_fft', 'laplace',
                                                    'mathops', 'mdct', 'modes', 'pitch', 'celt_lpc', 'rate', 'vq')]
    sources += [reference / f'src/{n}.c' for n in ('opus', 'opus_encoder', 'repacketizer')]
    oracle = compile_c(exe('opus-conformance-oracle'), sources, objects=precise, defines=defines, includes=includes,
                       fp='strict', libraries=[library])
    # The official perceptual comparison is compiled unchanged and test-only.
    compare = compile_c(exe('opus-compare'), [reference / 'src/opus_compare.c'], defines=defines, includes=includes)
    vectors = official_vectors()
    checks = []
    for rate in rates:
        for channels in channel_counts:
            for number in vector_numbers:
                name = f'testvector{number:02d}'
                output = work / f'{name}-{rate}-{channels}.s16'
                try:
                    stats = run([oracle, vectors / f'{name}.bit', output, rate, channels])
                except Failure as error:
                    raise Failure(f'Official vector packet/PCM/history mismatch: {name} {rate} {channels} {error}')
                decoded = json.loads(stats.splitlines()[-1])
                compare_args = ['-r', str(rate), vectors / f'{name}.dec', output]
                if channels == 2:
                    compare_args = ['-s'] + compare_args
                result = subprocess.run([str(compare), *map(str, compare_args)], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
                text = result.stderr.decode('utf-8', 'replace')
                quality = re.search(r'quality metric: ([0-9.]+)', text)
                if result.returncode or not quality or 'Test vector PASSES' not in text:
                    raise Failure(f'Official vector perceptual comparison failed: {name} {rate} {channels} {text}')
                checks.append({'vector': name, 'rate': rate, 'channels': channels, 'result': 'passed',
                               'quality_percent': float(quality.group(1)), 'packets': decoded['packets'],
                               'frames': decoded['frames'], 'history_values': decoded['history_values'],
                               'maximum_scaled_error': decoded['maximum_scaled_error']})
                print(f"{name} {rate} Hz {channels} channels: official comparison passed, {quality.group(1)}% quality, "
                      f"{decoded['packets']} exact packet/history checks", flush=True)
                output.unlink()
    write_report('opus-conformance', {
        'result': 'passed', 'complete_set': len(checks) == 120,
        'scope': 'Official RFC8251 phase-inversion vectors, selected rates/channels/vectors recorded per check; unmodified opus_compare acceptance plus packet final-range, native PCM/history at0.00004 scaled tolerance, immutable input, canaries and distinct-scratch assembly checks',
        'reference': 'Hash-verified RFC6716 archive + RFC8251 patch',
        'vector_hashes': 'tests/reference/opus-rfc8251-vector-hashes.json', 'checks': checks})


if __name__ == '__main__':
    main_guard(main)
