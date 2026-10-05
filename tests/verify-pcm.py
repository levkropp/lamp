#!/usr/bin/env python3
"""WAV and native FLAC exact-PCM checks against FFmpeg, synthetic FLAC branch
vectors, corrupt/truncated rejection and optional playback.

usage: python3 tests/verify-pcm.py [--skip-playback]
Writes <out>/verification.json.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flac_vectors import new_flac_vectors
from lamp_test import (Failure, check_file, decode_f32, ffmpeg, main_guard, out_dir, play, playback_requested,
                       scratch, write_report)
import json


def main():
    work = scratch()
    results = []

    def check_decode(path, mono=False):
        label = Path(path).name
        ours, reference = work / f'{label}.ours.f32', work / f'{label}.reference.f32'
        stats = decode_f32(path, ours)
        args = ['-i', path]
        if mono:
            args += ['-af', 'pan=stereo|c0=c0|c1=c0']
        ffmpeg(*args, '-c:a', 'pcm_f32le', '-f', 'f32le', reference)
        a, b = ours.read_bytes(), reference.read_bytes()
        if a != b:
            first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), -1)
            raise Failure(f'Sample mismatch: {label}, lengths={len(a)}/{len(b)}, first byte={first}')
        results.append({'test': label, 'result': 'exact', 'bytes': len(a), 'stats': stats})

    stereo = 'aevalsrc=0.08*sin(2*PI*997*t)+0.03*sin(2*PI*71*t)|0.06*sin(2*PI*431*t):s=48000:d=0.3'
    for codec in ('pcm_u8', 'pcm_s16le', 'pcm_s24le', 'pcm_s32le', 'pcm_f32le'):
        for channels in (1, 2):
            path = work / f'{codec}-{channels}.wav'
            ffmpeg('-f', 'lavfi', '-i', stereo, '-ac', str(channels), '-c:a', codec, path)
            check_decode(path, channels == 1)
    for bits in (16, 24):
        for channels in (1, 2):
            for level in (0, 5, 12):
                source = work / f'pcm_s{bits}le-{channels}.wav'
                path = work / f'flac-{bits}-{channels}-level{level}.flac'
                ffmpeg('-i', source, '-c:a', 'flac', '-compression_level', str(level), path)
                check_decode(path, channels == 1)
    for pattern in ('anullsrc=r=44100:cl=stereo', 'anoisesrc=r=44100:d=0.3:seed=1234:a=0.07'):
        kind = 'silence' if pattern.startswith('anull') else 'noise'
        path = work / f'{kind}.flac'
        ffmpeg('-f', 'lavfi', '-i', pattern, '-t', '0.3', '-ac', '2', '-c:a', 'flac', '-compression_level', '12', path)
        check_decode(path)
    for path in new_flac_vectors(work):
        check_decode(path)
    # Files whose advertised structure or CRC contradicts the bytes must fail.
    data = bytearray((work / 'flac-16-2-level5.flac').read_bytes())
    data[-3] ^= 1
    bad = work / 'bad-crc.flac'
    bad.write_bytes(data)
    code, stats = check_file(bad)
    if code == 0:
        raise Failure('Corrupt FLAC was accepted.')
    results.append({'test': 'corrupt-flac', 'result': 'rejected', 'bytes': 0, 'stats': stats})
    for fmt, source in (('wav', 'pcm_s16le-2.wav'), ('flac', 'flac-16-2-level5.flac')):
        data = (work / source).read_bytes()
        bad = work / f'truncated.{fmt}'
        bad.write_bytes(data[:len(data) - 10])
        code, stats = check_file(bad)
        if code == 0:
            raise Failure(f'Truncated {fmt} was accepted.')
        results.append({'test': f'truncated-{fmt}', 'result': 'rejected', 'bytes': 0, 'stats': stats})
    if playback_requested(sys.argv[1:]):
        # Digital silence exercises real audio rendering without audible output.
        path = work / 'playback-silence.flac'
        ffmpeg('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '1.2', '-c:a', 'flac', path)
        results.append({'test': 'playback-silence', 'result': 'played', 'bytes': 0, 'stats': play(path)})
    report = out_dir() / 'verification.json'
    report.write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print(f'Passed {len(results)} checks. Report: {report}')


if __name__ == '__main__':
    main_guard(main)
