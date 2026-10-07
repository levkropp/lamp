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
  - Chapter bracket keys (including focused controls) and context-menu
    commands use the heard file's chapters and preserve paused playback.
  - At 144 DPI (Wine's setting, restored afterwards) the window is half as
    large again and the scaled next button works.
Writes <out>/player-verification.json, or player-selected-verification.json
when --only selects scenarios.
"""
import importlib.util
import hashlib
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
    scenarios = [list_checks, list_playback, keys, folder_playback, killed_stream, output_menu, dpi,
                 modes, accessibility, eac3_playback, chapter_navigation, dense_queue, track_switching, track_queue,
                 asf_metadata, asf_chapter_navigation, asf_spread, asf_extended, resume]
    only = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None
    if only is not None:
        unknown = set(only) - {scenario.__name__ for scenario in scenarios}
        if unknown:
            raise Failure('Unknown player scenarios: ' + ', '.join(sorted(unknown)))
    _nav.check_capture_fragments()
    for tool in ('wine', 'Xvfb', 'parec'):
        if not shutil.which(tool):
            raise Failure(f'{tool} is required.')
    work = scratch('player')
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required for the private test sink.')
    run([sys.executable, ROOT / 'tools/build-windows.py', '--tests'], capture=False)
    display = Display()
    wine = {**env, **_nav.WINE_ENV, 'DISPLAY': display.name}
    # A Wine server left by an earlier suite may still be shutting down; start afresh.
    subprocess.run(['wineserver', '-k'], env=wine, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['wineserver', '-w'], env=wine, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    checks = []
    try:
        for scenario in scenarios:
            if only is None or scenario.__name__ in only:
                scenario(work, env, wine, checks)
    finally:
        subprocess.run(['wineserver', '-k'], env=wine, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        display.stop()
    source_hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
        ('src/queue.s', 'src/win/player.s', 'src/win/ui.s', 'src/win/ui_queue.inc',
         'src/win/ui_menu.inc', 'src/win/ui_resume.inc', 'src/win/resume_state.inc', 'src/resume.s', 'src/win/kernel32.def', 'tests/verify-player.py')}
    source_hashes.update({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
        ('src/decoder.s', 'src/mp4.s', 'src/mkv.s', 'src/avi.s', 'src/mpegts.s', 'src/ogg_chain.s',
         'src/win/ui_tracks.inc', 'src/win/ui_draw.inc', 'tests/ui-driver.s')})
    source_hashes.update({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
        ('src/tags.s', 'src/tags_asf.inc', 'src/cover.inc', 'src/asf.s',
         'src/chapters_asf.inc', 'src/chapters.inc', 'tests/verify-asf-chapters.py',
         'src/asf_spread.inc', 'tests/verify-asf-spread.py',
         'src/asf_extended.inc', 'tests/verify-asf-extended.py',
         'tests/asf-metadata-player-oracle.c', 'tests/verify-asf-metadata.py')})
    binary_hashes = {name: hashlib.sha256((BIN / name).read_bytes()).hexdigest()
                     for name in ('lamp.exe', 'lamp-cli.exe', 'ui-driver.exe')}
    if only is not None:
        write_report('player-selected', {'result': 'passed', 'checks': checks,
            'source_hashes': source_hashes, 'binary_hashes': binary_hashes,
            'selected_scenarios': only, 'scope': 'Selected Windows player scenarios under Wine on Xvfb'})
        print(f'Passed {len(checks)} player checks (only {", ".join(only)}).')
        return
    write_report('player', {'result': 'passed', 'checks': checks,
                            'source_hashes': source_hashes, 'binary_hashes': binary_hashes,
                            'scope': 'lamp.exe list building (folders, command line, drops, the open dialog), '
                                     'gapless list playback with the title following the file heard, N/P, the '
                                     'media next command, the next button, seeking, repeat, playlists, '
                                     'reopening a killed stream, choosing outputs, 144 DPI, fullscreen/compact '
                                     'restoration, Tab/Shift+Tab focus, slider values and MSAA names/native '
                                     'control classes, raw E-AC-3 playback and folder discovery, chronological chapter keys/menu and paused seeks, '
                                     'dense queue filename/chapter fallback after metadata eviction, per-entry audio track switching, Automatic, paused position retention and unsupported-track rollback, under Wine on Xvfb; native Windows screen-reader '
                                     'roles remain unverified.'})
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
                 '3 three.ec3', '4 four.EAC3', '5 fünf.gsm', '6 six.GSM', 'voice.gsm.txt',
                 '7 seven.AsF', '8 восьмь.WMA', '9 nine.wmv', 'video.wmv.txt',
                 'Disc 2/b.ogg', 'Disc 2/a.wv', 'disc 1/z.wav', '.hidden/h.flac', 'Empty/readme.txt'):
        path = album / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'')
    root = windows_path(album)
    expected = [root + '\\' + name for name in ('1 one.flac', '2 two.MP3', '3 three.ec3', '4 four.EAC3',
                                                 '5 fünf.gsm', '6 six.GSM', '7 seven.AsF', '8 восьмь.WMA', '9 nine.wmv', '10 ten.flac', 'disc 1\\z.wav',
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

    relative = os.path.relpath(album / 'Disc 2' / 'a.wv').replace('/', '\\')
    dotted = os.path.relpath(album).replace('/', '\\') + '\\Disc 2\\..\\1 one.flac'
    urls = ['https://example.invalid/list.m3u8', 'file:///Z:/music/one.flac']
    got = ui_list(wine, 'paths', relative, dotted, *urls)
    want = [root + '\\Disc 2\\a.wv', root + '\\1 one.flac', *urls]
    if got != want:
        raise Failure(f'local paths were not frozen to absolute names: {got}')
    checks.append({'test': 'absolute queue paths', 'result': 'relative and dotted local names frozen; URL spellings retained', 'list': got})

    got = ui_list(wine, 'dialog', 'Z:\\music', 'a.flac', 'b c.mp3', 'voice.GSM')
    got += ui_list(wine, 'dialog', 'Z:\\', 'top.flac')
    got += ui_list(wine, 'dialog', 'Z:\\music\\one.flac')
    want = ['Z:\\music\\a.flac', 'Z:\\music\\b c.mp3', 'Z:\\music\\voice.GSM', 'Z:\\top.flac', 'Z:\\music\\one.flac']
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
        command = ['wine', BIN / 'lamp.exe', *arguments]
        if wine.get('LAMP_TEST_LOCALAPPDATA'):
            # Wine reconstructs standard Windows environment variables at entry.
            # Set the directory inside cmd before starting the shipping binary.
            quoted = [windows_path(BIN / 'lamp.exe'), *arguments]
            if any('"' in str(value) for value in quoted + [wine['LAMP_TEST_LOCALAPPDATA']]):
                raise Failure('Unexpected quote in isolated test path')
            launcher = work / (label + '-launch.cmd')
            launcher.write_text('@echo off\nset "LOCALAPPDATA=%LAMP_TEST_LOCALAPPDATA%"\n'
                                '"%LAMP_TEST_PLAYER%" %LAMP_TEST_ARGUMENTS%\n', encoding='ascii')
            wine = {**wine, 'LAMP_TEST_PLAYER': quoted[0],
                    'LAMP_TEST_ARGUMENTS': ' '.join('"' + str(value) + '"' for value in arguments)}
            command = ['wine', 'cmd', '/c', windows_path(launcher)]
        launch_output = subprocess.DEVNULL
        if wine.get('LAMP_TEST_LOCALAPPDATA'):
            launch_output = open(work / (label + '-launch.log'), 'wb')
        self.player = subprocess.Popen(command, stdout=launch_output,
                                       stderr=launch_output, env=wine)
        if launch_output != subprocess.DEVNULL:
            launch_output.close()

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


def resume(work, env, wine, checks):
    """Opt-in resume: actual windows, persistent files, paused snapshots and PCM."""
    state_home = work / 'resume-local'
    shutil.rmtree(state_home, ignore_errors=True)
    state_home.mkdir()
    wine = {**wine, 'LAMP_TEST_LOCALAPPDATA': windows_path(state_home)}
    folder = state_home / 'LAMP'
    folder.mkdir()
    state, preference = folder / 'resume.txt', folder / 'player-resume.txt'
    paths = [tagged(work, 'resume/Ünïcode-first.flac', 'Resume first', 9, 81),
             tagged(work, 'resume/第二.flac', 'Resume second', 9, 82)]
    references = {name: _nav.linux_decode(work, path) for name, path in
                  zip(('first', 'second'), paths)}
    arguments = list(map(windows_path, paths))
    relative_arguments = [os.path.relpath(path).replace('/', '\\') for path in paths]
    other = '37\tZ:\\other.flac\tZ:\\other.flac\n'
    saved = '5000\t' + arguments[0] + '\t' + arguments[1] + '\n'

    def rows():
        return state.read_text(encoding='utf-8').splitlines() if state.exists() else []

    def playing(label, *args):
        return Session(work, env, wine, 'resume-' + label, *(args or arguments))

    def heard(label, pcm, name, ms=0):
        segments = merge(_nav.runs(pcm, references))
        if not segments or segments[0][0] != name or not ms * 48 <= segments[0][1] < (ms + 750) * 48:
            raise Failure(label + ': resumed wrong file/time: ' + str(segments))
        return segments

    state.write_text(saved + other, encoding='utf-8')
    session = playing('default-off')
    session.drive('s2500', 'c')
    first = heard('default off', session.finish(), 'first')
    if state.read_text(encoding='utf-8') != saved + other or preference.exists():
        raise Failure('Default-off GUI changed persistent state')
    checks.append(dict(test='GUI resume defaults off', result='saved position ignored and state untouched', segments=first))

    # Real popup P mnemonic selects Remember playback position; chapter items
    # are later in the menu and have no explicit P mnemonic.
    session = playing('enable')
    session.drive('s2000', 'r', 'e50', 'e0d', 's200', 'k4e', 's1800',
                  'k20', 's700', 'k24', 's1100', 'k27', 's1100', 'n111', 't', 'c')
    session.finish()
    expected = ['5000\t' + arguments[0] + '\t' + arguments[1], other.strip()]
    if preference.read_bytes() != b'1\n' or rows() != expected:
        raise Failure('Remember/pause/close did not save paired second-file 5s: ' + str(rows()))
    checks.append(dict(test='GUI remembers opt-in and paused heard position', result='real menu preference and exact second-file 5000ms persisted', rows=rows()))

    playlist = work / 'resume' / 'list.m3u8'
    playlist.write_text('#EXTM3U\n' + paths[0].name + '\n' + paths[1].name + '\n', encoding='utf-8')
    session = playing('reopen-playlist', windows_path(playlist))
    titles = session.drive('s2400', 't', 'c')
    segments = heard('expanded playlist', session.finish(), 'second', 5000)
    if titles != [title('Resume second')] or not rows()[0].endswith('\t' + arguments[0] + '\t' + arguments[1]):
        raise Failure('Expanded playlist did not retain its first-file key: ' + str(rows()))
    checks.append(dict(test='GUI reopens expanded Unicode playlist', result='same first-file key; second-file resumed PCM', segments=segments, titles=titles))

    replacement = tagged(work, 'resume/another/替換.flac', 'Resume replacement', 9, 83)
    references['replacement'] = _nav.linux_decode(work, replacement)
    state.write_text(saved + other, encoding='utf-8')
    session = playing('replace-queue', *relative_arguments)
    session.drive('s2200', 'k20', 's500', 'k24', 's1100', 'k27', 's1100')
    state.write_text(other, encoding='utf-8')  # prove replacement writes a new old-queue record
    session.drive('r', 's300', 'e1b', 's300', 'o100', 's2500', 'l4e', 's250', 'x' + windows_path(replacement), 'e0d', 's2600')
    titles = session.drive('t')
    if titles != [title('Resume replacement')] or rows() != expected:
        session.drive('e1b', 'c'); session.finish()
        raise Failure('Open-dialog replacement saved a different old queue/time: ' + str((titles, rows())))
    session.drive('k20', 's400', 'k24', 's1100', 'k27', 's1100', 'c')
    capture = session.finish()
    replacement_row = '5000\t' + windows_path(replacement) + '\t' + windows_path(replacement)
    if rows() != [replacement_row, *expected] or not any(name == 'replacement' for name, _, _ in _nav.runs(capture, references)):
        raise Failure('Replacement queue lost either saved position: ' + str(rows()))
    checks.append(dict(test='GUI saves replaced queue through real Open dialog', result='relative input paths remain absolute across a dialog in another folder; old paired second-file 5000ms saved before replacement; closing new list keeps both keys', rows=rows(), titles=titles))

    # Unlike startup (rate initially zero), replacing a running list converts
    # the saved time using its already-known rate on the UI thread. This value
    # exceeds the 64-bit frame range; the loading display must saturate, then
    # the worker clamps to EOF and the completed list forgets its record.
    state.write_text(saved + other, encoding='utf-8')
    session = playing('huge-time-replacement')
    session.drive('s2200', 'k20', 's400', 'k24', 's1100')
    huge = '999999999999999999\t' + windows_path(replacement) + '\t' + windows_path(replacement) + '\n'
    state.write_text(huge + saved + other, encoding='utf-8')
    sequence = session.drive('r', 's300', 'e1b', 's300', 'o100', 's2500', 'l4e', 's250',
                             'x' + windows_path(replacement), 'e0d', 's2500', 't', 'n111')
    old_row = '0\t' + arguments[0] + '\t' + arguments[1]
    if sequence[0] != title('Resume replacement') or sequence[1] != 'Play' or rows() != [old_row, other.strip()]:
        session.drive('e1b', 'c'); session.finish()
        raise Failure('Extreme saved time failed to finish and forget only the replaced list: ' + str((sequence, rows())))
    session.drive('k20', 's2200', 'c')
    pcm = session.finish()
    runs = merge(_nav.runs(pcm, references))
    if not any(name == 'replacement' and start < 750 * 48 for name, start, _ in runs):
        raise Failure('GUI did not remain usable after extreme saved-time replacement: ' + str(runs))
    checks.append(dict(test='GUI extreme saved time after queue replacement', result='18-digit time saturates loading frames, worker finishes at EOF, own record forgotten and explicit replay remains usable', controls=sequence, segments=runs))

    # Natural completion removes only this list's record; closing a finished
    # window must not recreate it. Space replays explicitly from the start.
    state.write_text(saved + other, encoding='utf-8')
    session = playing('completion')
    session.drive('s7000')
    if rows() != [other.strip()]:
        session.drive('c'); session.finish()
        raise Failure('Natural GUI completion did not forget only its own key: ' + str(rows()))
    session.drive('k20', 's2200', 'c')
    pcm = session.finish()
    runs = merge(_nav.runs(pcm, references))
    if not runs or runs[0][0] != 'second' or not any(name == 'first' and start < 750 * 48 for name, start, _ in runs):
        raise Failure('Space after completion did not replay from the first file: ' + str(runs))
    checks.append(dict(test='GUI completion and explicit replay', result='completion deletes only own record; Space starts the first file', segments=runs))

    # A saved filename absent from the newly expanded list is ignored. Disabling
    # persists and leaves existing positions available to the console opt-in.
    state.write_text('5000\t' + arguments[0] + '\tZ:\\missing.flac\n' + other, encoding='utf-8')
    session = playing('missing-and-disable')
    session.drive('s2400', 'o106', 'c')
    segments = heard('missing file', session.finish(), 'first')
    if preference.read_bytes() != b'0\n':
        raise Failure('GUI disable preference was not persisted')
    state.write_text(saved + other, encoding='utf-8')
    session = playing('disabled-reopen')
    session.drive('s2200', 'c')
    segments2 = heard('disabled reopen', session.finish(), 'first')
    if state.read_text(encoding='utf-8') != saved + other:
        raise Failure('Disabled GUI changed position records')
    checks.append(dict(test='GUI missing file and persistent disable', result='missing file starts first; disable survives reopen and preserves records', segments=segments, disabled_segments=segments2))

    # Strict preference parser: all malformed/suffixed/oversized settings default
    # off; an oversized position file is ignored and replaced by a bounded save.
    for value in (b'1', b'1\nextra', b'garbage\n'):
        preference.write_bytes(value)
        session = playing('corrupt-' + value.hex())
        session.drive('s2200', 'c')
        heard('corrupt preference', session.finish(), 'first')
        if state.read_text(encoding='utf-8') != saved + other:
            raise Failure('Malformed preference enabled GUI resume')
    preference.write_bytes(b'1\n')
    with state.open('wb') as handle:
        handle.write(saved.encode('utf-8'))
        handle.truncate((16 << 20) + 1)
    session = playing('oversized-state')
    session.drive('s2200', 'k20', 's400', 'k24', 's1000', 'c')
    pcm = session.finish()
    heard('oversized state', pcm, 'first')
    if rows() != ['0\t' + arguments[0] + '\t' + arguments[0]] or state.stat().st_size > 32768:
        raise Failure('Oversized state was not replaced by the exact paused first-file record: ' + str(rows()[:3]))
    checks.append(dict(test='GUI malformed settings and oversized state', result='three malformed preferences default off; 16MiB+1 state ignored and replaced by bounded paired record'))
    checks[-1].update(fixture_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in [*paths, replacement, playlist]},
                      reference_pcm_sha256={name: hashlib.sha256(pcm).hexdigest()
                                            for name, pcm in references.items()},
                      limit='Wine 8 on Xvfb and a private PulseAudio sink; native Windows remains unverified')
    print('GUI resume: default off, real menu opt-in, paused Unicode queue, playlist reopen, completion/replay, missing/disabled/corrupt state and size cap pass', flush=True)


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
    # The window exists before Wine finishes its audio/device setup. Leave
    # room for a slow cold start, then require all three titles and complete
    # audio runs rather than closing while the last track is still pending.
    titles = session.drive('p20000', 'c')
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


def wine_dpi(wine, value):
    """Sets Wine's DPI (None: removes the setting) -> the earlier value, or None."""
    key = r'HKCU\Control Panel\Desktop'
    query = subprocess.run(['wine', 'reg', 'query', key, '/v', 'LogPixels'], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=wine, timeout=120).stdout.decode().split()
    earlier = int(query[-1], 16) if 'LogPixels' in query else None
    if value is None:
        subprocess.run(['wine', 'reg', 'delete', key, '/v', 'LogPixels', '/f'], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, env=wine, timeout=120)
    else:
        subprocess.run(['wine', 'reg', 'add', key, '/v', 'LogPixels', '/t', 'REG_DWORD', '/d', str(value), '/f'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=wine, timeout=120, check=True)
    subprocess.run(['wineserver', '-k'], env=wine, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return earlier


def dpi(work, env, wine, checks):
    """At 144 DPI the window, its layout and its controls are half as large again."""
    paths = [tagged(work, f'keys/{n}.flac', name, 9, n + 11) for n, name in enumerate(['One', 'Two'])]
    session = Session(work, env, wine, 'dpi-96', *map(windows_path, paths))
    lines = session.drive('s1500', 'z', 'c')
    session.finish()
    normal = tuple(map(int, lines[0].split()))
    earlier = wine_dpi(wine, 144)
    try:
        session = Session(work, env, wine, 'dpi-144', *map(windows_path, paths))
        lines = session.drive('s2500', 'z', 't', 'm138,95', 's1500', 't', 'c')     # the next button, scaled
        session.finish()
    finally:
        wine_dpi(wine, earlier)
    scaled = tuple(map(int, lines[0].split()))
    if not all(1.45 <= b / a <= 1.55 for a, b in zip(normal, scaled)):
        raise Failure(f'at 144 DPI the client area is {scaled}, at 96 DPI {normal}')
    if lines[1:] != [title('One'), title('Two')]:
        raise Failure(f'at 144 DPI the next button gave titles {lines[1:]}')
    checks.append({'test': '144 DPI', 'result': 'window 1.5 times as large; the scaled next button works',
                   'client': [normal, scaled]})
    print(f'144 DPI: client {normal} -> {scaled}; the scaled next button moved to the next file', flush=True)


def modes(work, env, wine, checks):
    path = tagged(work, 'modes.flac', 'Modes', 25, 81)
    session = Session(work, env, wine, 'modes', windows_path(path))
    try:
        sizes = session.drive('s1500', 'z', 'k7a', 's1000', 'z', 'k1b', 's1000', 'z',
                              'k43', 's1000', 'z', 'k7a', 's1000', 'z', 'k1b', 's1000', 'z',
                              'o103', 's1000', 'z', 'o102', 's1000', 'z', 'o102', 's1000', 'z', 't', 'c')
    finally:
        pcm = session.finish()
    if len(sizes) != 10 or sizes[-1] != title('Modes'):
        raise Failure(f'mode transitions: {sizes}')
    dimensions = [tuple(map(int, row.split())) for row in sizes[:-1]]
    normal, fullscreen, restored, compact, full_compact, restored_compact, normal_menu, full_menu, final = dimensions
    if fullscreen != (1280, 1024) or full_compact != fullscreen or full_menu != fullscreen or \
            restored != normal or normal_menu != normal or final != normal or restored_compact != compact or \
            not (compact[0] < normal[0] and compact[1] < normal[1]):
        raise Failure(f'mode sizes/restoration: {dimensions}')
    if not pcm or session.player.returncode:
        raise Failure('mode transitions interrupted playback or crashed the player')
    checks.append({'test': 'fullscreen and compact modes', 'result': 'restored through keys and menu',
                   'dimensions': dimensions})
    print(f'fullscreen/compact keys and menu restore the source window: {dimensions}', flush=True)


def accessibility(work, env, wine, checks):
    a = tagged(work, 'accessible-long-a.flac', 'Accessible A', 90, 82)
    b = tagged(work, 'accessible-long-b.flac', 'Accessible B', 90, 83)
    session = Session(work, env, wine, 'accessibility', windows_path(a), windows_path(b))
    try:
        names = session.drive('s2500', 'n100', 'n110', 'n111', 'n112', 'n101', 'n113', 'n114')
        # Wine 8 supplies the generic client role (10) for buttons/trackbars;
        # Windows supplies push-button (43) and slider (51) roles. Check native
        # classes as well, so a generic custom window cannot satisfy this test.
        expected_names = ['Open files', 'Previous track', 'Pause', 'Next track',
                          'Repeat off', 'Playback position', 'Volume']
        expected_classes = ['Button'] * 5 + ['msctls_trackbar32'] * 2
        if names[::3] != expected_names or names[2::3] != expected_classes or \
                any(role not in ('10', '43' if i < 5 else '51') for i, role in enumerate(names[1::3])):
            raise Failure(f'MSAA names/roles and native classes: {names}')
        focus = session.drive('k09', 's1000', 'f', 'k09', 's1000', 'f', 'k09', 's1000', 'f',
                              'v0d', 's1000', 'n111', 'v20', 's1000', 'n111',
                              'k09', 's1000', 'f', 'k09', 's1000', 'f', 'v0d', 's1000', 'n101',
                              'k09', 's1000', 'f', 'k09', 's1000', 'f', 'v24', 's1000', 'n114', 'h114',
                              'k09', 's1000', 'f', 'b', 's1000', 'f', 'b', 's1000', 'f',
                              'v43', 's1000', 'z', 'v1b', 's1000', 'z',
                              'k09', 's3500', 'f', 'u114', 's3500', 'f',
                              'k09', 's1000', 'f', 'c')
        expected_focus = ['Open files', 'Previous track', 'Pause', 'Play', names[7], 'Button',
                          'Pause', names[7], 'Button', 'Next track', 'Repeat off',
                          'Repeat on', names[13], 'Button', 'Playback position',
                          'Volume', 'Volume', names[19], 'msctls_trackbar32', '0',
                          'Open files', 'Volume', 'Playback position']
        if focus[:-5] != expected_focus:
            raise Failure(f'keyboard focus/activation: {focus}')
        if not tuple(map(int, focus[-5].split()))[1] < tuple(map(int, focus[-4].split()))[1]:
            raise Failure(f'global compact/Escape keys while a child has focus: {focus[-5:-3]}')
        if focus[-3:] != ['Volume', title('Accessible A'), 'Open files']:
            raise Failure(f'keyboard focus preservation/mouse auto-hide/reveal: {focus[-3:]}')
    finally:
        session.finish()
    checks.append({'test': 'keyboard and accessibility', 'result': 'MSAA names and native control classes; '
                   'Tab/Shift+Tab cycle, Enter and Space activation, slider keys, global mode shortcuts, '
                   'keyboard focus preservation and mouse auto-hide/reveal',
                   'names_roles_classes': names, 'focus': focus,
                   'limit': 'Wine 8 exposes generic client roles; native Windows screen-reader testing remains.'})
    print('MSAA names, native classes, Tab order, Enter/Space and focused mode shortcuts pass', flush=True)


def chapter_navigation(work, env, wine, checks, container='flac'):
    """Bracket keys and menu while paused, using chapters of the heard file."""
    path=work/('chapter-a.'+container)
    comments=[]
    for index,start in enumerate([6500,0,3250,1250,3250,12000]):
        comments+=['-metadata',f'CHAPTER{index:03}=00:00:{start//1000:02}.{start%1000:03}']
    ffmpeg('-f','lavfi','-i',f'anoisesrc=r={RATE}:d=9:seed=9102:a=0.25','-ac','2',
           '-metadata','artist=LAMP Test','-metadata','title=Chapter A',
           *(comments if container=='flac' else []),'-c:a','flac' if container=='flac' else 'pcm_s16le',path)
    if container=='asf':
        spec=importlib.util.spec_from_file_location('asf_chapter_writer',ROOT/'tests/verify-asf-chapters.py')
        writer=importlib.util.module_from_spec(spec);spec.loader.exec_module(writer)
        marker=writer.markers([writer.entry(31000000+start*10000,'Part '+str(i))
            for i,start in enumerate([6500,0,3250,1250,3250,12000])])
        path.write_bytes(writer.insert(path.read_bytes(),[marker],3100,True))
    later=work/'chapter-b.flac'
    ffmpeg('-f','lavfi','-i',f'anoisesrc=r={RATE}:d=9:seed=9103:a=0.25','-ac','2',
           '-metadata','artist=LAMP Test','-metadata','title=Chapter B',
           '-metadata','CHAPTER001=00:00:07.000','-c:a','flac',later)
    references={'A':_nav.linux_decode(work,path),'B':_nav.linux_decode(work,later)}
    session=Session(work,env,wine,'chapters-'+container,windows_path(path),windows_path(later))
    try:
        # Pause before 3.25 s, then keep it paused through every restart.
        before=session.drive('s2500','k20','s1000','n111','h113')
        if before[0]!='Play' or not 0<int(before[-1])<3611:
            raise Failure(f'Chapter test did not pause before its next boundary: {before}')
        sequence=session.drive('o104','s1500','n111','h113',
            'kdd','s1500','n111','h113','kdd','s1500','n111','h113',
            'k09','vdb','s1500','n111','h113',
            'o105','s1500','n111','h113','o105','s1500','n111','h113',
            'o105','s1000','n111','h113','o104','s1500','n111','h113',
            'o105','s1500','n111','h113','t')
        expected=[0,1250,3250,1250,3250,6500,6500,3250,6500]
        for index,ms in enumerate(expected):
            if sequence[index*4]!='Play' or abs(int(sequence[index*4+3])-ms*10000//9000)>2:
                raise Failure(f'Paused chapter target {ms} ms: {sequence}')
        if sequence[-1]!=title('Chapter A'):
            raise Failure('Chapter controls used the file decoded ahead: '+str(sequence))
        relative=session.drive('k24','s1500','n111','h113',
            'k27','s1500','n111','h113','k25','s1500','n111','h113')
        for index,ms in enumerate([0,5000,0]):
            if relative[index*4]!='Play' or abs(int(relative[index*4+3])-ms*10000//9000)>2:
                raise Failure(f'Paused Home/Right/Left target {ms} ms: {relative}')
        restored=session.drive('o105','s1500','o105','s1500','o105','s1500','t','n111','h113')
        if restored[0]!=title('Chapter A') or restored[1]!='Play' or abs(int(restored[-1])-6500*10000//9000)>2:
            raise Failure(f'Paused chapter restoration after relative seeking: {restored}')
        assert_paused(session)
        session.drive('k20','s2000','c')
    finally:
        capture=session.finish()
    segments=merge(_nav.runs(capture,references))
    if len(segments)!=2 or any(name!='A' for name,_,_ in segments) or \
            segments[0][1]>RATE//2 or segments[0][2]>=3250*48 or \
            not 6500*48<=segments[1][1]<7000*48 or segments[1][2]>9000*48:
        raise Failure(f'Chapter seeks played while paused or chose wrong PCM: {segments}')
    checks.append(dict(test=container+' chapter navigation',result='brackets and menu choose heard-file chapters; pause preserved',
        paused_targets_ms=expected,controls=sequence,segments=segments,
        paused_relative_targets_ms=[0,5000,0],relative_controls=relative,
        fixture_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        reference_pcm_sha256={name:hashlib.sha256(pcm).hexdigest() for name,pcm in references.items()},
        player_sha256=hashlib.sha256((BIN/'lamp.exe').read_bytes()).hexdigest(),
        driver_sha256=hashlib.sha256((BIN/'ui-driver.exe').read_bytes()).hexdigest(),
        silent_paused_window_frames=RATE//2,
        limit='Wine playback; native Windows remains unverified'))
    print('Chapter keys, menu, heard-file snapshots and paused seeks pass',flush=True)


def asf_chapter_navigation(work, env, wine, checks):
    chapter_navigation(work,env,wine,checks,container='asf')


def dense_queue(work, env, wine, checks):
    """Metadata evicted by decode ahead: filename and paused chapter fallback."""
    path = work / 'dense-first.flac'
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=2:seed=9301:a=0.25', '-ac', '2',
           '-metadata', 'artist=LAMP Test', '-metadata', 'title=Early metadata',
           '-metadata', 'CHAPTER001=00:00:00.000', '-metadata', 'CHAPTER002=00:00:00.500',
           '-metadata', 'CHAPTER003=00:00:01.250', '-metadata', 'CHAPTER004=00:00:07.000',
           '-c:a', 'flac', path)
    later = work / 'dense-later.flac'
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=0.02:seed=9302:a=0.25', '-ac', '2',
           '-metadata', 'artist=LAMP Test', '-metadata', 'title=Future metadata',
           '-metadata', 'CHAPTER001=00:00:07.000', '-c:a', 'flac', later)
    reference = _nav.linux_decode(work, path)
    references = {'first': reference, 'later': _nav.linux_decode(work, later)}
    session = Session(work, env, wine, 'dense-queue', windows_path(path), *([windows_path(later)] * 100))
    expected_title = path.name + ' - LAMP'
    def paused_fallback():
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            lines = session.drive('t', 'n111')
            if lines[0] == expected_title and lines[1] == 'Play': return lines
            time.sleep(0.1)
        raise Failure(f'Dense queue did not show the paused heard filename: {lines}')
    try:
        # Pause as soon as the window exists. The producer still fills the
        # ring with all 101 files, evicting the first metadata snapshot.
        session.drive('k20')
        observed = [paused_fallback()]
        # Previous chapter returns to zero, independently of where the
        # initial pause landed. Both subsequent seeks must reopen file 0's
        # chapters on the worker, while the decoder has reached file 100.
        for command in ('o104', 'kdd', 'kdd'):
            session.drive(command, 's1500')
            observed.append(paused_fallback())
        time.sleep(0.6)
        before = session.capture.read_bytes()
        silent_frames = RATE // 2
        if len(before) < silent_frames * FRAME or any(before[-silent_frames * FRAME:]):
            raise Failure('Dense queue chapter restarts played while paused')
        offset = len(before)
        session.drive('k20')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            resumed = _nav.runs(session.capture.read_bytes()[offset:], references)
            if resumed and resumed[0][2] >= 256: break
            time.sleep(0.05)
        else: raise Failure('Dense queue did not resume first-file PCM')
        session.drive('c')
    finally:
        capture = session.finish()
    resumed = _nav.runs(capture[offset:], references)
    if not resumed or resumed[0][0] != 'first' or not 1250 * 48 <= resumed[0][1] < 1400 * 48:
        raise Failure(f'Dense queue reopened the wrong file/chapter: {resumed}')
    checks.append(dict(test='dense queue heard-file fallback',
        result='filename follows heard file after metadata eviction; worker chapter seeks preserve pause and exact resumed PCM',
        queued_files=101, metadata_snapshot_capacity=64, paused_targets_ms=[0, 500, 1250],
        titles_and_controls=observed, silent_window_frames=silent_frames, resumed_runs=resumed,
        limit='Wine playback; native Windows remains unverified'))
    print('Dense queue filename and paused chapter fallback pass', flush=True)


def track_pcm(work, path, choice):
    output = work / (path.name + f'.track-{choice}.f32')
    if output.exists(): output.unlink()
    run([_nav.lamp_cli(), '--decode', '--track', choice, path, output])
    return output.read_bytes()


def assert_paused(session):
    time.sleep(0.6)
    data = session.capture.read_bytes()
    if len(data) < RATE // 2 * FRAME or any(data[-RATE // 2 * FRAME:]):
        raise Failure('Track switch played while paused')


def track_switching(work, env, wine, checks):
    """Real heard-file switches, paused seek position and Automatic in each demuxer."""
    formats = [('mkv', ['-c:a', 'flac', '-disposition:a:0', '0', '-disposition:a:1', 'default'], 2),
               ('mp4', ['-c:a', 'alac'], 1), ('avi', ['-c:a', 'pcm_s16le'], 1),
               ('ogg', ['-c:a', 'libvorbis'], 1), ('ts', ['-c:a', 'mp2', '-b:a', '192k'], 1),
               ('vob', ['-c:a', 'mp2', '-b:a', '192k', '-f', 'vob'], 1)]
    formats.append(('asf', ['-c:a', 'pcm_s16le'], 1))
    for number, (extension, options, automatic) in enumerate(formats):
        path = work / ('gui-tracks.' + extension)
        ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=12:seed={9500+number*2}:a=0.25',
               '-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=12:seed={9501+number*2}:a=0.25',
               '-map', '0:a', '-map', '1:a', '-ac', '2', *options, path)
        references = {str(n): track_pcm(work, path, n) for n in (1, 2)}
        session = Session(work, env, wine, 'switch-' + extension, windows_path(path))
        try:
            initial = session.drive('s1500', 'k20', 's600', 'k24', 's1000', 'n111', 'h113')
            if initial[0] != 'Play' or int(initial[-1]) != 0:
                raise Failure(f'{extension}: initial paused Home: {initial}')
            popup = session.drive('r', 's250', 'e41', 's250', 'e23', 'e0d', 's1200', 'n111', 'h113')
            if popup[0] != 'Play' or int(popup[-1]) != 0:
                raise Failure(f'{extension}: real popup lost paused beginning: {popup}')
            assert_paused(session)
            popup_offset = session.capture.stat().st_size
            session.drive('k20', 's800', 'k20', 's800')
            popup_runs = merge(_nav.runs(session.capture.read_bytes()[popup_offset:], references))
            if not popup_runs or popup_runs[0][0] != '2' or popup_runs[0][1] >= RATE // 2:
                raise Failure(f'{extension}: real popup did not select track 2: {popup_runs}')
            observed = session.drive('k24', 's1200', 'k27', 's1200', 'n111', 'h113',
                                     'o401', 's1200', 'n111', 'h113', 'o402', 's1200', 'n111', 'h113')
            target = 5000 * RATE * 10000 // (1000 * (len(references['2']) // FRAME))
            for index in range(3):
                if observed[index * 4] != 'Play' or abs(int(observed[index * 4 + 3]) - target) > 3:
                    raise Failure(f'{extension}: track switch lost paused 5 s position: {observed}')
            assert_paused(session)
            offset = session.capture.stat().st_size
            session.drive('k20', 's1200', 'k20', 's800')
            switched = merge(_nav.runs(session.capture.read_bytes()[offset:], references))
            if not switched or switched[0][0] != '2' or not 5000 * 48 <= switched[0][1] < 5600 * 48:
                raise Failure(f'{extension}: wrong track/time after resume: {switched}')
            before_auto = session.drive('n111', 'h113')
            auto = session.drive('r', 's250', 'e41', 's250', 'e24', 'e0d', 's1200', 'n111', 'h113')
            if auto[0] != 'Play' or abs(int(auto[-1]) - int(before_auto[-1])) > 3:
                raise Failure(f'{extension}: Automatic lost paused position: {before_auto}, {auto}')
            assert_paused(session)
            offset = session.capture.stat().st_size
            session.drive('k20', 's1200', 'c')
        finally:
            capture = session.finish()
        automatic_runs = merge(_nav.runs(capture[offset:], references))
        if not automatic_runs or automatic_runs[0][0] != str(automatic):
            raise Failure(f'{extension}: Automatic chose wrong PCM: {automatic_runs}')
        checks.append(dict(test='audio track switch ' + extension, result='heard track PCM and paused time preserved',
            automatic=automatic, paused_target_ms=5000, controls=observed,
            real_keyboard_popup_choices=['Track 2', 'Automatic'],
            real_popup_runs=popup_runs,
            switched_runs=switched, automatic_runs=automatic_runs,
            reference_pcm_sha256={key: hashlib.sha256(value).hexdigest() for key,value in references.items()},
            limit='Wine playback; native Windows remains unverified'))
        print(f'{extension}: paused track switches and Automatic PCM pass', flush=True)


def asf_metadata(work, env, wine, checks):
    """Observed ASF titles and rendered cover pixels after paused track switches."""
    _asf_metadata(work, env, wine, checks)


def asf_spread(work, env, wine, checks):
    """Two spreading layouts: real popup tracks, covers and resumed PCM."""
    _asf_metadata(work, env, wine, checks, spreading=True)


def asf_extended(work, env, wine, checks):
    """Embedded streams with spreading: real popup choices and rendered metadata."""
    _asf_metadata(work, env, wine, checks, spreading=True, embedded=True)


def _asf_metadata(work, env, wine, checks, spreading=False, embedded=False):
    import json
    import struct
    spec = importlib.util.spec_from_file_location('asf_metadata_writer', ROOT / 'tests/verify-asf-metadata.py')
    metadata = importlib.util.module_from_spec(spec); spec.loader.exec_module(metadata)
    run(['x86_64-w64-mingw32-gcc', '-O2', ROOT / 'tests/asf-metadata-player-oracle.c',
         '-lgdi32', '-luser32', '-o', BIN / 'asf-metadata-player-oracle.exe'])
    images = []
    for color in ('red', 'blue'):
        image = work / ('asf-' + color + '.png')
        ffmpeg('-f', 'lavfi', '-i', f'color=c={color}:s=16x16', '-frames:v', '1', '-threads', '1', image)
        images.append(image.read_bytes())
    path = work / ('ASF Ünicode embedded.asf' if embedded else
                   'ASF Ünicode spreading.asf' if spreading else 'ASF Ünicode metadata.asf')
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=12:seed=9801:a=0.25',
           '-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=12:seed=9802:a=0.25',
           '-map', '0:a', '-map', '1:a', '-ac', '2', '-c:a', 'pcm_s16le',
           '-metadata', 'artist=LAMP Test', '-metadata', 'title=Global ASF title', path)
    if spreading:
        spec = importlib.util.spec_from_file_location('asf_spread_writer', ROOT / 'tests/verify-asf-spread.py')
        spread = importlib.util.module_from_spec(spec); spec.loader.exec_module(spread)
        formats, audio = [], []
        for ordinal in (0, 1):
            raw = work / f'gui-spread-{ordinal}.wav'
            ffmpeg('-i', path, '-map', f'0:a:{ordinal}', '-c:a', 'copy', raw)
            fmt, pcm = spread.writer.wave_parts(raw.read_bytes()); formats.append(fmt); audio.append(pcm)
        groups = [spread.packets(audio[0], 2, 768, 3, fragmented=False),
                  spread.packets(audio[1], 3, 256, 4, 2, fragmented=False)]
        interleaved = [packet for i in range(max(map(len, groups))) for group in groups for packet in group[i:i+1]]
        path.write_bytes(spread.writer.asf([spread.stream(formats[0], 2, 768, 3),
                                           spread.stream(formats[1], 3, 256, 4, 2)], interleaved,
                                          extra=[metadata.basic('Global ASF title', 'LAMP Test')]))
    if embedded:
        spec = importlib.util.spec_from_file_location('asf_extended_writer', ROOT / 'tests/verify-asf-extended.py')
        extension = importlib.util.module_from_spec(spec); spec.loader.exec_module(extension)
        path.write_bytes(extension.embedded(path.read_bytes(), names=[extension.name('Main 漢字 🎵')],
                                             systems=[extension.system(b'opaque description')]))
    data = path.read_bytes(); header_end = struct.unpack_from('<Q', data, 16)[0]
    children, streams, pos = [], [], 30
    while pos < header_end:
        size = struct.unpack_from('<Q', data, pos + 16)[0]; child = data[pos:pos + size]
        children.append(child)
        if child[:16] == metadata.writer.STREAM and child[24:40] == metadata.writer.AUDIO:
            streams.append(struct.unpack_from('<H', child, 72)[0] & 127)
        pos += size
    if embedded:
        # The independent writer preserves stream IDs 1 and 2 inside their
        # wrappers; metadata is deliberately inserted ahead of discovery.
        streams = [1, 2]
    if len(streams) != 2: raise Failure('Expected two ASF audio Stream Properties')
    names = ('ASF red 🎵', 'ASF blue 漢字')
    entries = [entry for stream, name, image in zip(streams, names, images) for entry in (
        metadata.descriptor('Title', name, stream=stream, metadata=True),
        metadata.descriptor('WM/Picture', metadata.picture(image), 1, stream=stream, metadata=True))]
    extra = metadata.extension([metadata.descriptors(entries, metadata.LIBRARY)])
    prefix = bytearray(data[:30]); struct.pack_into('<Q', prefix, 16, header_end + len(extra))
    struct.pack_into('<I', prefix, 24, len(children) + 1)
    # Put the metadata before stream discovery to exercise order independence.
    result = bytearray(prefix + extra + b''.join(children) + data[header_end:])
    position = 30 + len(extra)
    for child in children:
        if child[:16] == metadata.writer.FILE: struct.pack_into('<Q', result, position + 40, len(result))
        position += len(child)
    path.write_bytes(result)
    references = {str(n): track_pcm(work, path, n) for n in (1, 2)}
    session = Session(work, env, wine, 'asf-extended' if embedded else 'asf-spread' if spreading else 'asf-metadata', windows_path(path))
    observations = []
    spread_runs = None

    def pixels():
        return json.loads(run(['wine', BIN / 'asf-metadata-player-oracle.exe'], env=wine, timeout=30))

    def observe(name, color):
        lines = session.drive('t', 'n111', 'h113')
        art = pixels()
        if lines[0] != title(name) or lines[1] != 'Play' or int(lines[-1]) != 0 or \
                art[color] < 40 or art['blue' if color == 'red' else 'red']:
            raise Failure('ASF title/cover/paused beginning differs: ' + str((lines, art)))
        assert_paused(session)
        observations.append(dict(title=lines[0], play_control=lines[1], position=int(lines[-1]), pixels=art))

    try:
        session.drive('s1500', 'k20', 's800', 'k24', 's1200')
        observe(names[0], 'red')
        session.drive('r', 's250', 'e41', 's250', 'e23', 'e0d', 's1200')
        observe(names[1], 'blue')
        if spreading:
            spread_offset = session.capture.stat().st_size
            session.drive('k20', 's1200', 'k20', 's800')
            assert_paused(session)
            spread_runs = merge(_nav.runs(session.capture.read_bytes()[spread_offset:], references))
            if not spread_runs or spread_runs[0][0] != '2' or spread_runs[0][1] >= RATE // 2:
                raise Failure('ASF spreading Track 2 resumed wrong PCM: ' + str(spread_runs))
            session.drive('k24', 's1200')
            observe(names[1], 'blue')
        session.drive('r', 's250', 'e41', 's250', 'e24', 'e0d', 's1200')
        observe(names[0], 'red')
        offset = session.capture.stat().st_size
        session.drive('k20', 's1200', 'c')
    finally: capture = session.finish()
    heard = merge(_nav.runs(capture[offset:], references))
    if not heard or heard[0][0] != '1': raise Failure('ASF Automatic metadata did not match heard track: ' + str(heard))
    checks.append(dict(test='ASF embedded spreading track metadata and cover' if embedded else
                       'ASF spreading track metadata and cover' if spreading else 'ASF selected metadata and cover',
                       result='rendered cover and title follow paused track choice',
                       embedded_stream_properties=embedded,
                       spreading_layouts=[[2,768,3],[3,256,4]] if spreading else None,
                       selected_track_runs=spread_runs,
                       observations=observations, real_keyboard_popup_choices=['Track 2', 'Automatic'],
                       automatic_runs=heard, fixture_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                       picture_sha256=[hashlib.sha256(image).hexdigest() for image in images],
                       reference_pcm_sha256={key: hashlib.sha256(value).hexdigest() for key, value in references.items()},
                       player_sha256=hashlib.sha256((BIN / 'lamp.exe').read_bytes()).hexdigest(),
                       driver_sha256=hashlib.sha256((BIN / 'ui-driver.exe').read_bytes()).hexdigest(),
                       pixel_oracle_sha256=hashlib.sha256((BIN / 'asf-metadata-player-oracle.exe').read_bytes()).hexdigest(),
                       limit='Pixel/title/audio observations under Wine; native Windows remains unverified'))
    print('ASF '+('embedded ' if embedded else '')+('spreading ' if spreading else '')+'titles and red/blue cover pixels follow paused real-popup track switches', flush=True)


def track_queue(work, env, wine, checks):
    """Track choices persist per entry; an unsupported switch retains heard PCM."""
    first = work / 'queue-tracks.mp4'
    ffmpeg('-f','lavfi','-i',f'anoisesrc=r={RATE}:d=12:seed=9701:a=0.25',
           '-f','lavfi','-i',f'anoisesrc=r={RATE}:d=12:seed=9702:a=0.25',
           '-map','0:a','-map','1:a','-ac','2','-c:a','alac',first)
    later = tagged(work,'track-next.flac','Single after selected',4,9703)
    references = {'selected': track_pcm(work,first,2), 'single': _nav.linux_decode(work,later)}
    session = Session(work,env,wine,'track-queue',windows_path(first),windows_path(later))
    try:
        session.drive('s1500','k20','s600','k24','s1000','o402','s1200')
        assert_paused(session)
        offset = session.capture.stat().st_size
        names = session.drive('k20','s1200','k4e','s1200','t','k50','s1200','t','c')
    finally: capture = session.finish()
    segments = merge(_nav.runs(capture[offset:],references))
    expect_segments('per-file track queue',segments,[('selected',0),('single',0),('selected',0)])
    if names != [title('Single after selected'),first.name+' - LAMP']:
        raise Failure(f'Per-file track queue titles: {names}')
    checks.append(dict(test='per-file audio track queue',result='N/P retains selected entry and plays next single-track entry',
                       segments=segments,titles=names))
    print('Per-file track choice survives N/P without skipping a single-track file',flush=True)

    unsupported = work / 'unsupported-tracks.mkv'
    ffmpeg('-f','lavfi','-i',f'anoisesrc=r={RATE}:d=12:seed=9721:a=0.25',
           '-f','lavfi','-i',f'anoisesrc=r={RATE}:d=12:seed=9722:a=0.25',
           '-map','0:a','-map','1:a','-ac','2','-c:a:0','flac','-c:a:1','wmav2',unsupported)
    reference = track_pcm(work,unsupported,1)
    session = Session(work,env,wine,'unsupported-track',windows_path(unsupported),windows_path(later))
    try:
        controls = session.drive('s1500','k20','s600','k24','s1000','k27','s1200',
                                 'o402','s1200','n111','h113','t')
        if controls[0]!='Play' or abs(int(controls[3])-5000*10000//12000)>3 or \
                controls[-1]!=unsupported.name+' - LAMP':
            raise Failure(f'Unsupported track lost heard file, pause or position: {controls}')
        assert_paused(session)
        offset = session.capture.stat().st_size
        session.drive('k20','s1200','c')
    finally: capture=session.finish()
    segments=merge(_nav.runs(capture[offset:],{'retained':reference}))
    if not segments or segments[0][0]!='retained' or not 5000*48<=segments[0][1]<5200*48:
        raise Failure(f'Unsupported track did not retain previous PCM: {segments}')
    checks.append(dict(test='unsupported audio track switch',result='previous track, heard file, position and pause retained',
                       controls=controls,retained_runs=segments))
    print('Unsupported track switch retains previous heard PCM and pause',flush=True)


def eac3_playback(work, env, wine, checks):
    """The new raw codec kind plays through the GUI engine, not just --decode."""
    path=work/'enhanced.ec3'
    ffmpeg('-f','lavfi','-i',f'anoisesrc=r={RATE}:d=3:a=0.25:seed=20',
           '-ac','2','-c:a','eac3','-b:a','192k','-f','eac3',path)
    reference=_nav.linux_decode(work,path)
    session=Session(work,env,wine,'eac3',windows_path(path))
    titles=session.drive('p12000','c')
    capture=session.finish()
    expected_title='enhanced.ec3 - LAMP'
    if expected_title not in titles:raise Failure(f'E-AC-3 GUI title: {titles}')
    segments=merge(_nav.runs(capture,{'E-AC-3':reference}))
    expect_segments('E-AC-3 GUI',segments,[('E-AC-3',None)])
    if segments[0][2] < len(reference)//FRAME-RATE//4:
        raise Failure(f'E-AC-3 GUI stopped early: {segments}')
    checks.append({'test':'E-AC-3 GUI playback','result':'PCM matched through Wine sink',
                   'titles':titles,'segments':segments})
    print('E-AC-3 GUI: '+str(segments),flush=True)


if __name__ == '__main__':
    main_guard(main)
