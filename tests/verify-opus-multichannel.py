#!/usr/bin/env python3
"""Opus mapping family 1 (1-8 speaker channels) against modern libopus with an
independent double-precision RFC 7845 stereo downmix.

usage: python3 tests/verify-opus-multichannel.py
Writes <out>/opus-multichannel-verification.json.
"""
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import Failure, compare_pcm, decode_f32, ffmpeg, ffmpeg_version, main_guard, scratch, write_report


def main():
    work = scratch('multichannel-opus')
    checks = []
    # Speaker labels avoid depending on FFmpeg's PCM channel order. Coefficients
    # follow RFC7845 Figures4-9, evaluated independently in double precision.
    q, a = 1 / math.sqrt(2), math.sqrt(3) / 2
    layouts = ['mono', 'stereo', '3.0', 'quad', '5.0', '5.1', '6.1', '7.1']
    speakers = [['FC'], ['FL', 'FR'], ['FL', 'FC', 'FR'], ['FL', 'FR', 'BL', 'BR'], ['FL', 'FC', 'FR', 'BL', 'BR'],
                ['FL', 'FC', 'FR', 'BL', 'BR', 'LFE'], ['FL', 'FC', 'FR', 'SL', 'SR', 'BC', 'LFE'],
                ['FL', 'FC', 'FR', 'SL', 'SR', 'BL', 'BR', 'LFE']]
    left = [[1], [1, 0], [1, q, 0], [1, 0, a, 0.5], [1, q, 0, a, 0.5], [1, q, 0, a, 0.5, q], [1, q, 0, a, 0.5, a * q, q],
            [1, q, 0, a, 0.5, a, 0.5, q]]
    right = [[1], [0, 1], [0, q, 1], [0, 1, 0.5, a], [0, q, 1, 0.5, a], [0, q, 1, 0.5, a, q], [0, q, 1, 0.5, a, a * q, q],
             [0, q, 1, 0.5, a, 0.5, a, q]]
    normal = [1, 1, 1 / (1 + q), 1 / (1 + a + 0.5), 2 / (1 + q + a + 0.5), 2 / (1 + 2 * q + a + 0.5),
              2 / (1 + 2 * q + a + 0.5 + a * q), 2 / (2 + 2 * q + 2 * a)]
    for channels in range(1, 9):
        for duration in ('2.5', '5', '10', '20', '40', '60', '120'):
            for vbr in ('on', 'off'):
                name = f'opus-family1-{channels}-{duration}-{vbr}.opus'
                path = work / name
                source = '|'.join(f'0.08*sin(2*PI*{113 + 79 * c}*t)+0.012*sin(2*PI*{3101 + 131 * c}*t)' for c in range(channels))
                application = 'lowdelay' if float(duration) < 10 else 'audio'
                ffmpeg('-f', 'lavfi', '-i', f'aevalsrc={source}:s=48000:d=0.73:c={layouts[channels - 1]}', '-c:a', 'libopus',
                       '-mapping_family', '1', '-application', application, '-frame_duration', duration, '-b:a',
                       str(48000 * channels), '-vbr', vbr, path)
                data = path.read_bytes()
                head = 27 + data[26]
                if data[head + 9] != channels or data[head + 18] != 1:
                    raise Failure('Encoder did not create the requested family1 header')
                ours, reference = work / f'{name}.ours.f32', work / f'{name}.reference.f32'
                stats = decode_f32(path, ours)
                terms = []
                for weights in (left[channels - 1], right[channels - 1]):
                    terms.append('+'.join(f'{repr(weights[c] * normal[channels - 1])}*{speakers[channels - 1][c]}'
                                          for c in range(channels) if weights[c] != 0))
                ffmpeg('-request_sample_fmt', 'flt', '-c:a', 'libopus', '-i', path, '-af',
                       f'aformat=sample_fmts=flt,pan=stereo|c0={terms[0]}|c1={terms[1]}', '-ar', '48000', '-c:a',
                       'pcm_f32le', '-f', 'f32le', reference)
                measure = compare_pcm(ours, reference, 60, 0.00004)
                checks.append({'test': name, 'result': 'matched', 'source_channels': channels, 'streams': data[head + 19],
                               'coupled_streams': data[head + 20], 'frames': measure['frames'], 'snr_db': measure['snrDb'],
                               'peak_error': measure['peakError'], 'stats': stats})
                print(name, json.dumps(measure))
    write_report('opus-multichannel', {
        'result': 'passed', 'scope': '112 independent modern-libopus Ogg family1 files,1..8 speaker channels,2.5..120ms packets,VBR/CBR and explicit RFC7845 stereo downmix; decoder PCM comparisons, not native surround output or chained Ogg',
        'minimum_snr_db': 60, 'maximum_absolute_error': 0.00004, 'ffmpeg_version': ffmpeg_version(), 'checks': checks})
    print(f'Passed {len(checks)} family 1 comparisons.')


if __name__ == '__main__':
    main_guard(main)
