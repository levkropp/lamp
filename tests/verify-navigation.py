#!/usr/bin/env python3
"""Start positions, queue navigation and repeat.

usage: python3 tests/verify-navigation.py [--skip-playback]
- --start: --decode of ten formats from several start times equals their
  whole decode without the frames before the start, sample for sample (Opus
  after its state converges, within half a second; AC-3 within its dither);
  a
  start past the end gives nothing; in a queue only the first file starts
  late; --check counts the same frames; malformed times and misplaced
  options print the usage and decode nothing.
- Playback through a private PulseAudio null sink, driven by keys on a
  pseudo-terminal: --start, N (next), P (previous file, or the same file
  from its start after 3 s), N on the last file, the arrow keys (+5 s,
  -60 s), --repeat and the R key. The captured audio is cut into runs of
  the files' own decodes, which must follow the expected order and starts.
Writes <out>/navigation-verification.json.
"""
import array
import math
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (WINDOWS, Failure, audio_environment, decode_f32, ffmpeg, lamp_cli, main_guard, run, scratch,
                       stats_frames, write_report)

RATE = 48000
FRAME = 8                           # stereo float32 bytes
START_SLACK = 4800                  # frames the sink may lose as a stream starts
KEY_SLACK = RATE                    # a key's effect, against the time it was sent
# Opus resumes 80 ms or more before a seek target, and its decoder state
# reaches the continuous decode's within half a second (as tests/verify-seek.py
# compares Opus seeks with a reset reference rather than bit for bit).
CONVERGE = {'opus': 24000}
# AC-3 decoders dither zero-bit mantissas from a running generator (FFmpeg's
# encoder sets the dither flags), so its frames after a seek match within
# the dither only (tests/verify-ac3.py seeks dither-free streams exactly).
DITHERED = {'ac3': 50.0}


def snr(reference, ours):
    a, b = array.array('f', reference), array.array('f', ours)
    noise = sum((x - y) ** 2 for x, y in zip(a, b))
    return float('inf') if not noise else 10 * math.log10(sum(x * x for x in a) / noise)


