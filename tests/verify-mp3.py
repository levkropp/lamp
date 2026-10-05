#!/usr/bin/env python3
"""MP3 numerical checks against FFmpeg mp3float, generated vectors,
malformed-stream rejection and optional playback.

usage: python3 tests/verify-mp3.py [--skip-playback]
Writes <out>/mp3-verification.json.
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, check_file, compare_pcm, decode_f32, ffmpeg, main_guard, node, out_dir, play,
                       playback_requested, scratch)


def main():
    work = scratch()
    results = []

    def check(path, mono):
        label = Path(path).name
        ours, reference = work / f'{label}.ours.f32', work / f'{label}.reference.f32'
        stats = decode_f32(path, ours)
        args = ['-c:a', 'mp3float', '-i', path]
        if mono:
            args += ['-af', 'pan=stereo|c0=c0|c1=c0']
        ffmpeg(*args, '-c:a', 'pcm_f32le', '-f', 'f32le', reference)
        measure = compare_pcm(ours, reference)
        results.append({'test': label, 'result': 'matched', 'frames': measure['frames'], 'snr_db': measure['snrDb'],
                        'peak_error': measure['peakError'], 'stats': stats})
        print(label, json.dumps(measure))

    # Every MPEG-1, MPEG-2 and MPEG-2.5 sample rate, with mono and stereo streams.
    for rate in (8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000):
        for channels in (1, 2):
            path = work / f'mp3-{rate}-{channels}.mp3'
            source = f'aevalsrc=0.15*sin(2*PI*997*t)+0.05*sin(2*PI*71*t)|0.12*sin(2*PI*431*t):s={rate}:d=0.35'
            bitrate = '128k' if rate >= 32000 else '64k' if rate >= 16000 else '32k'
            ffmpeg('-f', 'lavfi', '-i', source, '-ac', str(channels), '-c:a', 'libmp3lame', '-b:a', bitrate, path)
            check(path, channels == 1)
    # Impulses trigger short blocks; seeded noise exercises larger Huffman values.
    patterns = [
        ('noise', 'anoisesrc=r=44100:d=0.7:seed=9123:a=0.2'),
        ('transient', 'aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.7*sin(2*PI*9000*t)\\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=44100:d=0.7'),
        ('correlated', 'aevalsrc=0.2*sin(2*PI*1997*t)|0.19*sin(2*PI*1997*t):s=44100:d=0.7'),
    ]
    modes = {'cbr-stereo': ['-b:a', '192k', '-joint_stereo', '0'], 'cbr-joint': ['-b:a', '96k', '-joint_stereo', '1'],
             'vbr': ['-q:a', '4']}
    for name, source in patterns:
        for mode, coding in modes.items():
            path = work / f'mp3-{name}-{mode}.mp3'
            ffmpeg('-f', 'lavfi', '-i', source, '-ac', '2', '-c:a', 'libmp3lame', *coding, path)
            check(path, False)
    # Headerless tagging and unknown total length: no Xing/Info, no ID3v2.
    path = work / 'mp3-no-xing.mp3'
    ffmpeg('-f', 'lavfi', '-i', 'sine=frequency=771:sample_rate=44100:duration=0.2', '-c:a', 'libmp3lame', '-b:a',
           '128k', '-write_xing', '0', '-id3v2_version', '0', path)
    check(path, True)
    for name in node('mp3-vectors.js', work).splitlines():
        check(name.strip(), False)
    for name in node('mp3-malformed.js', work).splitlines():
        code, stats = check_file(name.strip())
        if code != 2:
            raise Failure(f'Malformed MP3 was not rejected: {name} {stats}')
        results.append({'test': Path(name.strip()).name, 'result': 'rejected', 'frames': 0, 'snr_db': None,
                        'peak_error': 0, 'stats': stats})
    if playback_requested(sys.argv[1:]):
        path = work / 'mp3-playback-silence.mp3'
        ffmpeg('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '1.2', '-c:a', 'libmp3lame', '-b:a', '128k', path)
        results.append({'test': 'mp3-playback-silence', 'result': 'played', 'frames': 57600, 'snr_db': None,
                        'peak_error': 0, 'stats': play(path)})
    report = out_dir() / 'mp3-verification.json'
    report.write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print(f'Passed {len(results)} MP3 checks. Report: {report}')


if __name__ == '__main__':
    main_guard(main)
