#!/usr/bin/env python3
"""The Windows player's list: lamp.exe under Wine, on a virtual X display.

usage: python3 tests/verify-player.py [--only SCENARIO,...]
Needs Wine, Xvfb, PulseAudio (a private server, as for the playback checks)
and FFmpeg. Builds bin/ with the test tools (tools/build-windows.py --tests).
- List building, through the player's own code (ui-list.exe): folders add
  their audio files and their folders' in natural order (hidden entries,
  other files and playlists left out, extensions in any case); files named
  on the command line or dropped stay as named; the open dialog's folder and
  names join into paths, and a single choice stays whole.
- Playback (lamp.exe driven through window messages by ui-driver.exe): the
  window's title names the file heard, and the null sink's monitor, matched
  against each file's decode, gives the order and positions played. Wine's
  driver drops audio, so runs of a file are merged across short gaps and
  starts are compared within a tolerance.
  - Three files on the command line play gaplessly in order, the title
    following each as it is heard.
  - N, P (the previous file within 3 s, else the file again), the media
    "next" command, the next button, Right (+5 s), N on the last file
    without repeat (nothing), and R with N (the first file again).
  - A folder and an M3U playlist on the command line play in list order.
  - A stream the server kills reopens where it was heard.
  - Choosing another output (WM_COMMAND, as the context menu's Output items
    send) continues the file there from the heard position, and choosing
    the default output brings it back.
Writes <out>/player-verification.json.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import ROOT, Failure, audio_environment, ffmpeg, main_guard, run, scratch, write_report

_spec = importlib.util.spec_from_file_location('verify_navigation',
                                               Path(__file__).resolve().parent / 'verify-navigation.py')
_nav = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_nav)
RATE, FRAME = _nav.RATE, _nav.FRAME
BIN = ROOT / 'bin'


def windows_path(path):
    return 'Z:' + str(path).replace('/', '\\')


class Display:
    """A private Xvfb server for Wine's windows."""

    def __init__(self):
        number = next(n for n in range(57, 120) if not Path(f'/tmp/.X{n}-lock').exists())
        self.name = f':{number}'
        self.process = subprocess.Popen(['Xvfb', self.name, '-screen', '0', '1280x1024x24', '-nolisten', 'tcp'],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if Path(f'/tmp/.X11-unix/X{number}').exists():
                return
            time.sleep(0.05)
        raise Failure('Xvfb did not start')

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=10)


def merge(found):
    """Runs of one file continuing within 1.5 s (audio Wine dropped) ->
    [(name, first frame, end frame)]."""
    segments = []
    for name, start, frames in found:
        if segments and segments[-1][0] == name and -RATE // 10 <= start - segments[-1][2] <= RATE * 3 // 2:
            segments[-1][2] = start + frames
        else:
            segments.append([name, start, start + frames])
    return [tuple(s) for s in segments]


