#!/usr/bin/env python3
"""Linux playback and lifecycle checks through a private PulseAudio null sink.

usage: python3 tests/verify-playback.py
The sink records float32 at 48 kHz, so 48 kHz playback is compared bit for bit
with lamp-cli --decode. Covers every format, 5.1 downmixes, pause/resume
continuity, Q, Ctrl+C, resampled rates and a missing server.
Windows uses tests/verify-engine.ps1 for WASAPI. Writes <out>/playback-verification.json.
"""
import array
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (WINDOWS, Failure, audio_environment, decode_f32, ffmpeg, lamp_cli, main_guard, scratch,
                       write_report)

CAPTURE_START_TOLERANCE = 4800      # parec may miss up to 100 ms before its stream starts


class Recorder:
    """Records the null sink's monitor as float32 stereo."""

    def __init__(self, env, path):
        self.path = path
        self.process = subprocess.Popen(['parec', '-d', 'lamp_test.monitor', '--format=float32le', '--rate=48000',
                                         '--channels=2', '--raw', '--latency-msec=10'],
                                        stdout=open(path, 'wb'), env=env)
        time.sleep(0.5)

    def stop(self):
        time.sleep(0.8)
        self.process.send_signal(signal.SIGINT)
        self.process.wait(timeout=10)
        return array.array('f', Path(self.path).read_bytes())


def locate(capture, reference):
    """Returns the reference frame where the capture's audio begins, or None."""
    first = next((i for i in range(0, len(capture), 2) if capture[i] or capture[i + 1]), None)
    if first is None:
        return None, None
    key = capture[first:first + 128]
    for offset in range(0, min(len(reference) - 128, CAPTURE_START_TOLERANCE * 2), 2):
        if reference[offset:offset + 128] == key:
            return first, offset
    return first, None


