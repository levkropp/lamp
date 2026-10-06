#!/usr/bin/env python3
"""Output devices: --list-devices, --device and reconnection.

usage: python3 tests/verify-devices.py [--wine]
A private PulseAudio server gains two null sinks beside lamp_test.
- --list-devices lists every sink with its number, name and description.
- --device by name, description or number plays on that sink only: its
  monitor records the file bit for bit and the default sink stays silent;
  an unknown device exits 3 before playing; --device with --decode prints
  the usage.
- A stream the server kills during playback reopens where it was heard:
  the file continues to its end on a new stream.
- A sink removed during playback hands the stream to the default sink,
  where the file continues to its end.
- --wine runs the same with bin/lamp-cli.exe under Wine (WASAPI through
  Wine's PulseAudio driver): devices are endpoints with IDs and friendly
  names, and its playback is compared by order and position only, as Wine's
  driver drops audio here.
Writes <out>/devices-verification.json (devices-wine-verification.json
with --wine).
"""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import Failure, audio_environment, ffmpeg, main_guard, scratch, write_report

_spec = importlib.util.spec_from_file_location('verify_navigation',
                                               Path(__file__).resolve().parent / 'verify-navigation.py')
_nav = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_nav)
RATE, FRAME, START_SLACK = _nav.RATE, _nav.FRAME, _nav.START_SLACK
WINE = _nav.WINE


class Recorder:
    """Records one sink's monitor as float32 stereo at 48 kHz."""

    def __init__(self, env, sink, path):
        self.path = path
        self.process = subprocess.Popen(['parec', '-d', f'{sink}.monitor', '--format=float32le', f'--rate={RATE}',
                                         '--channels=2', '--raw', '--latency-msec=10'],
                                        stdout=open(path, 'wb'), env=env)

    def stop(self):
        self.process.send_signal(signal.SIGINT)
        self.process.wait(timeout=10)
        return Path(self.path).read_bytes()


def pactl(env, *arguments):
    result = subprocess.run(['pactl', *arguments], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=20)
    if result.returncode:
        raise Failure(f'pactl {arguments}: {result.stdout[-200:]}')
    return result.stdout.decode()