def main():
    for tool in ('wine', 'Xvfb', 'parec'):
        if not shutil.which(tool):
            raise Failure(f'{tool} is required.')
    work = scratch('player')
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required for the private test sink.')
    run([sys.executable, ROOT / 'tools/build-windows.py', '--tests'], capture=False)
    display = Display()
    wine = dict(env, **_nav.WINE_ENV, DISPLAY=display.name)
    checks = []
    scenarios = [list_checks, list_playback, keys, folder_playback, killed_stream, output_menu]
    only = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None
    try:
        for scenario in scenarios:
            if only is None or scenario.__name__ in only:
                scenario(work, env, wine, checks)
    finally:
        subprocess.run(['wineserver', '-k'], env=wine, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        display.stop()
    if only is not None:
        print(f'Passed {len(checks)} player checks (only {", ".join(only)}).')
        return
    write_report('player', {'result': 'passed', 'checks': checks,
                            'scope': 'lamp.exe list building (folders, command line, drops, the open dialog), '
                                     'gapless list playback with the title following the file heard, N/P, the '
                                     'media next command, the next button, seeking, repeat, playlists, '
                                     'reopening a killed stream and choosing outputs, under Wine on Xvfb.'})
    print(f'Passed {len(checks)} player checks.')


def ui_list(wine, *arguments):
    result = subprocess.run(['wine', BIN / 'ui-list.exe', *arguments], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=wine, timeout=120)
    if result.returncode:
        raise Failure(f'ui-list {arguments}: exit {result.returncode}')
    return result.stdout.decode().splitlines()


def list_checks(work, env, wine, checks):
    tree = work / 'tree'
    shutil.rmtree(tree, ignore_errors=True)
    album = tree / 'Album'
    for name in ('10 ten.flac', '2 two.MP3', '1 one.flac', 'Ünïcode.opus', 'cover.jpg', 'album.m3u', 'notes.txt',
                 'Disc 2/b.ogg', 'Disc 2/a.wv', 'disc 1/z.wav', '.hidden/h.flac', 'Empty/readme.txt'):
        path = album / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'')
    root = windows_path(album)
    expected = [root + '\\' + name for name in ('1 one.flac', '2 two.MP3', '10 ten.flac', 'disc 1\\z.wav',
                                                 'Disc 2\\a.wv', 'Disc 2\\b.ogg', 'Ünïcode.opus')]
    got = ui_list(wine, 'paths', root)
    if got != expected:
        raise Failure(f'a folder lists {got}, not {expected}')
    checks.append({'test': 'folder', 'result': 'natural order, folders in place, others left out', 'list': got})
    print(f'a folder: {len(got)} audio files in natural order, folders in place', flush=True)

    named = [root + '\\notes.txt', 'Z:\\no such file.flac', root + '\\Disc 2']
    got = ui_list(wine, 'paths', *named)
    want = named[:2] + [root + '\\Disc 2\\a.wv', root + '\\Disc 2\\b.ogg']
    if got != want:
        raise Failure(f'named paths list {got}, not {want}')
    got = ui_list(wine, 'drop', *named)
    if got != want:
        raise Failure(f'a drop lists {got}, not {want}')
    checks.append({'test': 'command line and drop', 'result': 'files as named, folders expanded', 'list': got})
    print('the command line and a drop: files as named, folders expanded', flush=True)

    got = ui_list(wine, 'dialog', 'Z:\\music', 'a.flac', 'b c.mp3')
    got += ui_list(wine, 'dialog', 'Z:\\', 'top.flac')
    got += ui_list(wine, 'dialog', 'Z:\\music\\one.flac')
    want = ['Z:\\music\\a.flac', 'Z:\\music\\b c.mp3', 'Z:\\top.flac', 'Z:\\music\\one.flac']
    if got != want:
        raise Failure(f'dialog choices list {got}, not {want}')
    checks.append({'test': 'open dialog', 'result': 'folder and names joined; one path whole', 'list': got})
    print('the open dialog: folder and names joined, one path whole', flush=True)


def tagged(work, name, title, seconds, seed):
    path = work / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d={seconds}:seed={seed}:a=0.25', '-ac', '2',
               '-metadata', f'title={title}', '-metadata', 'artist=LAMP Test', '-c:a', 'flac', path)
    return path


def title(name):
    return f'LAMP Test \u2013 {name} - LAMP'


class Session:
    """lamp.exe playing ARGUMENTS while the sink's monitor is recorded."""

    def __init__(self, work, env, wine, label, *arguments):
        self.env, self.wine = env, wine
        self.capture = work / f'{label}.f32'
        self.recorder = subprocess.Popen(['parec', '-d', 'lamp_test.monitor', '--format=float32le', f'--rate={RATE}',
                                          '--channels=2', '--raw', '--latency-msec=10'],
                                         stdout=open(self.capture, 'wb'), env=env)
        time.sleep(0.5)
        self.player = subprocess.Popen(['wine', BIN / 'lamp.exe', *arguments], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, env=wine)

    def drive(self, *commands, timeout=180):
        """Runs ui-driver.exe with COMMANDS once the window is there -> the titles printed."""
        result = subprocess.run(['wine', BIN / 'ui-driver.exe', 'w', *commands], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=self.wine, timeout=timeout)
        lines = result.stdout.decode().splitlines()
        if result.returncode:
            self.finish()
            raise Failure(f'ui-driver {commands}: exit {result.returncode} after {lines}')
        return lines

    def finish(self):
        try:
            self.player.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.player.kill()
            self.player.wait()
        time.sleep(0.5)
        self.recorder.send_signal(signal.SIGINT)
        self.recorder.wait(timeout=10)
        return self.capture.read_bytes()


def expect_segments(label, segments, expected):
    """expected: [(name, start in frames or None for any)]."""
    names = [s[0] for s in segments]
    if names != [e[0] for e in expected]:
        raise Failure(f'{label}: played {segments}, expected {[e[0] for e in expected]}')
    for (name, start, end), (_, want) in zip(segments, expected):
        if want is not None and not want - RATE // 2 <= start <= want + RATE * 3 // 4:
            raise Failure(f'{label}: {name} started at frame {start}, not near {want}: {segments}')


