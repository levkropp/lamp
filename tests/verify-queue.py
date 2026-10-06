#!/usr/bin/env python3
"""Several files in one lamp-cli run: a gapless queue.

usage: python3 tests/verify-queue.py
- Files at the first file's rate (FLAC, WAV, MP3, AAC, WavPack, Vorbis, ALAC)
  decode to the exact concatenation of their own decodes; --check counts the
  same frames.
- Files at other rates (Opus, 22.05/32/96 kHz, 8 kHz) are resampled to the
  first file's rate exactly as tests/resample-oracle.c resamples their own
  decodes, also when the first file is at 48 kHz.
- Chained Ogg files: a chain at another rate is resampled; a chain whose
  links change rate plays when the session runs at its rate and is skipped
  otherwise.
- Files that do not open are skipped with a message (exit 2); a file that
  fails while decoding contributes what it decoded and the queue continues;
  the last file's own error is kept; a queue where nothing opens fails.
Playback of a queue through the null sink is in tests/verify-playback.py.
Writes <out>/queue-verification.json.
"""
import json
import math
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, lamp_cli, main_guard, out_dir, run,
                       scratch, write_report)


def lamp(*args, expect=0):
    result = subprocess.run([str(lamp_cli()), *[str(a) for a in args]], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    text = result.stdout.decode('utf-8', 'replace')
    if result.returncode != expect:
        raise Failure(f'lamp-cli {" ".join(str(a) for a in args[:3])}... exited {result.returncode}, expected '
                      f'{expect}: {text[-400:]}')
    return text


def stat(text, key):
    line = text.strip().splitlines()[-1]
    return int(line.split(f' {key}=')[1].split()[0]) if f' {key}=' in line else int(line.split(f'{key}=')[1].split()[0])


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'resample-oracle': 'resample-oracle.c'}, library)
    resampler = exe('resample-oracle')
    work = scratch('queue')
    checks = []

    def source(rate, seconds, seed, channels=2):
        return ['-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d={seconds}:seed={seed}:a=0.25', '-ac', str(channels)]

    def own(path):
        target = Path(str(path) + '.own.f32')
        decode_f32(path, target)
        return target.read_bytes()

    def resampled(path, rate_in, rate_out):
        target = Path(str(path) + f'.{rate_out}.f32')
        own(path)
        run([resampler, str(rate_in), str(rate_out), Path(str(path) + '.own.f32'), target])
        data = target.read_bytes()
        frames = len(Path(str(path) + '.own.f32').read_bytes()) // 8
        if len(data) // 8 != math.ceil(frames * rate_out / rate_in):
            raise Failure(f'{path.name}: {len(data) // 8} resampled frames')
        return data

    def decode(name, inputs, expect=0):
        target = work / name
        if target.exists():
            target.unlink()
        text = lamp('--decode', *inputs, target, expect=expect)
        return target.read_bytes() if target.exists() else b'', text

    def record(test, ours, reference, note, text):
        if ours != reference:
            raise Failure(f'{test}: {len(ours) // 8} frames differ from the reference ({len(reference) // 8})')
        line = text.strip().splitlines()[-1]
        checks.append({'test': test, 'result': 'exact', 'frames': len(ours) // 8, 'note': note, 'stats': line})
        print(f'{test}: {len(ours) // 8} frames exact ({note})', flush=True)

    # Same rate.
    files = []
    for k, (name, coding) in enumerate((('a.flac', ['-c:a', 'flac']), ('b.wav', ['-c:a', 'pcm_s24le']),
                                        ('c.mp3', ['-c:a', 'libmp3lame']), ('d.m4a', ['-c:a', 'aac']),
                                        ('e.wv', ['-c:a', 'wavpack']), ('f.ogg', ['-c:a', 'libvorbis']),
                                        ('g.m4a', ['-c:a', 'alac']), ('h.wav', ['-c:a', 'pcm_u8']))):
        path = work / name
        ffmpeg(*source(44100, 0.4 + 0.1 * k, k + 1, 1 if name == 'h.wav' else 2), *coding, path)
        files.append(path)
    ours, text = decode('same-rate.f32', files)
    record('same-rate', ours, b''.join(own(p) for p in files), 'eight formats at 44.1 kHz', text)
    text = lamp('--check', *files)
    if stat(text, 'frames') != len(ours) // 8:
        raise Failure(f'--check counted {stat(text, "frames")} frames')
    checks.append({'test': '--check same rate', 'result': 'frames match', 'stats': text.strip().splitlines()[-1]})

    # Other rates, resampled to the first file's.
    others = []
    for k, (name, rate, coding) in enumerate((('r48.opus', 48000, ['-c:a', 'libopus']),
                                              ('r22.mp3', 22050, ['-c:a', 'libmp3lame']),
                                              ('r96.flac', 96000, ['-c:a', 'flac']),
                                              ('r8.wav', 8000, ['-c:a', 'pcm_s16le']),
                                              ('r32.ogg', 32000, ['-c:a', 'libvorbis']))):
        path = work / name
        ffmpeg(*source(rate, 0.5, 40 + k), *coding, path)
        others.append((path, 48000 if name.endswith('.opus') else rate))
    queue = [files[0], others[0][0], files[1], others[1][0], others[2][0], others[3][0], others[4][0], files[2]]
    reference = (own(files[0]) + resampled(others[0][0], others[0][1], 44100) + own(files[1]) +
                 resampled(others[1][0], others[1][1], 44100) + resampled(others[2][0], others[2][1], 44100) +
                 resampled(others[3][0], others[3][1], 44100) + resampled(others[4][0], others[4][1], 44100) +
                 own(files[2]))
    ours, text = decode('mixed-rates.f32', queue)
    record('mixed-rates', ours, reference, 'Opus 48, MP3 22.05, FLAC 96, WAV 8 and Vorbis 32 kHz resampled to 44.1',
           text)
    queue = [others[0][0], files[0], others[3][0]]
    reference = own(others[0][0]) + resampled(files[0], 44100, 48000) + resampled(others[3][0], 8000, 48000)
    ours, text = decode('from-48k.f32', queue)
    record('from-48k', ours, reference, 'a 48 kHz session', text)

    # Chained Ogg files.
    links = []
    for k, (name, rate, coding) in enumerate((('link1.ogg', 48000, ['-c:a', 'libvorbis']),
                                              ('link2.opus', 48000, ['-c:a', 'libopus']),
                                              ('link3.oga', 32000, ['-c:a', 'flac']))):
        path = work / name
        ffmpeg(*source(rate, 0.4, 60 + k), *coding, '-f', 'ogg', path)
        links.append(path.read_bytes())
    uniform, mixed = work / 'uniform-chain.ogg', work / 'mixed-chain.ogg'
    uniform.write_bytes(links[0] + links[1])
    mixed.write_bytes(links[0] + links[2])
    ours, text = decode('chain-resampled.f32', [files[0], uniform])
    record('chain-resampled', ours, own(files[0]) + resampled(uniform, 48000, 44100),
           'a 48 kHz chain resampled to 44.1 kHz', text)
    ours, text = decode('chain-own-rate.f32', [others[0][0], mixed])
    record('chain-own-rate', ours, own(others[0][0]) + own(mixed), "a chain resampling its own links at the "
           "session's rate", text)
    ours, text = decode('chain-skipped.f32', [files[0], mixed, files[1]], expect=2)
    if 'Skipped' not in text or ' decode_error=6 ' not in text.splitlines()[-1] + ' ':
        raise Failure(f'chain-skipped: {text[-300:]}')
    record('chain-skipped', ours, own(files[0]) + own(files[1]), 'a chain whose links change rate, at another rate',
           text)

    # Failures.
    junk, missing = work / 'junk.bin', work / 'missing.flac'
    junk.write_bytes(b'not audio' * 100)
    if missing.exists():
        missing.unlink()
    ours, text = decode('unopenable.f32', [files[0], junk, missing, files[1]], expect=2)
    if text.count('Skipped') != 2:
        raise Failure(f'unopenable: {text[-300:]}')
    record('unopenable', ours, own(files[0]) + own(files[1]), 'two files skipped, exit 2', text)
    flac = files[0].read_bytes()
    broken = work / 'broken.flac'
    broken.write_bytes(flac[:len(flac) // 2])
    partial, _ = decode('broken-alone.f32', [broken], expect=2)
    ours, text = decode('broken-middle.f32', [files[1], broken, files[2]], expect=2)
    record('broken-middle', ours, own(files[1]) + partial + own(files[2]), 'a truncated file in the middle', text)
    ours, text = decode('broken-last.f32', [files[1], broken], expect=2)
    if ' decode_error=6 ' in text.splitlines()[-1] + ' ':
        raise Failure('broken-last: the last file should keep its own error')
    record('broken-last', ours, own(files[1]) + partial, "the last file's own error kept", text)
    text = lamp('--decode', junk, missing, work / 'none.f32', expect=2)
    if 'Unsupported' not in text:
        raise Failure(f'none: {text[-300:]}')
    checks.append({'test': 'nothing opens', 'result': 'rejected', 'output': text.strip().splitlines()[-1]})
    text = lamp('--check', junk, files[0], expect=2)
    checks.append({'test': '--check with a skipped file', 'result': 'exit 2', 'stats': text.strip().splitlines()[-1]})
    print('Failure cases behave as documented', flush=True)

    write_report('queue', {'result': 'passed', 'checks': checks,
                           'scope': 'Gapless queues of several files: exact concatenation at one rate, resampling '
                                    'to the first file\'s rate against the resampler oracle, chained Ogg files, '
                                    'skipped and failing files.'})
    print(f'Passed {len(checks)} queue checks.')


if __name__ == '__main__':
    main_guard(main)
