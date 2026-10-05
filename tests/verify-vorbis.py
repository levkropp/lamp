#!/usr/bin/env python3
"""Ogg/Vorbis numerical checks against FFmpeg, generated Ogg vectors,
malformed-stream rejection and optional playback.

usage: python3 tests/verify-vorbis.py [--skip-playback]
Writes <out>/vorbis-verification.json.
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, check_file, compare_pcm, decode_f32, ffmpeg, main_guard, node, out_dir, play,
                       playback_requested, run, scratch, stats_frames)


def main():
    work = scratch()
    results = []

    def compare(path, mono):
        name = Path(path).name
        ours, reference = work / f'{name}.ours.f32', work / f'{name}.reference.f32'
        stats = decode_f32(path, ours)
        # FFmpeg's Ogg demuxer counts a first packet that only primes overlap.
        # Request untrimmed PCM, explicitly remove its initial delay, and trim to
        # the stream's final granule. This avoids its 128-sample end-trim discrepancy.
        frames = stats_frames(stats)
        vector = name.startswith('vorbis-vector-')
        decoder = []
        if vector:
            decoder = ['-c:a', 'libvorbis']
            filters = f'atrim=end_sample={frames}'
        else:
            probe = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'a', '-show_packets', '-show_entries',
                                    'packet=duration', '-of', 'json', path]))
            delay = int(probe['packets'][0]['duration'])
            filters = f'atrim=start_sample={delay}:end_sample={delay + frames}'
        if mono:
            filters += ',pan=stereo|c0=c0|c1=c0'
        ffmpeg(*decoder, '-flags2', '+skip_manual', '-i', path, '-af', filters, '-f', 'f32le', reference)
        # FFmpeg's libvorbis wrapper exposes signed 16-bit PCM. Its quantisation
        # limits SNR; allow two PCM LSBs for its integer transform rounding.
        measure = compare_pcm(ours, reference, 65, 0.000062) if vector else compare_pcm(ours, reference)
        results.append({'test': name, 'result': 'matched', 'frames': frames, 'snr_db': measure['snrDb'],
                        'peak_error': measure['peakError'], 'stats': stats})
        print(name, json.dumps(measure))

    for rate in (8000, 16000, 22050, 32000, 44100, 48000, 96000, 192000):
        for channels in (1, 2):
            for quality in (0, 8):
                path = work / f'vorbis-{rate}-{channels}-q{quality}.ogg'
                ffmpeg('-f', 'lavfi', '-i', f'aevalsrc=0.15*sin(2*PI*997*t)+0.03*sin(2*PI*71*t)|0.1*sin(2*PI*431*t):s={rate}:d=0.37',
                       '-ac', str(channels), '-c:a', 'libvorbis', '-q:a', str(quality), path)
                compare(path, channels == 1)
    for name, source in (('noise', 'anoisesrc=r=48000:d=1.3:a=0.2:seed=9812'),
                         ('transient', 'aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.7*sin(2*PI*9000*t)\\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=48000:d=1.3'),
                         ('silence', 'anullsrc=r=48000:cl=stereo:d=1.3')):
        path = work / f'vorbis-{name}.ogg'
        ffmpeg('-f', 'lavfi', '-i', source, '-ac', '2', '-c:a', 'libvorbis', '-q:a', '4', path)
        compare(path, False)
    for line in node('ogg-vectors.js', work).splitlines():
        entry = json.loads(line)
        if entry['valid']:
            compare(entry['path'], entry['mono'])
        else:
            code, stats = check_file(entry['path'])
            if code != 2:
                raise Failure(f"Malformed Ogg/Vorbis accepted {entry['path']} {stats}")
            results.append({'test': Path(entry['path']).name, 'result': 'rejected', 'frames': 0, 'snr_db': None,
                            'peak_error': 0, 'stats': stats})
    if playback_requested(sys.argv[1:]):
        results.append({'test': 'Vorbis playback', 'result': 'played', 'stats': play(work / 'vorbis-silence.ogg')})
    (out_dir() / 'vorbis-verification.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print(f'Passed {len(results)} Ogg/Vorbis checks.')


if __name__ == '__main__':
    main_guard(main)