def list_playback(work, env, wine, checks):
    """Three files on the command line: gapless, the title following each."""
    names = ['First', 'Second', 'Third']
    paths = [tagged(work, f'list/{n}.flac', name, 2.5, n + 1) for n, name in enumerate(names)]
    references = {name: _nav.linux_decode(work, path) for name, path in zip(names, paths)}
    session = Session(work, env, wine, 'list', *map(windows_path, paths))
    titles = session.drive('p14000', 'c')
    capture = session.finish()
    want = [title(name) for name in names]
    if [t for t in titles if t in want] != want:
        raise Failure(f'the list titled the window {titles}')
    segments = merge(_nav.runs(capture, references))
    expect_segments('the list', segments, [('First', None), ('Second', 0), ('Third', 0)])
    frames = len(references['First']) // FRAME
    if any(end < frames - RATE // 4 for _, _, end in segments):
        raise Failure(f'the list did not play each file to its end: {segments}')
    checks.append({'test': 'command-line list', 'result': 'in order, titled as heard', 'titles': titles,
                   'segments': segments})
    print(f'three files: {segments}, titled {titles[1:]}', flush=True)


def keys(work, env, wine, checks):
    """Keys, the media command and the next button."""
    names = ['One', 'Two', 'Three', 'Four']
    paths = [tagged(work, f'keys/{n}.flac', name, 9, n + 11) for n, name in enumerate(names)]
    references = {name: _nav.linux_decode(work, path) for name, path in zip(names, paths)}
    session = Session(work, env, wine, 'keys', *map(windows_path, paths))
    steps = [('s3000', 't'), ('k4e', 's1500', 't'), ('k50', 's1500', 't'), ('s2500', 'k50', 's1500', 't'),
             ('a11', 's1500', 't'), ('m92,63', 's1500', 't'), ('k27', 's1500', 't'), ('s3500', 't'),
             ('k4e', 's1500', 't'), ('k52', 'k4e', 's1500', 't'), ('c',)]
    titles = session.drive(*[command for step in steps for command in step])
    capture = session.finish()
    want = [title(name) for name in ('One', 'Two', 'One', 'One', 'Two', 'Three', 'Three', 'Four', 'Four', 'One')]
    if titles != want:
        raise Failure(f'the keys titled the window {titles}, not {want}')
    segments = merge(_nav.runs(capture, references))
    expect_segments('the keys', segments, [('One', None), ('Two', 0), ('One', 0), ('One', 0), ('Two', 0),
                                           ('Three', 0), ('Three', None), ('Four', 0), ('One', 0)])
    seek = segments[6][1] - segments[5][2]
    if not 4 * RATE - RATE // 2 <= seek <= 5 * RATE + RATE // 2:
        raise Failure(f'Right moved {seek} frames, not 5 s: {segments}')
    checks.append({'test': 'keys', 'result': 'N, P twice, media next, next button, Right, N at the end, R and N',
                   'titles': titles, 'segments': segments})
    print(f'keys: {segments}', flush=True)


def folder_playback(work, env, wine, checks):
    """A folder and a playlist on the command line."""
    folder = work / 'folder'
    shutil.rmtree(folder, ignore_errors=True)
    names = ['Track 1', 'Track 2', 'Track 10', 'Inner', 'Listed']
    paths = [tagged(work, f'folder/{name}', title_name, 1.5, n + 21) for n, (name, title_name) in
             enumerate(zip(('1.flac', '2.flac', '10.flac', 'z/inner.flac', '../listed.flac'), names))]
    (folder / 'cover.jpg').write_bytes(b'\xff\xd8')
    playlist = work / 'list.m3u'
    playlist.write_text('#EXTM3U\nlisted.flac\n')
    references = {name: _nav.linux_decode(work, path) for name, path in zip(names, paths)}
    session = Session(work, env, wine, 'folder', windows_path(folder), windows_path(playlist))
    titles = session.drive('p12000', 'c')
    capture = session.finish()
    want = [title(name) for name in names]
    if [t for t in titles if t in want] != want:
        raise Failure(f'the folder and playlist titled the window {titles}')
    segments = merge(_nav.runs(capture, references))
    if [s[0] for s in segments] != names[len(names) - len(segments):] or len(segments) < len(names) - 1:
        raise Failure(f'the folder and playlist played {segments}')
    checks.append({'test': 'folder and playlist', 'result': 'list order', 'titles': titles, 'segments': segments})
    print(f'a folder and a playlist: {[s[0] for s in segments]}', flush=True)


def killed_stream(work, env, wine, checks):
    """A killed stream reopens where it was heard."""
    path = tagged(work, 'long.flac', 'Long', 8, 31)
    references = {'Long': _nav.linux_decode(work, path)}
    frames = len(references['Long']) // FRAME
    session = Session(work, env, wine, 'killed', windows_path(path))
    session.drive('s4500')
    def streams():
        return [line.split('\t')[0] for line in subprocess.run(['pactl', 'list', 'short', 'sink-inputs'], env=env,
                                                              stdout=subprocess.PIPE).stdout.decode().splitlines()
                if line]
    inputs = streams()
    if len(inputs) != 1:
        session.drive('c')
        session.finish()
        raise Failure(f'expected one playback stream, found {inputs}')
    subprocess.run(['pactl', 'load-module', 'module-cli-protocol-unix'], env=env, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)                     # for pacmd; it may be loaded already
    subprocess.run(['pacmd', 'kill-sink-input', inputs[0]], env=env, check=True, stdout=subprocess.DEVNULL)
    time.sleep(2)
    reopened = streams()
    titles = session.drive('s4000', 't', 'c')
    capture = session.finish()
    found = _nav.runs(capture, references)
    if len(reopened) != 1 or reopened == inputs:
        raise Failure(f'the killed stream {inputs} was not reopened: {reopened}')
    if titles != [title('Long')] or len(found) < 2 or found[-1][1] + found[-1][2] < frames - RATE // 2 or \
            not any(-RATE <= b[1] - (a[1] + a[2]) <= RATE // 2 for a, b in zip(found, found[1:])):
        raise Failure(f'a killed stream: runs {found}, titles {titles}')
    checks.append({'test': 'killed stream reopens', 'result': 'continued to the end', 'runs': found})
    print(f'a killed stream reopens where it was heard: {found}', flush=True)


def stream_sinks(env):
    """-> the names of the sinks the server's playback streams play on."""
    def short(kind):
        listing = subprocess.run(['pactl', 'list', 'short', kind], env=env, stdout=subprocess.PIPE, timeout=20)
        return [line.split('\t') for line in listing.stdout.decode().splitlines() if line]
    names = {row[0]: row[1] for row in short('sinks')}
    return [names.get(row[1], row[1]) for row in short('sink-inputs')]


def output_menu(work, env, wine, checks):
    """The Output menu: another endpoint, then the default again."""
    module = subprocess.run(['pactl', 'load-module', 'module-null-sink', 'sink_name=lamp_menu', 'format=float32le',
                             'rate=48000', 'channels=2', "sink_properties=\"device.description='Menu test sink'\""],
                            env=env, stdout=subprocess.PIPE, check=True).stdout.decode().strip()
    try:
        time.sleep(0.5)
        # Wine lists an endpoint it has not seen before out of its later
        # order until it registers it, so the second listing gives the
        # numbers lamp.exe will see.
        for _ in range(2):
            listed = subprocess.run(['wine', BIN / 'lamp-cli.exe', '--list-devices'], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, env=wine, timeout=120).stdout.decode()
        rows = [line.split('\t') for line in listed.replace('\r', '').splitlines()]
        number = next(int(row[0]) for row in rows if len(row) == 3 and row[2] == 'Menu test sink')
        path = tagged(work, 'output.flac', 'Output', 10, 41)
        references = {'Output': _nav.linux_decode(work, path)}
        menu = work / 'menu.f32'
        recorder = subprocess.Popen(['parec', '-d', 'lamp_menu.monitor', '--format=float32le', f'--rate={RATE}',
                                     '--channels=2', '--raw', '--latency-msec=10'], stdout=open(menu, 'wb'), env=env)
        session = Session(work, env, wine, 'output', windows_path(path))
        session.drive('s3500', f'o{201 + number}', 's1500')
        on_chosen = stream_sinks(env)
        session.drive('s1500', 'o200', 's1500')
        on_default = stream_sinks(env)
        session.drive('s500', 'c')
        default = merge(_nav.runs(session.finish(), references))
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=10)
        chosen = merge(_nav.runs(menu.read_bytes(), references))
    finally:
        subprocess.run(['pactl', 'unload-module', module], env=env, stdout=subprocess.DEVNULL)
    if on_chosen != ['lamp_menu'] or on_default != ['lamp_test']:
        raise Failure(f'the Output menu: the stream played on {on_chosen}, then {on_default}; endpoints {rows}')
    if len(chosen) != 1 or len(default) != 2 or not RATE <= chosen[0][1] <= default[0][2] + RATE // 2 or \
            not -RATE <= default[1][1] - chosen[0][2] <= RATE // 2 or chosen[0][2] - chosen[0][1] < RATE:
        raise Failure(f'the Output menu: the default sink played {default}, the chosen one {chosen}')
    checks.append({'test': 'output menu', 'result': 'continued on the chosen endpoint, then the default',
                   'default': default, 'chosen': chosen})
    print(f'the Output menu: {default[0]} on the default, {chosen} on the chosen one, {default[1]} back', flush=True)


if __name__ == '__main__':
    main_guard(main)
