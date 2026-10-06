#!/usr/bin/env python3
"""Same-machine playback comparison on Linux: LAMP, mpv and VLC.

usage: python3 tests/benchmark-linux.py [--runs N] [--seconds S] [--formats wav,flac,...]
                                        [--players lamp,mpv,vlc] [--workers N]

Every player plays through one private PulseAudio server into a float32
48 kHz null sink whose monitor is recorded, so times are observed where the
audio arrives rather than taken from each player's own clock. The players
run as the unprivileged user nobody (VLC refuses root), reaching the server
through an anonymous socket. They are the static Linux lamp-cli (keys on a
pseudo-terminal), mpv (JSON IPC) and VLC (its rc interface on stdin). For
each format and condition:

- **Startup:** the time from starting the process to the first sound at the
  sink, over --runs runs of a noise file. PulseAudio rewinds the null sink
  for new audio, so its monitor shows audio as soon as a client writes it:
  these are times until the server has the player's audio, without any
  device latency. paplay, PulseAudio's own minimal client, gives the floor.
- **Seek:** the time from a seek command to the first sound at the sink (as
  for startup, until the server has the new audio). A
  file of 30 s of silence and then noise plays from its start; 3 s in, the
  player seeks 60 s on (LAMP's Up, mpv's relative seek, VLC's absolute
  seek), into the noise. It then goes back to the start (LAMP's P, a seek to
  0), --runs times in one process.
- **Resources:** during --seconds of playback and then --seconds paused:
  - the process's CPU time and the PulseAudio server's, as percentages of
    one core;
  - context switches of all the player's threads and the server's, per
    second (the voluntary ones are wakeups after blocking);
  - resident and anonymous memory at the end, and the peak.

The conditions are baseline (no load added) and --workers busy processes.
Writes <out>/linux-playback-benchmark.json.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import Failure, audio_environment, build_lamp, ffmpeg, lamp_cli, main_guard, out_dir

RATE = 48000
FRAME = 8
NOBODY = ['setpriv', '--reuid=65534', '--regid=65534', '--clear-groups', '--']
THRESHOLD = 1e-3                     # sound, against digital silence
TICKS = os.sysconf('SC_CLK_TCK')
FORMATS = {
    'wav': ['-c:a', 'pcm_s16le'],
    'flac': ['-c:a', 'flac'],
    'mp3': ['-c:a', 'libmp3lame', '-b:a', '320k'],
    'vorbis': ['-c:a', 'libvorbis', '-q:a', '8'],
    'opus': ['-c:a', 'libopus', '-b:a', '128k'],
    'aac': ['-c:a', 'aac', '-b:a', '256k'],
}
EXTENSION = {'wav': 'wav', 'flac': 'flac', 'mp3': 'mp3', 'vorbis': 'ogg', 'opus': 'opus', 'aac': 'm4a'}


class Capture:
    """Records the null sink's monitor, noting when each chunk arrived."""

    def __init__(self, env):
        self.process = subprocess.Popen(['parec', '-d', 'lamp_test.monitor', '--format=float32le', f'--rate={RATE}',
                                         '--channels=2', '--raw', '--latency-msec=5'],
                                        stdout=subprocess.PIPE, env=env, bufsize=0)
        self.data = bytearray()
        self.arrivals = []           # (monotonic time, bytes received by then)
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        time.sleep(0.5)

    def read(self):
        while True:
            chunk = self.process.stdout.read(4096)
            if not chunk:
                return
            now = time.monotonic()
            with self.lock:
                self.data += chunk
                self.arrivals.append((now, len(self.data)))

    def mark(self):
        """-> the frame recorded now."""
        with self.lock:
            return len(self.data) // FRAME

    def first_sound(self, frame, timeout):
        """The first sound at or after FRAME -> its estimated arrival time, or None."""
        end = time.monotonic() + timeout
        position = frame
        while time.monotonic() < end:
            with self.lock:
                data = bytes(self.data[position * FRAME:])
                arrivals = list(self.arrivals)
            samples = memoryview(data).cast('f')
            for index in range(0, len(samples) - 1, 2):
                if abs(samples[index]) > THRESHOLD or abs(samples[index + 1]) > THRESHOLD:
                    byte = (position + index // 2) * FRAME
                    for arrived, total in arrivals:
                        if total > byte:
                            return arrived - (total - byte) / FRAME / RATE
            position += len(samples) // 2
            time.sleep(0.005)
        return None

    def stop(self):
        self.process.send_signal(signal.SIGINT)
        self.process.wait(timeout=10)


class Player:
    """A player process run as nobody; command() sends pause, seek and quit."""
    name = ''

    def __init__(self, env, path):
        self.env = env
        self.started = time.monotonic()
        self.start(path)

    def finish(self):
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


class Lamp(Player):
    name = 'lamp'
    KEYS = {'pause': b' ', 'seek': b'\x1b[A', 'back': b'p', 'quit': b'q'}

    def start(self, path):
        pid, self.fd = pty.fork()
        if pid == 0:
            os.execvpe(NOBODY[0], NOBODY + [str(self.env['LAMP_BENCH_CLI']), str(path)], self.env)
        self.pid = pid
        self.output = b''
        self.alive = True
        threading.Thread(target=self.drain, daemon=True).start()

    def drain(self):
        while self.alive:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    self.output += os.read(self.fd, 4096)
                except OSError:
                    return

    def command(self, name):
        os.write(self.fd, self.KEYS[name])

    def finish(self):
        for _ in range(200):
            if os.waitpid(self.pid, os.WNOHANG)[0]:
                break
            time.sleep(0.05)
        else:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        self.alive = False
        os.close(self.fd)


class Mpv(Player):
    name = 'mpv'

    def start(self, path):
        self.socket_path = Path(self.env['LAMP_BENCH_DIR']) / f'mpv-{os.getpid()}-{time.monotonic_ns()}.sock'
        self.process = subprocess.Popen(NOBODY + ['mpv', '--no-config', '--no-video', '--really-quiet', '--ao=pulse',
                                                  '--no-terminal', f'--input-ipc-server={self.socket_path}', str(path)],
                                        env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.pid = self.process.pid
        self.connection = None

    def command(self, name):
        if self.connection is None:
            for _ in range(400):
                try:
                    self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self.connection.connect(str(self.socket_path))
                    break
                except OSError:
                    self.connection = None
                    time.sleep(0.01)
            else:
                raise Failure('mpv did not open its IPC socket')
        request = {'pause': ['cycle', 'pause'], 'seek': ['seek', 60, 'relative'], 'back': ['seek', 0, 'absolute'],
                   'quit': ['quit']}[name]
        self.connection.sendall(json.dumps({'command': request}).encode() + b'\n')

    def finish(self):
        super().finish()
        if self.connection:
            self.connection.close()


class Vlc(Player):
    name = 'vlc'

    def start(self, path):
        self.process = subprocess.Popen(NOBODY + ['vlc', '-I', 'rc', '--rc-fake-tty', '--no-video', '--aout=pulse',
                                                  '--no-plugins-cache', '--play-and-exit', str(path)],
                                        env=self.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.pid = self.process.pid

    def command(self, name):
        text = {'pause': 'pause', 'seek': 'seek 63', 'back': 'seek 0', 'quit': 'quit'}[name]
        self.process.stdin.write(text.encode() + b'\n')
        self.process.stdin.flush()

    def finish(self):
        super().finish()
        self.process.stdin.close()


class Paplay(Player):
    """PulseAudio's own minimal client: the startup floor (WAV only)."""
    name = 'paplay'

    def start(self, path):
        self.process = subprocess.Popen(NOBODY + ['paplay', str(path)], env=self.env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pid = self.process.pid

    def command(self, name):
        self.process.terminate()


PLAYERS = {'lamp': Lamp, 'mpv': Mpv, 'vlc': Vlc}


def process_counters(pid):
    """-> (CPU seconds, voluntary and involuntary context switches of all threads)."""
    with open(f'/proc/{pid}/stat') as stat:
        fields = stat.read().rsplit(')', 1)[1].split()
    cpu = (int(fields[11]) + int(fields[12])) / TICKS
    voluntary = involuntary = 0
    for task in os.listdir(f'/proc/{pid}/task'):
        try:
            with open(f'/proc/{pid}/task/{task}/status') as status:
                for line in status:
                    if line.startswith('voluntary_ctxt_switches'):
                        voluntary += int(line.split()[1])
                    elif line.startswith('nonvoluntary_ctxt_switches'):
                        involuntary += int(line.split()[1])
        except FileNotFoundError:
            pass                     # a thread that ended
    return cpu, voluntary, involuntary


def memory(pid):
    """-> resident, anonymous and peak resident memory in MiB."""
    values = {}
    with open(f'/proc/{pid}/status') as status:
        for line in status:
            key, _, rest = line.partition(':')
            if key in ('VmRSS', 'RssAnon', 'VmHWM'):
                values[key] = int(rest.split()[0]) / 1024
    return {'rss_mib': round(values['VmRSS'], 2), 'anon_mib': round(values['RssAnon'], 2),
            'peak_mib': round(values['VmHWM'], 2)}


def system_busy():
    with open('/proc/stat') as stat:
        fields = [int(value) for value in stat.readline().split()[1:]]
    return sum(fields) - fields[3] - fields[4], sum(fields)


def window(player, server, seconds):
    """Resource use of the player and the server over SECONDS."""
    before = process_counters(player.pid), process_counters(server), system_busy(), time.monotonic()
    time.sleep(seconds)
    after = process_counters(player.pid), process_counters(server), system_busy(), time.monotonic()
    elapsed = after[3] - before[3]
    result = {}
    for label, index in (('player', 0), ('server', 1)):
        cpu = after[index][0] - before[index][0]
        result[f'{label}_cpu_percent'] = round(100 * cpu / elapsed, 2)
        result[f'{label}_voluntary_per_s'] = round((after[index][1] - before[index][1]) / elapsed, 1)
        result[f'{label}_involuntary_per_s'] = round((after[index][2] - before[index][2]) / elapsed, 1)
    busy = after[2][0] - before[2][0]
    result['system_busy_percent'] = round(100 * busy / max(1, after[2][1] - before[2][1]), 1)
    result.update(memory(player.pid))
    return result


def median(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    middle = len(values) // 2
    return values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2


def startups(kind, path, env, capture, runs):
    """Times from the process start to the first sound at the sink, in ms."""
    times = []
    for _ in range(runs):
        frame = capture.mark()
        player = kind(env, path)
        heard = capture.first_sound(frame, 15)
        times.append(None if heard is None else round(1000 * (heard - player.started), 1))
        player.command('quit')
        player.finish()
        time.sleep(0.3)
    return times


def measure(kind, fmt, fixtures, env, capture, server, runs, seconds):
    record = {'player': kind.name, 'format': fmt}
    startup = startups(kind, fixtures['noise'][fmt], env, capture, runs)
    record['startup_ms'] = startup
    # Seeks from silence into the noise, and back.
    seeks = []
    player = kind(env, fixtures['seek'][fmt])
    time.sleep(3)
    for _ in range(runs):
        frame = capture.mark()
        sent = time.monotonic()
        player.command('seek')
        heard = capture.first_sound(frame, 10)
        seeks.append(None if heard is None else round(1000 * (heard - sent), 1))
        time.sleep(1.0)
        player.command('back')
        time.sleep(3.2)
    player.command('quit')
    player.finish()
    record['seek_ms'] = seeks
    # Resources while playing, then paused.
    player = kind(env, fixtures['noise'][fmt])
    time.sleep(2)
    record['playing'] = window(player, server, seconds)
    player.command('pause')
    time.sleep(0.5)
    record['paused'] = window(player, server, seconds)
    player.command('quit')
    player.finish()
    time.sleep(0.3)
    record['startup_median_ms'] = median(startup)
    record['seek_median_ms'] = median(seeks)
    return record


def busy_worker():
    while True:
        pass


def version(command, name):
    """-> the first line of COMMAND's output that starts with NAME (warnings aside)."""
    try:
        lines = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
                               env=dict(os.environ, HOME='/tmp')).stdout.decode().splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return next((line.strip() for line in lines if line.lower().startswith(name.lower())), None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--seconds', type=float, default=10)
    parser.add_argument('--formats', default=','.join(FORMATS))
    parser.add_argument('--players', default='lamp,mpv,vlc')
    parser.add_argument('--workers', type=int, default=4)
    args = parser.parse_args()
    formats = args.formats.split(',')
    players = [PLAYERS[name] for name in args.players.split(',')]
    for tool in ('setpriv', 'parec', 'pactl', *(['mpv'] if Mpv in players else []),
                 *(['vlc'] if Vlc in players else [])):
        if not shutil.which(tool):
            raise Failure(f'{tool} is required.')
    build_lamp()
    env = audio_environment()
    if env is None:
        raise Failure('PulseAudio (pulseaudio and parec) is required.')
    work = Path(tempfile.mkdtemp(prefix='lamp-bench-'))
    work.chmod(0o755)
    try:
        run(work, env, formats, players, args)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work, env, formats, players, args):
    # The players reach the server anonymously through a socket nobody can use.
    sockets = work / 'pulse'
    sockets.mkdir()
    sockets.chmod(0o777)
    subprocess.run(['pactl', 'load-module', 'module-native-protocol-unix', f'socket={sockets}/native',
                    'auth-anonymous=1'], env=env, check=True, stdout=subprocess.DEVNULL)
    home = work / 'home'
    home.mkdir()
    shutil.chown(home, 65534, 65534)
    cli = work / 'lamp-cli'
    shutil.copy(lamp_cli(), cli)
    cli.chmod(0o755)
    player_env = {'PATH': os.environ['PATH'], 'HOME': str(home), 'PULSE_SERVER': f'unix:{sockets}/native',
                  'XDG_RUNTIME_DIR': str(home), 'LANG': 'C.UTF-8', 'TERM': 'xterm',
                  'LAMP_BENCH_CLI': str(cli), 'LAMP_BENCH_DIR': str(home)}
    with open(Path(env['XDG_RUNTIME_DIR']) / 'pulse' / 'pid') as pid_file:
        server = int(pid_file.read().split()[0])
    # Fixtures: two minutes of noise; 30 s of silence, then noise.
    fixtures = {'noise': {}, 'seek': {}}
    noise = work / 'noise.wav'                # also paplay's
    ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={RATE}:d=120:seed=5:a=0.25', '-ac', '2', '-c:a', 'pcm_s16le', noise)
    seek = work / 'seek.wav'
    ffmpeg('-f', 'lavfi', '-i', f'anullsrc=r={RATE}:cl=stereo:d=30', '-f', 'lavfi', '-i',
           f'anoisesrc=r={RATE}:d=90:seed=6:a=0.25', '-filter_complex',
           '[1:a]aformat=channel_layouts=stereo[n];[0:a][n]concat=n=2:v=0:a=1', '-c:a', 'pcm_s16le', seek)
    noise.chmod(0o644)
    for fmt in formats:
        for kind, source in (('noise', noise), ('seek', seek)):
            path = work / f'{kind}.{fmt}.{EXTENSION[fmt]}'
            ffmpeg('-i', source, *FORMATS[fmt], path)
            path.chmod(0o644)
            fixtures[kind][fmt] = path
    capture = Capture(env)
    records = []
    references = []
    try:
        # The server's first stream after the capture starts stalls its
        # monitor once; a short warm-up takes that.
        startups(Paplay, fixtures['noise'].get('wav', noise), player_env, capture, 1)
        for condition in ('baseline', 'loaded'):
            workers = []
            if condition == 'loaded':
                import multiprocessing
                workers = [multiprocessing.Process(target=busy_worker, daemon=True) for _ in range(args.workers)]
                for worker in workers:
                    worker.start()
                time.sleep(1)
            try:
                floor = startups(Paplay, noise, player_env, capture, args.runs)
                references.append({'player': 'paplay', 'format': 'wav', 'condition': condition, 'startup_ms': floor,
                                   'startup_median_ms': median(floor)})
                print(f'{condition} paplay (the floor): startup {median(floor)} ms', flush=True)
                for fmt in formats:
                    for kind in players:
                        record = measure(kind, fmt, fixtures, player_env, capture, server, args.runs, args.seconds)
                        record['condition'] = condition
                        records.append(record)
                        print(f"{condition} {fmt} {kind.name}: startup {record['startup_median_ms']} ms, seek "
                              f"{record['seek_median_ms']} ms, playing {record['playing']['player_cpu_percent']}% "
                              f"CPU, {record['playing']['player_voluntary_per_s']}/s wakeups, "
                              f"{record['playing']['rss_mib']} MiB; paused {record['paused']['player_cpu_percent']}%"
                              f", {record['paused']['player_voluntary_per_s']}/s", flush=True)
            finally:
                for worker in workers:
                    worker.terminate()
                    worker.join()
    finally:
        capture.stop()
    report = out_dir() / 'linux-playback-benchmark.json'
    report.write_text(json.dumps({
        'result': 'recorded',
        'machine': {'processor': cpu_model(), 'logical_processors': os.cpu_count(), 'kernel': platform.release()},
        'versions': {'lamp': version([str(cli)], 'LAMP'), 'mpv': version(['mpv', '--version'], 'mpv'),
                     'vlc': version(NOBODY + ['vlc', '--version'], 'VLC version'),
                     'pulseaudio': version(['pulseaudio', '--version'], 'pulseaudio')},
        'parameters': {'runs': args.runs, 'seconds': args.seconds, 'workers': args.workers, 'formats': formats},
        'references': references,
        'records': records,
    }, indent=2) + '\n', encoding='utf-8')
    print(f'Wrote {report}')


def cpu_model():
    with open('/proc/cpuinfo') as info:
        for line in info:
            if line.startswith('model name'):
                return line.split(':', 1)[1].strip()
    return None


if __name__ == '__main__':
    main_guard(main)