def interactive(path, env, actions):
    """Runs lamp-cli on a pseudo-terminal; actions are (delay seconds, bytes or 'SIGINT')."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(lamp_cli()), ['lamp-cli', str(path)], env)
    output = b''
    started = time.time()

    def pump(seconds):
        nonlocal output
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.02)
            if ready:
                try:
                    output += os.read(fd, 4096)
                except OSError:
                    return
    for delay, action in actions:
        pump(delay)
        if action == 'SIGINT':
            os.kill(pid, signal.SIGINT)
        elif action:
            os.write(fd, action)
    deadline = time.time() + 30
    status = None
    while time.time() < deadline:
        pump(0.1)
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            break
    else:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise Failure(f'Interactive playback did not exit: {path}')
    pump(0.1)
    os.close(fd)
    text = output.decode('utf-8', 'replace').replace('\r', '')
    stats = next((line for line in text.splitlines() if line.startswith('codec=')), '')
    return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1, stats, time.time() - started


def require_clean(stats, label):
    if 'underruns=0 ' not in stats or 'endpoint_dry=0' not in stats or 'audio_error=0' not in stats:
        raise Failure(f'Queue counters not clean for {label}: {stats}')


def main():
    if WINDOWS:
        raise Failure('Use tests/verify-engine.ps1 for WASAPI playback on Windows.')
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required for the private test sink.')
    work = scratch('playback')
    checks = []
    signal_source = 'anoisesrc=r=48000:d=1.6:seed=4711:a=0.25[a];anoisesrc=r=48000:d=1.6:seed=4712:a=0.25[b];[a][b]amerge=inputs=2'
    encodings = {'wav': ['-c:a', 'pcm_s24le'], 'aiff': ['-c:a', 'pcm_s16be'], 'flac': ['-c:a', 'flac'],
                 'mp3': ['-c:a', 'libmp3lame', '-b:a', '192k'], 'ogg': ['-c:a', 'libvorbis', '-q:a', '5'],
                 'opus': ['-c:a', 'libopus', '-b:a', '128k']}
    cases = [(f'noise.{ext}', ['-filter_complex', signal_source] + coding) for ext, coding in encodings.items()]
    for layout, ext, coding in (('5.1', 'flac', ['-c:a', 'flac']), ('5.1', 'ogg', ['-c:a', 'libvorbis']),
                                ('5.1', 'opus', ['-c:a', 'libopus', '-mapping_family', '1', '-b:a', '256k'])):
        cases.append((f'surround-{layout}.{ext}', ['-f', 'lavfi', '-i', f'anoisesrc=r=48000:d=1.6:seed=99:a=0.2',
                                                   '-af', f'aformat=channel_layouts={layout}'] + coding))
    for name, args in cases:
        path = work / name
        if args[0] == '-filter_complex':
            ffmpeg(*args[:2], *args[2:], path)
        else:
            ffmpeg(*args, path)
        reference_path = work / (name + '.f32')
        decode_f32(path, reference_path)
        reference = array.array('f', reference_path.read_bytes())
        recorder = Recorder(env, work / (name + '.capture.f32'))
        result = subprocess.run([str(lamp_cli()), str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, env=env, timeout=60)
        capture = recorder.stop()
        stats = result.stdout.decode('utf-8', 'replace').strip().splitlines()[-1]
        if result.returncode:
            raise Failure(f'Playback failed for {name}: {stats}')
        require_clean(stats, name)
        first, offset = locate(capture, reference)
        if offset is None:
            raise Failure(f'Played audio not found in the capture: {name}')
        remaining = len(reference) - offset
        exact = capture[first:first + remaining] == reference[offset:]
        silent_after = not any(capture[first + remaining:first + remaining + 9600])
        if not exact or not silent_after:
            raise Failure(f'Captured playback differs from --decode output: {name}')
        checks.append({'test': name, 'result': 'bit-exact', 'frames': len(reference) // 2,
                       'compared_frames': remaining // 2, 'stats': stats})
        print(f'{name}: {remaining // 2} frames bit-exact; {stats}', flush=True)

    # Pause/resume: audio after each pause continues the stream and plays to the
    # end. On cork the server rewinds audio it rendered but had not played; its
    # monitor mirrors that boundary only approximately, so a resume may repeat or
    # skip a few frames there. Everything else must match exactly.
    # The idle null sink can take over a second to start, so pause well after that.
    path = work / 'pause-noise.flac'
    ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=r=48000:d=7:seed=8128:a=0.25', '-ac', '2', '-c:a', 'flac', path)
    decode_f32(path, work / 'pause-noise.flac.f32')
    reference = array.array('f', (work / 'pause-noise.flac.f32').read_bytes())
    recorder = Recorder(env, work / 'pause.capture.f32')
    code, stats, _ = interactive(path, env, [(3.0, b' '), (0.6, b' '), (0.8, b' '), (0.6, b' ')])
    capture = recorder.stop()
    if code:
        raise Failure(f'Pause/resume playback failed: {stats}')
    require_clean(stats, 'pause/resume')
    first, offset = locate(capture, reference)
    if offset is None:
        raise Failure('Pause/resume audio not found in the capture')
    position, cursor, gaps, boundary = offset, first, 0, 0
    while position < len(reference) and cursor < len(capture):
        if capture[cursor] == reference[position] and capture[cursor + 1] == reference[position + 1]:
            position += 2
            cursor += 2
            continue
        silence = cursor
        while silence < len(capture) and not capture[silence] and not capture[silence + 1]:
            silence += 2
        if silence == cursor:
            raise Failure(f'Pause/resume audio diverges at reference frame {position // 2}')
        key = capture[silence:silence + 128]
        window = range(max(0, position - 19200), min(len(reference) - 128, position + 19200), 2)
        resumed = next((p for p in window if reference[p:p + 128] == key), None)
        if resumed is None:
            raise Failure(f'Audio after a pause does not continue the stream at frame {position // 2}')
        boundary = max(boundary, abs(position - resumed) // 2)
        gaps += 1
        position, cursor = resumed, silence
    if position < len(reference) or gaps != 2:
        raise Failure(f'Pause/resume capture incomplete: {gaps} pauses, reference frame {position // 2}')
    checks.append({'test': 'pause/resume continuity', 'result': 'passed', 'pauses': gaps,
                   'maximum_pause_boundary_frames': boundary, 'stats': stats})
    print(f'pause/resume: two pauses, stream continuous to the end, pause boundaries within {boundary} frames')

    long_path = work / 'tone-6s.flac'
    ffmpeg('-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000:duration=6', '-ac', '2', '-c:a', 'flac', long_path)
    for label, actions in (('quit with Q', [(1.5, b'q')]), ('Ctrl+C', [(1.5, 'SIGINT')])):
        code, stats, took = interactive(long_path, env, actions)
        if code or not stats or took > 4:
            raise Failure(f'{label} did not stop playback promptly: exit {code}, {took:.2f}s, {stats}')
        require_clean(stats, label)
        checks.append({'test': label, 'result': 'stopped', 'seconds': round(took, 2), 'stats': stats})
        print(f'{label}: stopped after {took:.2f}s')

    for rate, channels in ((8000, 1), (44100, 2), (96000, 2)):
        path = work / f'rate-{rate}-{channels}.flac'
        ffmpeg('-f', 'lavfi', '-i', f'sine=frequency=700:sample_rate={rate}:duration=0.8', '-ac', str(channels),
               '-c:a', 'flac', path)
        result = subprocess.run([str(lamp_cli()), str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, env=env, timeout=60)
        stats = result.stdout.decode('utf-8', 'replace').strip().splitlines()[-1]
        if result.returncode:
            raise Failure(f'Resampled playback failed at {rate} Hz: {stats}')
        require_clean(stats, f'{rate} Hz')
        checks.append({'test': f'{rate} Hz {channels} channel(s), server resampling', 'result': 'played', 'stats': stats})
        print(f'{rate} Hz: played through server resampling')

    missing = dict(env, PULSE_SERVER='unix:' + str(work / 'no-server'))
    result = subprocess.run([str(lamp_cli()), str(work / 'noise.wav')], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=missing, timeout=30)
    text = result.stdout.decode('utf-8', 'replace')
    if result.returncode != 3 or 'Audio output unavailable' not in text:
        raise Failure(f'Missing server was not reported: exit {result.returncode} {text}')
    checks.append({'test': 'missing server', 'result': 'exit 3', 'message': text.strip()})
    print('missing server: exit 3 with a message')

    write_report('playback', {'result': 'passed', 'platform': 'linux-x86_64', 'output': 'PulseAudio native protocol',
                              'sink': 'private null sink, float32le 48 kHz stereo',
                              'scope': 'Bit-exact 48 kHz playback for WAV/AIFF/FLAC/MP3/Vorbis/Opus and 5.1 downmixes; pause/resume continuity; Q and Ctrl+C; resampled rates; missing server. Measures delivered PCM, not audible latency or real-device behaviour.',
                              'checks': checks})
    print(f'Passed {len(checks)} playback checks.')


if __name__ == '__main__':
    main_guard(main)
