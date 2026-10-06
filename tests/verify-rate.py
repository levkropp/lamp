#!/usr/bin/env python3
"""--rate: every file resampled to one rate by LAMP's own filter.

usage: python3 tests/verify-rate.py [--skip-playback] [--wine]
- --decode --rate 48000 of 44.1 kHz FLAC, WAV, MP3, Vorbis and AAC equals
  tests/resample-oracle.c resampling each file's own decode; --rate at a
  file's own rate changes nothing; a list at 44.1, 48 and 96 kHz resamples
  each file but the 48 kHz one.
- --start in a resampled file reads from the start exactly, as the queue
  seeks the decoder a filter half-width early and restarts the resampler.
- --check counts ceil(N * 48000 / 44100) frames; malformed or misplaced
  --rate arguments print the usage.
- Playback with --rate device on the private float32 48 kHz null sink plays
  a 44.1 kHz file bit for bit as --decode --rate 48000 gives it (the server
  does not resample), reports rate=48000, and seeks exactly within it; on a
  44.1 kHz sink chosen with --device it reports rate=44100.
- --wine runs the decodes with bin/lamp-cli.exe (exact as on Linux) and
  playback under Wine, where WASAPI's mix rate is the sink's and Wine's
  driver drops audio, so runs are compared by order.
Writes <out>/rate-verification.json (rate-wine-verification.json with --wine).
"""
import importlib.util
import math
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, audio_environment, build_lamp, build_oracles, exe, ffmpeg, main_guard, out_dir,
                       playback_requested, run, scratch, write_report)
from lamp_test import lamp_cli as lamp_cli_linux

_spec = importlib.util.spec_from_file_location('verify_navigation',
                                               Path(__file__).resolve().parent / 'verify-navigation.py')
_nav = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_nav)
WINE = _nav.WINE
FRAME = 8