def main():
    work = scratch('devices-wine' if WINE else 'devices')
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required for the private test sinks.')
    checks = []
    modules = {}
    for name, description in (('lamp_second', 'Second test sink'), ('lamp_third', 'Third')):
        modules[name] = pactl(env, 'load-module', 'module-null-sink', f'sink_name={name}', 'format=float32le',
                              'rate=48000', 'channels=2',
                              f'sink_properties="device.description=\'{description}\'"').strip()
    pactl(env, 'load-module', 'module-cli-protocol-unix')    # for pacmd kill-sink-input
    time.sleep(0.5)

    def cli(*arguments, timeout=60):
        return subprocess.run(_nav.command(*arguments), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL, env=dict(env, **_nav.WINE_ENV) if WINE else env,
                              timeout=timeout)

    # --list-devices.
    result = cli('--list-devices')
    listed = [line.split('\t') for line in result.stdout.decode().replace('\r', '').splitlines()]
    if result.returncode or any(len(row) != 3 or not row[0].isdigit() for row in listed):
        raise Failure(f'--list-devices: exit {result.returncode}: {result.stdout[-300:]}')
    descriptions = [row[2] for row in listed]
    for description in ('Second test sink', 'Third'):
        if description not in descriptions:
            raise Failure(f'--list-devices lacks {description}: {listed}')
    if not WINE:
        sinks = {row[1]: row[2] for row in listed}
        if sinks.get('lamp_second') != 'Second test sink' or sinks.get('lamp_third') != 'Third' or \
                'lamp_test' not in sinks:
            raise Failure(f'--list-devices: {listed}')
    checks.append({'test': '--list-devices', 'result': 'listed', 'devices': listed})
    print(f'--list-devices: {len(listed)} devices: {", ".join(descriptions)}', flush=True)
    second = next(row for row in listed if row[2] == 'Second test sink')

    path = work / 'tone.flac'
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=3:seed=77:a=0.25', '-ac', '2', '-c:a', 'flac', path)
    reference = _nav.linux_decode(work, path)
    frames = len(reference) // FRAME

    # --device by name, description and number.
    for label, device in (('name', second[1]), ('description', second[2]), ('number', second[0])):
        quiet = Recorder(env, 'lamp_test', work / f'{label}-default.f32')
        recorder = Recorder(env, 'lamp_second', work / f'{label}.f32')
        time.sleep(0.5)
        result = cli('--device', device, path)
        time.sleep(0.8)
        capture, other = recorder.stop(), quiet.stop()
        if result.returncode:
            raise Failure(f'--device {device}: exit {result.returncode}: {result.stdout[-300:]}')
        found = _nav.runs(capture, {'tone': reference})
        if WINE:
            good = found and found[0][1] < RATE and found[-1][1] + found[-1][2] >= frames - RATE // 2
        else:
            good = len(found) == 1 and found[0][1] <= START_SLACK and found[0][1] + found[0][2] == frames
        if not good:
            raise Failure(f'--device by {label}: the second sink recorded {found}')
        if any(other):
            raise Failure(f'--device by {label}: the default sink played too')
        checks.append({'test': f'--device by {label}', 'result': 'played on that sink only', 'runs': found})
        print(f'--device by {label} ({device}): {found} on the second sink only', flush=True)
    result = cli('--device', 'no such device', path)
    if result.returncode != 3 or b'nknown audio device' not in result.stdout:
        raise Failure(f'an unknown device: exit {result.returncode}: {result.stdout[-300:]}')
    result = cli('--decode', '--device', 'lamp_second', path, work / 'x.f32')
    if not result.stdout.startswith(b'LAMP ') or (work / 'x.f32').exists():
        raise Failure('--device with --decode did not print the usage')
    checks.append({'test': 'unknown device and --decode', 'result': 'exit 3; usage'})
    print('an unknown device exits 3; --device with --decode prints the usage', flush=True)

    long_path = work / 'long.flac'
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=7:seed=78:a=0.25', '-ac', '2', '-c:a', 'flac', long_path)
    long_reference = _nav.linux_decode(work, long_path)
    long_frames = len(long_reference) // FRAME

    def ended(found):
        return found and found[-1][0] == 'long' and found[-1][1] + found[-1][2] >= long_frames - \
            (RATE // 2 if WINE else 0)

    # A killed stream reopens where it was heard.
    recorder = Recorder(env, 'lamp_test', work / 'killed.f32')
    time.sleep(0.5)
    process = subprocess.Popen(_nav.command(long_path), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, env=dict(env, **_nav.WINE_ENV) if WINE else env)
    time.sleep(3.5 + (_nav.WINE_STARTUP if WINE else 0))
    inputs = [line.split('\t')[0] for line in pactl(env, 'list', 'short', 'sink-inputs').splitlines() if line]
    if len(inputs) != 1:
        process.kill()
        raise Failure(f'expected one playback stream, found {inputs}')
    killed = subprocess.run(['pacmd', 'kill-sink-input', inputs[0]], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=20)
    if killed.returncode or killed.stdout.strip():
        process.kill()
        raise Failure(f'pacmd kill-sink-input: {killed.stdout[-200:]}')
    output, _ = process.communicate(timeout=60)
    time.sleep(0.8)
    capture = recorder.stop()
    found = _nav.runs(capture, {'long': long_reference})
    if process.returncode or b'reopening' not in output or len(found) < 2 or not ended(found) or \
            not any(-RATE <= b[1] - (a[1] + a[2]) <= RATE // 2 for a, b in zip(found, found[1:])):
        raise Failure(f'a killed stream: exit {process.returncode}, runs {found}: {output[-300:]}')
    checks.append({'test': 'killed stream reopens', 'result': 'continued to the end', 'runs': found})
    print(f'a killed stream reopens where it was heard: {found}', flush=True)

    # A removed sink hands the stream to the default sink.
    third = Recorder(env, 'lamp_third', work / 'removed-third.f32')
    default = Recorder(env, 'lamp_test', work / 'removed-default.f32')
    time.sleep(0.5)
    process = subprocess.Popen(_nav.command('--device', 'Third', long_path), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                               env=dict(env, **_nav.WINE_ENV) if WINE else env)
    time.sleep(3.0 + (_nav.WINE_STARTUP if WINE else 0))
    pactl(env, 'unload-module', modules['lamp_third'])
    output, _ = process.communicate(timeout=60)
    time.sleep(0.8)
    before, after = third.stop(), default.stop()
    first = _nav.runs(before, {'long': long_reference})
    rest = _nav.runs(after, {'long': long_reference})
    # The server moves the recorder of the removed monitor to the default one
    # too, so only the first run there was recorded on the removed sink.
    if process.returncode or not first or not ended(rest) or rest[0][1] < first[0][1] + first[0][2] - RATE:
        raise Failure(f'a removed sink: exit {process.returncode}, runs {first} then {rest}: {output[-300:]}')
    checks.append({'test': 'removed sink', 'result': 'continued on the default sink', 'runs': [first, rest]})
    print(f'a removed sink: {first} there, then {rest} on the default sink', flush=True)

    write_report('devices-wine' if WINE else 'devices',
                 {'result': 'passed', 'checks': checks,
                  'scope': '--list-devices; --device by name, description and number; unknown devices; a killed '
                           'stream reopening; a removed sink.'})
    print(f'Passed {len(checks)} device checks.')


if __name__ == '__main__':
    main_guard(main)
