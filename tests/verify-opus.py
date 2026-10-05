#!/usr/bin/env python3
"""Independent modern-libopus PCM comparisons for 51 generated Ogg/Opus files.

usage: python3 tests/verify-opus.py
Writes <out>/opus-verification.json.
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import compare_pcm, decode_f32, ffmpeg, ffmpeg_version, main_guard, scratch, write_report


def main():
    work = scratch()
    checks = []

    def check(path, channels):
        name = Path(path).name
        ours, reference = work / f'{name}.ours.f32', work / f'{name}.reference.f32'
        stats = decode_f32(path, ours)
        args = ['-c:a', 'libopus', '-i', path, '-ar', '48000']
        if channels == 1:
            args += ['-af', 'pan=stereo|c0=c0|c1=c0']
        ffmpeg(*args, '-c:a', 'pcm_f32le', '-f', 'f32le', reference)
        # 16-bit SILK output in the normative decoder can differ from modern
        # libopus float output by a fraction of one int16 LSB. Require bounded
        # absolute error and >=60dB SNR for these non-silent synthetic signals.
        measure = compare_pcm(ours, reference, 60, 0.00004)
        checks.append({'test': name, 'result': 'matched', 'frames': measure['frames'], 'snr_db': measure['snrDb'],
                       'peak_error': measure['peakError'], 'stats': stats})
        print(name, json.dumps(measure))

    for rate in (8000, 16000, 48000):
        for channels in (1, 2):
            for duration in ('2.5', '5', '10', '20', '40', '60', '120'):
                path = work / f'opus-{rate}-{channels}-{duration}.opus'
                source = f'aevalsrc=0.15*sin(2*PI*997*t)+0.05*sin(2*PI*71*t)|0.12*sin(2*PI*431*t):s={rate}:d=0.37'
                frame = float(duration)
                application = 'lowdelay' if frame < 10 else 'voip' if rate < 48000 else 'audio'
                bitrate = '24k' if rate < 48000 and frame >= 10 else '64k'
                ffmpeg('-f', 'lavfi', '-i', source, '-ac', str(channels), '-c:a', 'libopus', '-application', application,
                       '-frame_duration', duration, '-b:a', bitrate, path)
                check(path, channels)
    patterns = [('noise', 'anoisesrc=r=48000:d=0.63:seed=928:a=0.2'),
                ('transient', 'aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.7*sin(2*PI*9000*t)\\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=48000:d=0.63'),
                ('silence', 'anullsrc=r=48000:cl=stereo:d=0.63')]
    for name, source in patterns:
        for vbr in ('off', 'on', 'constrained'):
            path = work / f'opus-{name}-{vbr}.opus'
            ffmpeg('-f', 'lavfi', '-i', source, '-ac', '2', '-c:a', 'libopus', '-b:a', '48k', '-vbr', vbr, '-fec', '1',
                   '-packet_loss', '20', path)
            check(path, 2)
    write_report('opus', {'result': 'passed', 'scope': '51 generated Ogg/Opus files; independent modern libopus PCM comparisons at 48kHz, mono/stereo, input rates,2.5..120ms packet durations, VBR/CBR/constrained VBR,noise/transients/silence/FEC; not official conformance',
                          'minimum_snr_db': 60, 'maximum_absolute_error': 0.00004, 'ffmpeg_version': ffmpeg_version(),
                          'checks': checks})
    print(f'Passed {len(checks)} modern-libopus comparisons.')


if __name__ == '__main__':
    main_guard(main)