def decode(work, paths, *options):
    """lamp-cli --decode with options -> stereo float32 bytes."""
    output = work / 'decoded.f32'
    if output.exists():
        output.unlink()
    result = subprocess.run([str(lamp_cli()), '--decode', *options, *[str(p) for p in paths], str(output)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise Failure(f'--decode {options} failed: {result.stdout[-300:]}')
    return output.read_bytes(), result.stdout.decode().strip().splitlines()[-1]


class Recorder:
    """Records the null sink's monitor as float32 stereo at 48 kHz."""

    def __init__(self, env, path):
        self.path = path
        self.process = subprocess.Popen(['parec', '-d', 'lamp_test.monitor', '--format=float32le', f'--rate={RATE}',
                                         '--channels=2', '--raw', '--latency-msec=10'],
                                        stdout=open(path, 'wb'), env=env)
        time.sleep(0.5)

    def stop(self):
        time.sleep(0.8)
        self.process.send_signal(signal.SIGINT)
        self.process.wait(timeout=10)
        return Path(self.path).read_bytes()


def interactive(arguments, env, actions):
    """Runs lamp-cli on a pseudo-terminal; actions are (delay seconds, bytes).
    -> (exit code, its output)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(lamp_cli()), ['lamp-cli', *[str(a) for a in arguments]], env)
    output = b''

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
        os.write(fd, action)
    deadline = time.time() + 60
    while time.time() < deadline:
        pump(0.1)
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            break
    else:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise Failure(f'Interactive playback did not exit: {arguments}')
    pump(0.1)
    os.close(fd)
    return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1, output.decode('utf-8', 'replace')


def runs(capture, references):
    """Cuts the capture into runs of the references (name -> bytes), skipping
    silence between them -> [(name, first frame, frames)]."""
    found = []
    position = 0
    zero = bytes(FRAME)
    while position + 256 * FRAME <= len(capture):
        if capture[position:position + FRAME] == zero:
            position += FRAME
            continue
        key = capture[position:position + 128 * FRAME]
        match = None
        for name, data in references.items():
            index = data.find(key)
            while index >= 0 and index % FRAME:
                index = data.find(key, index + 1)
            if index >= 0:
                match = (name, index)
                break
        if match is None:
            raise Failure(f'Captured audio at frame {position // FRAME} is in no reference '
                          f'(after {[(n, s, f) for n, s, f in found]})')
        name, index = match
        data = references[name]
        length = 0
        step = 4096 * FRAME
        while True:
            a = capture[position + length:position + length + step]
            b = data[index + length:index + length + step]
            if a and a == b:
                length += len(a)
                if len(a) < step:
                    break
                continue
            common = 0
            while common + FRAME <= min(len(a), len(b)) and a[common:common + FRAME] == b[common:common + FRAME]:
                common += FRAME
            length += common
            break
        found.append((name, index // FRAME, length // FRAME))
        position += length
    return found


def main():
    playback = '--skip-playback' not in sys.argv[1:] and not WINDOWS
    work = scratch('navigation')
    checks = []

    # --start: exact against the whole decode.
    sources = {'flac': ['-c:a', 'flac'], 'mp3': ['-c:a', 'libmp3lame'], 'ogg': ['-c:a', 'libvorbis'],
               'opus': ['-c:a', 'libopus'], 'm4a': ['-c:a', 'aac', '-aac_pns', '0'], 'wav': ['-c:a', 'pcm_s24le'],
               'wv': ['-c:a', 'wavpack'], 'mka': ['-c:a', 'alac'], 'ac3': ['-c:a', 'ac3'], 'mp2': ['-c:a', 'mp2']}
    for n, (extension, coding) in enumerate(sources.items()):
        path = work / f'start.{extension}'
        tones = f'0.3*sin(2*PI*{220 + 37 * n}*t)*sin(2*PI*0.7*t)+0.2*sin(2*PI*{1500 + 91 * n}*t)'  # no PNS in AAC
        ffmpeg('-f', 'lavfi', '-i', f'aevalsrc={tones}|{tones.replace("0.7", "0.9")}:s=44100:d=4.2', *coding, path)
        whole, stats = decode(work, [path])
        rate = int(stats.split(' rate=')[1].split()[0])
        for time_text, milliseconds in (('0.25', 250), ('1.5', 1500), ('0:02.125', 2125), ('0:00:03.9999', 3999),
                                        ('9', 9000)):
            ours, stats = decode(work, [path], '--start', time_text)
            skip = min(milliseconds * rate // 1000, len(whole) // FRAME) * FRAME
            settle = CONVERGE.get(extension, 0) * FRAME   # decoder state after a seek's pre-roll
            if extension in DITHERED:
                if len(ours) != len(whole) - skip or snr(whole[skip:], ours) < DITHERED[extension]:
                    raise Failure(f'{path.name} --start {time_text}: not within the dither of the whole decode')
            elif len(ours) != len(whole) - skip or ours[settle:] != whole[skip + settle:]:
                raise Failure(f'{path.name} --start {time_text}: {len(ours) // FRAME} frames differ from the whole '
                              f'decode after frame {skip // FRAME}')
            frames = stats_frames(run([lamp_cli(), '--check', '--start', time_text, path]).splitlines()[-1])
            if frames != len(ours) // FRAME:
                raise Failure(f'{path.name} --check --start {time_text}: {frames} frames, not {len(ours) // FRAME}')
        note = (f'exact after {CONVERGE[extension]} frames' if extension in CONVERGE else
                f'within the dither ({DITHERED[extension]:.0f} dB or more)' if extension in DITHERED else 'exact')
        checks.append({'test': f'{path.name} --start', 'result': note, 'starts': 5})
        print(f'{path.name}: five starts {note} against the whole decode', flush=True)
    first, second = work / 'start.flac', work / 'start.ogg'
    both, _ = decode(work, [first, second], '--start', '1.5')
    alone_first, _ = decode(work, [first], '--start', '1.5')
    alone_second, _ = decode(work, [second])
    if both != alone_first + alone_second:
        raise Failure('--start in a queue changed a later file')
    checks.append({'test': 'queue --start', 'result': 'exact', 'note': 'only the first file starts late'})
    print('queue: --start applies to the first file only', flush=True)
    for arguments in (['--decode', '--start'], ['--start', 'x', first], ['--start', '1:', first],
                      ['--start', '1:2:3:4', first], ['--start', '5.', first], ['--decode', '--repeat', first, 'x.f32'],
                      ['--tags', '--start', '1', first], ['--check', '--decode', first], ['--bogus', first]):
        result = subprocess.run([str(lamp_cli()), *[str(a) for a in arguments]], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=30)
        if not result.stdout.startswith(b'LAMP ') or (work / 'x.f32').exists():
            raise Failure(f'{arguments}: expected the usage, got {result.stdout[:200]}')
    checks.append({'test': 'option errors', 'result': 'usage', 'cases': 9})
    print('nine malformed times and misplaced options print the usage', flush=True)

    if playback:
        env = audio_environment()
        if env is None:
            raise Failure('PulseAudio (pulseaudio and parec) is required for the private test sink.')
        files = {}
        for name, seconds, seed in (('a', 6, 101), ('b', 3, 102), ('c', 2, 103), ('d', 14, 104), ('e', 1.2, 105)):
            path = work / f'nav-{name}.flac'
            ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d={seconds}:seed={seed}:a=0.25', '-ac', '2', '-c:a',
                   'flac', path)
            files[name] = path
        references = {name: decode(work, [path])[0] for name, path in files.items()}
        frames = {name: len(data) // FRAME for name, data in references.items()}

        def play(label, arguments, actions, expect):
            recorder = Recorder(env, work / f'{label}.capture.f32')
            code, output = interactive(arguments, env, actions)
            capture = recorder.stop()
            if code:
                raise Failure(f'{label}: exit {code}: {output[-300:]}')
            found = runs(capture, references)
            problem = expect(found)
            if problem:
                raise Failure(f'{label}: {problem}; runs {found}')
            checks.append({'test': label, 'result': 'passed', 'runs': [list(r) for r in found]})
            print(f'{label}: {", ".join(f"{n}[{s}:{s + f}]" for n, s, f in found)}', flush=True)

        def whole(run_, name, start=0):
            n, s, f = run_
            return n == name and start <= s <= start + START_SLACK and s + f == frames[name]

        def near(value, target, slack=KEY_SLACK):
            return abs(value - target) <= slack

        play('start', ['--start', '2.5', files['a']], [],
             lambda r: None if len(r) == 1 and whole(r[0], 'a', 120000) else 'expected a from 2.5 s to its end')
        play('next', [files['a'], files['b']], [(2.5, b'n')],
             lambda r: None if len(r) == 2 and r[0][0] == 'a' and r[0][1] <= START_SLACK and r[0][2] < frames['a']
             and whole(r[1], 'b') else 'expected part of a, then all of b')
        play('next on the last file', [files['a']], [(2.5, b'n')],
             lambda r: None if len(r) == 1 and r[0][0] == 'a' and r[0][2] < frames['a'] else 'expected part of a only')
        play('previous file', [files['c'], files['a']], [(3.6, b'p')],
             lambda r: None if len(r) == 4 and whole(r[0], 'c') and r[1][0] == 'a' and r[1][1] == 0
             and r[1][2] < 3 * RATE and whole(r[2], 'c') and whole(r[3], 'a')
             else 'expected c, part of a, then c and a again')
        play('previous restarts', [files['a']], [(5.0, b'P')],
             lambda r: None if len(r) == 2 and r[0][0] == 'a' and r[0][2] > 3 * RATE and whole(r[1], 'a')
             else 'expected a for over 3 s, then a from its start')
        play('seek', [files['d']], [(3.0, b'\x1b[C'), (2.5, b'\x1b[B')],
             lambda r: None if len(r) == 3 and r[0][0] == r[1][0] == r[2][0] == 'd'
             and near(r[1][1] - (r[0][1] + r[0][2]), 5 * RATE, RATE // 2) and whole(r[2], 'd')
             else 'expected d, d 5 s later, then d from its start')
        def repeated(r):
            if not r or any(n != 'e' for n, _, _ in r):
                return 'expected only e'
            if len(r) < 3 or any(s > START_SLACK for _, s, _ in r) or any(s + f != frames['e'] for _, s, f in r[:-1]):
                return 'expected e again and again from its start'
            return None
        play('--repeat', ['--repeat', files['e']], [(4.5, b'q')], repeated)
        play('R key', [files['e']], [(1.0, b'r'), (3.5, b'q')], repeated)
        play('R key twice', [files['e']], [(0.9, b'r'), (0.2, b'R')],
             lambda r: None if len(r) == 1 and whole(r[0], 'e') else 'expected e once')

    write_report('navigation', {'result': 'passed', 'checks': checks,
                                'scope': '--start against whole decodes in ten formats, queues and option errors; '
                                         'keys N/P, arrows, R and --repeat through the null sink.'})
    print(f'Passed {len(checks)} navigation checks.')


if __name__ == '__main__':
    main_guard(main)