def lamp(*arguments, expect=0, env=None):
    result = subprocess.run(_nav.command(*arguments), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, env=env or _nav.WINE_ENV, timeout=600)
    text = result.stdout.decode('utf-8', 'replace').replace('\r', '')
    if expect is not None and result.returncode != expect:
        raise Failure(f'lamp-cli {arguments[:4]}... exited {result.returncode}, expected {expect}: {text[-300:]}')
    return text


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'resample-oracle': 'resample-oracle.c'}, library)
    resampler = exe('resample-oracle')
    work = scratch('rate-wine' if WINE else 'rate')
    checks = []

    def decode(*arguments):
        target = work / 'decoded.f32'
        if target.exists():
            target.unlink()
        text = lamp('--decode', *arguments, target)
        return target.read_bytes(), text

    def own(path):
        return _nav.linux_decode(work, path)

    def resampled(path, rate_in, rate_out):
        source = work / 'own.f32'
        source.write_bytes(own(path))
        target = work / 'oracle.f32'
        run([resampler, rate_in, rate_out, source, target])
        data = target.read_bytes()
        if len(data) // FRAME != math.ceil(len(source.read_bytes()) // FRAME * rate_out / rate_in):
            raise Failure(f'{path.name}: the oracle gave {len(data) // FRAME} frames')
        return data

    files = {}
    for name, coding in (('flac', ['-c:a', 'flac']), ('wav', ['-c:a', 'pcm_s16le']),
                         ('mp3', ['-c:a', 'libmp3lame', '-b:a', '256k']), ('ogg', ['-c:a', 'libvorbis']),
                         ('m4a', ['-c:a', 'aac', '-aac_pns', '0'])):
        path = work / f'tone.{name}'
        ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r=44100:d=6:seed={len(files) + 3}:a=0.25', '-ac', '2', *coding, path)
        files[name] = path

    # Whole files at 48 kHz.
    references = {}
    for name, path in files.items():
        ours, text = decode('--rate', '48000', path)
        references[name] = resampled(path, 44100, 48000)
        if ours != references[name]:
            raise Failure(f'--rate 48000 {name}: {len(ours) // FRAME} frames differ from the oracle\'s '
                          f'{len(references[name]) // FRAME}')
        checks.append({'test': f'--rate 48000 {name}', 'result': 'exact', 'frames': len(ours) // FRAME})
        print(f'--rate 48000 {name}: {len(ours) // FRAME} frames exact', flush=True)
    ours, _ = decode('--rate', '44100', files['flac'])
    if ours != own(files['flac']):
        raise Failure('--rate at the file\'s own rate changed it')
    mixed = [files['flac'], work / 'r48.opus', work / 'r96.flac']
    ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=r=48000:d=1.5:seed=31:a=0.25', '-ac', '2', '-c:a', 'libopus', mixed[1])
    ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=r=96000:d=1.5:seed=32:a=0.25', '-ac', '2', '-c:a', 'flac', mixed[2])
    ours, _ = decode('--rate', '48000', *mixed)
    want = references['flac'] + own(mixed[1]) + resampled(mixed[2], 96000, 48000)
    if ours != want:
        raise Failure(f'a list at 44.1, 48 and 96 kHz: {len(ours) // FRAME} frames, not {len(want) // FRAME} exact')
    checks.append({'test': 'own rate and a list', 'result': 'exact'})
    print('--rate at the own rate changes nothing; a 44.1/48/96 kHz list resamples exactly', flush=True)

    # --start within resampled files.
    for name in ('flac', 'mp3', 'ogg', 'm4a'):
        for start in ('0.5', '3.7'):
            ours, _ = decode('--rate', '48000', '--start', start, files[name])
            skip = round(float(start) * 48000)
            if ours != references[name][skip * FRAME:]:
                raise Failure(f'--rate 48000 --start {start} {name}: not the whole decode from frame {skip}')
        checks.append({'test': f'--start in a resampled {name}', 'result': 'exact from 0.5 s and 3.7 s'})
    print('--start in resampled FLAC, MP3, Vorbis and AAC: exact', flush=True)

    # --check, and the usage.
    text = lamp('--check', '--rate', '48000', files['wav'])
    frames = int(text.strip().splitlines()[-1].split(' frames=')[1].split()[0])
    if frames != math.ceil(6 * 44100 * 48000 / 44100) or ' rate=48000' not in text:
        raise Failure(f'--check --rate 48000: {text.strip().splitlines()[-1]}')
    for arguments in (('--rate', '999', files['wav']), ('--rate', '768001', files['wav']),
                      ('--rate', '48k', files['wav']), ('--rate', '', files['wav']), ('--rate',),
                      ('--decode', '--rate', 'device', files['wav'], work / 'x.f32'),
                      ('--tags', '--rate', '48000', files['wav']), ('--list-devices', '--rate', '48000')):
        text = lamp(*arguments, expect=None)
        if not text.startswith('LAMP '):
            raise Failure(f'{arguments} did not print the usage: {text[:200]}')
    checks.append({'test': '--check and usage', 'result': 'frames counted; 8 misuses print the usage'})
    print('--check counts the resampled frames; 8 misuses print the usage', flush=True)

    if playback_requested(sys.argv[1:]):
        playback(work, files['flac'], references['flac'], checks)
    write_report('rate-wine' if WINE else 'rate', {
        'result': 'passed', 'checks': checks,
        'scope': '--rate decodes of five formats against the resampler oracle, lists, --start in resampled files, '
                 '--check, misuse, and --rate device playback on the private null sink.'})
    print(f'Passed {len(checks)} rate checks.')


def playback(work, path, reference, checks):
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required for the playback checks.')
    player_env = dict(env, **_nav.WINE_ENV) if WINE else env
    frames = len(reference) // FRAME
    # The whole file at the sink's rate.
    recorder = _nav.Recorder(env, work / 'device.f32')
    text = lamp('--rate', 'device', path, env=player_env)
    capture = recorder.stop()
    found = _nav.runs(capture, {'tone': reference})
    if WINE:
        good = found and found[0][1] < _nav.RATE and found[-1][1] + found[-1][2] >= frames - _nav.RATE // 2
    else:
        good = len(found) == 1 and found[0][1] <= _nav.START_SLACK and found[0][1] + found[0][2] == frames
    if not good or ' rate=48000' not in text:
        raise Failure(f'--rate device: {found}, {text.strip().splitlines()[-1:]}')
    checks.append({'test': '--rate device playback', 'result': 'the resampled decode, unresampled by the server',
                   'runs': found})
    print(f'--rate device on the 48 kHz sink: {found}, as --decode --rate 48000 gives it', flush=True)
    # Right: an exact jump within a longer resampled file.
    long_path = work / 'long.flac'
    ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=r=44100:d=12:seed=21:a=0.25', '-ac', '2', '-c:a', 'flac', long_path)
    long_reference = work / 'long48.f32'
    if long_reference.exists():
        long_reference.unlink()
    run([lamp_cli_linux(), '--decode', '--rate', '48000', long_path, long_reference])
    reference = long_reference.read_bytes()
    frames = len(reference) // FRAME
    recorder = _nav.Recorder(env, work / 'seek.f32')
    code, output = _nav.interactive(['--rate', 'device', long_path], env, [(3.0, b'\x1b[C')])
    capture = recorder.stop()
    found = _nav.runs(capture, {'tone': reference})
    jumps = [b[1] - (a[1] + a[2]) for a, b in zip(found, found[1:])]
    if len(found) < 2 or not any(5 * _nav.RATE - _nav.KEY_SLACK <= j <= 5 * _nav.RATE + _nav.KEY_SLACK
                                 for j in jumps) or found[-1][1] + found[-1][2] < frames - \
            (_nav.RATE // 2 if WINE else 0):
        raise Failure(f'Right in a resampled file: exit {code}, {found}: {output[-200:]}')
    checks.append({'test': 'seek in a resampled file', 'result': 'jumped 5 s and played to the end', 'runs': found})
    print(f'Right in a resampled file: {found}', flush=True)
    # A 44.1 kHz sink chosen with --device.
    module = subprocess.run(['pactl', 'load-module', 'module-null-sink', 'sink_name=lamp_cd', 'format=float32le',
                             'rate=44100', 'channels=2', "sink_properties=\"device.description='cd'\""], env=env,
                            stdout=subprocess.PIPE, check=True)
    try:
        time.sleep(0.5)
        device = 'lamp_cd'
        if WINE:
            for _ in range(2):         # Wine places a new endpoint once it has registered it
                listed = lamp('--list-devices', env=player_env)
            device = next(line.split('\t')[0] for line in listed.splitlines()
                          if line.count('\t') == 2 and 'cd' in line.split('\t')[2])
        text = lamp('--device', device, '--rate', 'device', path, env=player_env)
    finally:
        subprocess.run(['pactl', 'unload-module', module.stdout.decode().strip()], env=env,
                       stdout=subprocess.DEVNULL)
    if ' rate=44100' not in text:
        raise Failure(f'--rate device on a 44.1 kHz sink: {text.strip().splitlines()[-1:]}')
    checks.append({'test': '--rate device on a 44.1 kHz sink', 'result': 'rate=44100'})
    print('--rate device on a 44.1 kHz sink chosen with --device: rate=44100', flush=True)


if __name__ == '__main__':
    main_guard(main)
