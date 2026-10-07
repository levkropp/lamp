#!/usr/bin/env python3
"""Start positions, queue navigation and repeat.

usage: python3 tests/verify-navigation.py [--skip-playback] [--wine]
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
- --resume: Q keeps the list's heard file and position in the state file,
  the next run starts there (in a later file of a list too), playing to the
  end forgets the list, --start wins, other lists' lines stay, malformed
  lines are dropped and at most 256 lines are kept.
- --wine runs the same checks against bin/lamp-cli.exe under Wine: its
  decodes must equal the Linux build's whole decodes the same way, and its
  playback (through Wine's PulseAudio driver, which drops audio here) must
  show the same files, jumps and restarts in order.
Writes <out>/navigation-verification.json (navigation-wine-verification.json
with --wine).
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
from lamp_test import (ROOT, WINDOWS, Failure, audio_environment, decode_f32, ffmpeg, lamp_cli, main_guard, run,
                       scratch, stats_frames, write_report)

WINE = '--wine' in sys.argv[1:]
WINE_ENV = dict(os.environ, WINEPREFIX=os.environ.get('WINEPREFIX', str(Path.home() / '.wine')), WINEDEBUG='-all',
                LANG='C.UTF-8')


def command(*arguments):
    """The player under test: the Linux lamp-cli, or lamp-cli.exe under Wine."""
    if WINE:
        return ['wine', str(ROOT / 'bin' / 'lamp-cli.exe'), *[str(a) for a in arguments]]
    return [str(lamp_cli()), *[str(a) for a in arguments]]


def linux_decode(work, path):
    output = work / 'linux.f32'
    if output.exists():
        output.unlink()
    run([lamp_cli(), '--decode', path, output])
    return output.read_bytes()

RATE = 48000
FRAME = 8                           # stereo float32 bytes
START_SLACK = 4800                  # frames the sink may lose as a stream starts
KEY_SLACK = RATE                    # a key's effect, against the time it was sent
# Opus resumes 80 ms or more before a seek target, and its decoder state
# reaches the continuous decode's within half a second (as tests/verify-seek.py
# compares Opus seeks with a reset reference rather than bit for bit).
CONVERGE = {'opus': 24000}
WINE_STARTUP = 1.5                  # Wine starts a program this much later
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
    result = subprocess.run(command('--decode', *options, *paths, output), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=WINE_ENV)
    if result.returncode:
        raise Failure(f'--decode {options} failed: {result.stdout[-300:]}')
    return output.read_bytes(), result.stdout.decode().replace('\r', '').strip().splitlines()[-1]


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


def interactive(arguments, env, actions, ready_text=None):
    """Runs lamp-cli on a pseudo-terminal; actions are (delay, bytes/callback).
    A callback can wait for captured PCM and return the next key's bytes.
    -> (exit code, its output)."""
    pid, fd = pty.fork()
    if pid == 0:
        argv = command(*arguments)
        os.execvpe(argv[0], argv, dict(env, **WINE_ENV) if WINE else env)
    output = b''
    reaped = False

    def pump(seconds):
        nonlocal output
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            ready, _, _ = select.select([fd], [], [], 0.02)
            if ready:
                try:
                    output += os.read(fd, 4096)
                except OSError:
                    return
    try:
        if ready_text is not None:
            deadline = time.monotonic() + 60
            while ready_text not in output:
                pump(0.05)
                finished, status = os.waitpid(pid, os.WNOHANG)
                if finished:
                    reaped = True
                    raise Failure(f'Playback exited before ready: {output[-1000:]}')
                if time.monotonic() >= deadline:
                    raise Failure(f'Playback did not become ready: {output[-1000:]}')
        for n, (delay, action) in enumerate(actions):
            pump(delay + (WINE_STARTUP if WINE and n == 0 and ready_text is None else 0))
            key = action() if callable(action) else action
            if key is not None:
                os.write(fd, key)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            pump(0.1)
            finished, status = os.waitpid(pid, os.WNOHANG)
            if finished:
                reaped = True
                break
        else:
            raise Failure(f'Interactive playback did not exit: {arguments}')
        pump(0.1)
        return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1, output.decode('utf-8', 'replace')
    finally:
        if not reaped:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)


def resume_state(env):
    """The state file the player under test keeps."""
    if WINE:
        local = subprocess.run(['wine', 'cmd', '/c', 'echo %LOCALAPPDATA%'], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=WINE_ENV).stdout.decode().strip()
        return Path(wine_unix(local)) / 'LAMP' / 'resume.txt'
    return Path(env['HOME']) / '.local' / 'state' / 'lamp' / 'resume'


def wine_unix(path):
    return subprocess.run(['winepath', '-u', path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env=WINE_ENV).stdout.decode().strip()


def wine_path(path):
    """A Unix path as the Windows player's absolute path for it."""
    return subprocess.run(['winepath', '-w', str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env=WINE_ENV).stdout.decode().strip()


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
            # Wine can leave fewer than 128 exact frames between dropouts.
            # Match the entire non-silent fragment when silence cuts the
            # fingerprint short; every captured frame must still be exact.
            end = position + FRAME
            while end < position + 128 * FRAME and capture[end:end + FRAME] != zero:
                end += FRAME
            if end < position + 128 * FRAME:
                key = capture[position:end]
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


def check_capture_fragments():
    """Short exact fragments before a dropout pass; changed samples fail."""
    import struct
    reference = b''.join(struct.pack('<ff', i + 1, -i - 1) for i in range(1024))
    silence = bytes(512 * FRAME)
    for length in (1, 32, 126, 128):
        capture = reference[10 * FRAME:(10 + length) * FRAME] + silence + reference[400 * FRAME:600 * FRAME] + silence
        if runs(capture, {'fixture': reference}) != [('fixture', 10, length), ('fixture', 400, 200)]:
            raise Failure(f'Capture matcher loses a {length}-frame fragment')
    damaged = reference[10 * FRAME:30 * FRAME] + struct.pack('<ff', 123456, -123456) + silence
    try:
        runs(damaged, {'fixture': reference})
    except Failure:
        return
    raise Failure('Capture matcher accepts a changed sample')


def main():
    playback = '--skip-playback' not in sys.argv[1:] and not WINDOWS
    work = scratch('navigation-wine' if WINE else 'navigation')
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
        if WINE and whole != linux_decode(work, path):
            raise Failure(f'{path.name}: the Windows decode differs from the Linux one')
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
            frames = stats_frames(run(command('--check', '--start', time_text, path),
                                      env=WINE_ENV).replace('\r', '').splitlines()[-1])
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
        result = subprocess.run(command(*arguments), stdout=subprocess.PIPE, env=WINE_ENV,
                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=60)
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

        def play(label, arguments, actions, expect, loose=None):
            if WINE and loose is None:
                return
            recorder = Recorder(env, work / f'{label}.capture.f32')
            code, output = interactive(arguments, env, actions)
            capture = recorder.stop()
            if code:
                raise Failure(f'{label}: exit {code}: {output[-300:]}')
            found = runs(capture, references)
            problem = (loose if WINE else expect)(found)
            if problem:
                raise Failure(f'{label}: {problem}; runs {found}')
            checks.append({'test': label, 'result': 'passed', 'runs': [list(r) for r in found]})
            print(f'{label}: {", ".join(f"{n}[{s}:{s + f}]" for n, s, f in found)}', flush=True)

        def whole(run_, name, start=0):
            n, s, f = run_
            return n == name and start <= s <= start + START_SLACK and s + f == frames[name]

        def near(value, target, slack=KEY_SLACK):
            return abs(value - target) <= slack

        def order(r):
            """File names in order, with each run's (start, end)."""
            names = []
            for n, s, f in r:
                if not names or names[-1][0] != n:
                    names.append([n, []])
                names[-1][1].append((s, s + f))
            return names

        def ends(run_, name):
            """Under Wine: a run reaching within half a second of the file's end."""
            return run_[0] == name and run_[1] + run_[2] >= frames[name] - RATE // 2

        def jumps(spans):
            """Moves between consecutive runs of one file: (forward frames) list."""
            return [b[0] - a[1] for a, b in zip(spans, spans[1:])]

        play('start', ['--start', '2.5', files['a']], [],
             lambda r: None if len(r) == 1 and whole(r[0], 'a', 120000) else 'expected a from 2.5 s to its end',
             lambda r: None if r and r[0][0] == 'a' and 120000 <= r[0][1] < 120000 + RATE
             and ends(r[-1], 'a') else 'expected a from 2.5 s to its end')
        play('next', [files['a'], files['b']], [(2.5, b'n')],
             lambda r: None if len(r) == 2 and r[0][0] == 'a' and r[0][1] <= START_SLACK and r[0][2] < frames['a']
             and whole(r[1], 'b') else 'expected part of a, then all of b',
             lambda r: None if [n for n, _ in order(r)] == ['a', 'b'] and order(r)[0][1][-1][1] < frames['a']
             and order(r)[1][1][0][0] < RATE and order(r)[1][1][-1][1] >= frames['b'] - RATE // 2
             else 'expected part of a, then b to its end')
        play('next on the last file', [files['a']], [(2.5, b'n')],
             lambda r: None if len(r) == 1 and r[0][0] == 'a' and r[0][2] < frames['a'] else 'expected part of a only',
             lambda r: None if [n for n, _ in order(r)] == ['a'] and r[-1][1] + r[-1][2] < frames['a']
             else 'expected part of a only')
        play('previous file', [files['c'], files['a']], [(3.6, b'p')],
             lambda r: None if len(r) == 4 and whole(r[0], 'c') and r[1][0] == 'a' and r[1][1] == 0
             and r[1][2] < 3 * RATE and whole(r[2], 'c') and whole(r[3], 'a')
             else 'expected c, part of a, then c and a again',
             lambda r: None if [n for n, _ in order(r)] == ['c', 'a', 'c', 'a'] and ends(r[-1], 'a')
             else 'expected c, part of a, then c and a again')
        play('previous restarts', [files['a']], [(5.0, b'P')],
             lambda r: None if len(r) == 2 and r[0][0] == 'a' and r[0][2] > 3 * RATE and whole(r[1], 'a')
             else 'expected a for over 3 s, then a from its start',
             lambda r: None if [n for n, _ in order(r)] == ['a'] and any(j < -3 * RATE for j in jumps(order(r)[0][1]))
             and ends(r[-1], 'a') else 'expected a for over 3 s, then a from its start')
        play('seek', [files['d']], [(3.0, b'\x1b[C'), (2.5, b'\x1b[B')],
             lambda r: None if len(r) == 3 and r[0][0] == r[1][0] == r[2][0] == 'd'
             and near(r[1][1] - (r[0][1] + r[0][2]), 5 * RATE, RATE // 2) and whole(r[2], 'd')
             else 'expected d, d 5 s later, then d from its start',
             lambda r: None if [n for n, _ in order(r)] == ['d']
             and any(4 * RATE <= j <= 6 * RATE for j in jumps(order(r)[0][1]))
             and any(j < -4 * RATE for j in jumps(order(r)[0][1])) and ends(r[-1], 'd')
             else 'expected d with a jump of about 5 s, then back to its start')
        def repeated(r):
            if not r or any(n != 'e' for n, _, _ in r):
                return 'expected only e'
            if len(r) < 3 or any(s > START_SLACK for _, s, _ in r) or any(s + f != frames['e'] for _, s, f in r[:-1]):
                return 'expected e again and again from its start'
            return None
        def restarted(r):
            spans = order(r)
            if [n for n, _ in spans] != ['e'] or sum(j < -RATE // 2 for j in jumps(spans[0][1])) < 2:
                return 'expected e to start again at least twice'
            return None
        play('--repeat', ['--repeat', files['e']], [(4.5, b'q')], repeated, restarted)
        play('R key', [files['e']], [(1.0, b'r'), (3.5, b'q')], repeated, restarted)
        play('R key twice', [files['e']], [(0.9, b'r'), (0.2, b'R')],
             lambda r: None if len(r) == 1 and whole(r[0], 'e') else 'expected e once')

        # --resume.
        state = resume_state(env)
        if state.exists():
            state.unlink()

        def lines():
            return [line.split('\t') for line in state.read_text().splitlines()] if state.exists() else []

        def absolute(path):
            return wine_path(path) if WINE else str(path)

        code, output = interactive(['--resume', files['a']], env, [(3.0, b'q')])
        saved = lines()
        if code or len(saved) != 1 or saved[0][1:] != [absolute(files['a'])] * 2 or not 0 < int(saved[0][0]) < 6000:
            raise Failure(f'--resume did not keep a: {saved}')
        position = int(saved[0][0]) * RATE // 1000
        play('resume', ['--resume', files['a']], [],
             lambda r: None if len(r) == 1 and whole(r[0], 'a', position) else f'expected a from {position}',
             lambda r: None if r and r[0][0] == 'a' and position <= r[0][1] < position + RATE and ends(r[-1], 'a')
             else f'expected a from {position}')
        if lines():
            raise Failure(f'playing to the end did not forget a: {lines()}')
        code, output = interactive(['--resume', files['c'], files['a']], env, [(4.5, b'q')])
        saved = lines()
        if code or len(saved) != 1 or saved[0][1:] != [absolute(files['c']), absolute(files['a'])]:
            raise Failure(f'--resume did not keep a in the list of c: {saved}')
        position = int(saved[0][0]) * RATE // 1000
        play('resume in a list', ['--resume', files['c'], files['a']], [],
             lambda r: None if len(r) == 1 and whole(r[0], 'a', position) else f'expected a from {position}',
             lambda r: None if r and r[0][0] == 'a' and position <= r[0][1] < position + RATE and ends(r[-1], 'a')
             else f'expected a from {position}')
        code, _ = interactive(['--resume', files['a']], env, [(2.5, b'q')])
        code2, _ = interactive(['--resume', files['d']], env, [(2.5, b'q')])
        saved = lines()
        if code or code2 or [line[1] for line in saved] != [absolute(files['d']), absolute(files['a'])]:
            raise Failure(f'two lists not kept newest first: {saved}')
        play('--start wins', ['--start', '2', '--resume', files['a']], [],
             lambda r: None if len(r) == 1 and whole(r[0], 'a', 2 * RATE) else 'expected a from 2 s',
             lambda r: None if r and r[0][0] == 'a' and 2 * RATE <= r[0][1] < 3 * RATE else 'expected a from 2 s')
        if [line[1] for line in lines()] != [absolute(files['d'])]:
            raise Failure(f'the end of a did not forget only a: {lines()}')
        others = ''.join(f'{n * 10}\t/other/list-{n}.flac\t/other/list-{n}.flac\n' for n in range(300))
        state.write_text('garbage line\n12x\t/a\t/b\n\t\t\n' + others)
        code, _ = interactive(['--resume', files['d']], env, [(2.5, b'q')])
        saved = lines()
        if code or len(saved) != 256 or saved[0][1] != absolute(files['d']) or \
                saved[1] != ['0', '/other/list-0.flac', '/other/list-0.flac'] or \
                saved[-1] != ['2540', '/other/list-254.flac', '/other/list-254.flac']:
            raise Failure(f'the state file was not rewritten as expected: {saved[:3]} ... {saved[-1:]} ({len(saved)})')
        checks.append({'test': 'resume lines', 'result': 'passed',
                       'note': 'newest first, other lists kept, malformed lines dropped, 256 kept'})
        print('resume lines: newest first, other lists kept, malformed lines dropped, 256 kept', flush=True)
        result = subprocess.run(command('--check', '--resume', files['a']), stdout=subprocess.PIPE, env=WINE_ENV,
                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=60)
        if not result.stdout.startswith(b'LAMP '):
            raise Failure('--resume with --check did not print the usage')

    write_report('navigation-wine' if WINE else 'navigation', {'result': 'passed', 'checks': checks,
                                'scope': '--start against whole decodes in ten formats, queues and option errors; '
                                         'keys N/P, arrows, R and --repeat through the null sink.'})
    print(f'Passed {len(checks)} navigation checks.')


if __name__ == '__main__':
    main_guard(main)
