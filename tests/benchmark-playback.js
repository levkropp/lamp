'use strict';
// Test-only controller. Node, C/CRT, IPC and HTTP are not player dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const http = require('node:http');
const readline = require('node:readline');
const {spawn} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const {pathToFileURL} = require('node:url');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function options() {
  const result = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    assert(process.argv[i].startsWith('--') && process.argv[i + 1], 'Use --name value pairs');
    result[process.argv[i].slice(2)] = process.argv[i + 1];
  }
  for (const key of ['bridge', 'mpv', 'vlc', 'fixtures', 'metadata', 'report']) assert(result[key], `Missing --${key}`);
  for (const [key, min, max] of [['runs', 1, 10], ['sample-seconds', 3, 30], ['load-workers', 1, 8]]) {
    result[key] = Number(result[key]);
    assert(Number.isInteger(result[key]) && result[key] >= min && result[key] <= max, `Invalid --${key}`);
  }
  result.codecs = result.codecs.split(',');
  assert(result.codecs.length && result.codecs.every(x => ['wav', 'flac', 'mp3', 'vorbis', 'opus'].includes(x)));
  result.players = (result.players || 'lamp,mpv,vlc').split(',');
  assert(result.players.length && new Set(result.players).size === result.players.length && result.players.every(x => ['lamp', 'mpv', 'vlc'].includes(x)));
  result['vlc-seek-mode'] ||= 'percent';
  assert(['percent', 'seconds'].includes(result['vlc-seek-mode']));
  return result;
}

function child(executable, args, log, pipe = false) {
  return spawn(executable, args, {windowsHide: true, stdio: [pipe ? 'pipe' : 'ignore', pipe ? 'pipe' : log, log]});
}

async function reap(proc, grace = 2000) {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  const ended = new Promise(resolve => proc.once('exit', resolve));
  await Promise.race([ended, delay(grace)]);
  if (proc.exitCode === null && proc.signalCode === null) {
    proc.kill(); // Only the subprocess created by this controller.
    await Promise.race([ended, delay(3000)]);
  }
}

class Bridge {
  constructor(proc) {
    this.proc = proc;
    this.pending = null;
    this.hello = new Promise((resolve, reject) => {
      this.helloResolve = resolve;
      this.helloReject = reject;
    });
    readline.createInterface({input: proc.stdout}).on('line', line => {
      try {
        const message = JSON.parse(line);
        if (message.bridge_ready) this.helloResolve(message);
        else if (this.pending) {
          const {resolve, reject, timer} = this.pending;
          this.pending = null;
          clearTimeout(timer);
          if (message.error) reject(new Error(JSON.stringify(message)));
          else resolve(message);
        } else throw new Error(`Unexpected bridge message: ${line}`);
      } catch (error) { this.fail(error); }
    });
    proc.once('error', error => this.fail(error));
    proc.once('exit', code => this.fail(new Error(`Bridge exited: ${code}`)));
  }
  fail(error) {
    this.helloReject(error);
    if (this.pending) {
      clearTimeout(this.pending.timer);
      this.pending.reject(error);
      this.pending = null;
    }
  }
  request(command) {
    assert(!this.pending, 'Bridge requests must be sequential');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending = null; reject(new Error(`Bridge timeout: ${command}`)); }, 15000);
      this.pending = {resolve, reject, timer};
      this.proc.stdin.write(`${command}\n`);
    });
  }
  async close() {
    if (this.proc.exitCode === null && this.proc.signalCode === null) this.proc.stdin.end('quit\n');
    await reap(this.proc);
  }
}

async function waitFor(get, predicate, description, timeout = 15000) {
  const deadline = performance.now() + timeout;
  let last;
  do {
    last = await get();
    if (predicate(last)) return last;
    await delay(5);
  } while (performance.now() < deadline);
  throw new Error(`Timeout ${description}: ${JSON.stringify(last)}`);
}

class Lamp {
  static async launch(o, log) {
    const started = performance.now();
    const bridge = new Bridge(child(o.bridge, [], log, true));
    const hello = await bridge.hello;
    const player = new Lamp();
    Object.assign(player, {proc: bridge.proc, bridge, monitor: bridge, launchMs: performance.now() - started, version: o.metadata.source_version, args: [], pid: hello.pid});
    return player;
  }
  async open(file) { await this.bridge.request(`open 0 0 ${file}`); }
  async seek(seconds, paused = false) { await this.bridge.request(`open ${seconds} ${paused ? 1 : 0} ${this.file}`); }
  async state() {
    const s = await this.bridge.request('state');
    // FLAC's bounded seek search temporarily uses decode_error while rejecting
    // speculative frame candidates. It clears the scratch result before ready.
    assert(s.alive && !s.exit_code && (!s.ready || !s.decode_error), `LAMP playback failed: ${JSON.stringify(s)}`);
    return {...s, position: s.sample_rate ? s.position_frames / s.sample_rate : null, paused: s.pause_requested};
  }
  async pause(value) {
    const s = await this.state();
    if (s.paused !== value) await this.bridge.request('pause');
  }
  async stop() {
    const s = await this.bridge.request('stop');
    assert.equal(s.thread_result, 0, 'LAMP worker returned an error');
  }
  async close() { await this.bridge.close(); }
}

class Mpv {
  static async launch(o, log) {
    const player = new Mpv();
    const pipe = `\\\\.\\pipe\\lamp-benchmark-${crypto.randomUUID()}`;
    player.args = ['--no-config', '--idle=yes', '--terminal=no', '--vid=no', '--audio-display=no', '--ao=wasapi', '--audio-exclusive=no', '--audio-fallback-to-null=no', '--volume=0', `--input-ipc-server=${pipe}`];
    const started = performance.now();
    player.proc = child(o.mpv, player.args, log);
    player.proc.once('error', error => { player.launchError = error; });
    try {
      player.socket = await waitFor(async () => {
        if (player.launchError) throw player.launchError;
        if (player.proc.exitCode !== null) throw new Error(`mpv exited ${player.proc.exitCode}`);
        return new Promise(resolve => {
          const socket = net.connect(pipe);
          socket.once('connect', () => resolve(socket));
          socket.once('error', () => { socket.destroy(); resolve(null); });
        });
      }, Boolean, 'mpv IPC server');
      player.pending = new Map();
      player.serial = 0;
      player.restartAt = -Infinity;
      readline.createInterface({input: player.socket}).on('line', line => {
        try {
          const message = JSON.parse(line);
          if (message.event === 'playback-restart') player.restartAt = performance.now();
          if (message.event === 'end-file' && message.reason === 'error') player.playbackError = message;
          const pending = player.pending.get(message.request_id);
          if (pending) {
            player.pending.delete(message.request_id);
            clearTimeout(pending.timer);
            if (message.error === 'success') pending.resolve(message.data);
            else if (pending.optional) pending.resolve(null);
            else pending.reject(new Error(`mpv command: ${JSON.stringify(message)}`));
          }
        } catch (error) { player.playbackError = {error: error.message}; }
      });
      player.socket.on('error', error => { player.playbackError = {error: error.message}; });
      player.version = await player.request(['get_property', 'mpv-version']);
      player.launchMs = performance.now() - started;
      player.monitor = new Bridge(child(o.bridge, ['--monitor', String(player.proc.pid)], log, true));
      await player.monitor.hello;
      return player;
    } catch (error) { await player.close(); throw error; }
  }
  request(command, optional = false) {
    const request_id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(request_id); reject(new Error('mpv IPC timeout')); }, 15000);
      this.pending.set(request_id, {resolve, reject, timer, optional});
      this.socket.write(`${JSON.stringify({command, request_id})}\n`);
    });
  }
  async open(file) {
    this.playbackError = null;
    this.restartAt = -Infinity;
    await this.request(['loadfile', file, 'replace']);
  }
  async seek(seconds, paused = false) {
    await this.pause(paused);
    this.restartAt = -Infinity;
    await this.request(['seek', seconds, 'absolute+exact']);
  }
  async state() {
    assert(!this.playbackError, `mpv playback error: ${JSON.stringify(this.playbackError)}`);
    const position = await this.request(['get_property', 'audio-pts'], true);
    const paused = await this.request(['get_property', 'pause']);
    return {position, paused, ready: Number.isFinite(this.restartAt), restart_at: this.restartAt};
  }
  async pause(value) { await this.request(['set_property', 'pause', value]); }
  async stop() { await this.request(['stop']); }
  async close() {
    if (this.monitor) await this.monitor.close();
    if (this.socket && !this.socket.destroyed) {
      this.socket.end(`${JSON.stringify({command: ['quit']})}\n`);
      this.socket.destroy();
    }
    await reap(this.proc);
  }
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

class Vlc {
  static async launch(o, log) {
    const player = new Vlc();
    player.seekMode = o['vlc-seek-mode'];
    player.port = await freePort();
    player.password = crypto.randomUUID();
    player.args = ['--ignore-config', '--no-one-instance', '--no-media-library', '--no-video', '--no-video-title-show', '--intf=dummy', '--extraintf=http', '--http-host=127.0.0.1', `--http-port=${player.port}`, `--http-password=${player.password}`, '--aout=mmdevice', '--mmdevice-backend=wasapi', '--mmdevice-volume=0', '--no-volume-save', '--no-metadata-network-access'];
    const started = performance.now();
    player.proc = child(o.vlc, player.args, log);
    player.proc.once('error', error => { player.launchError = error; });
    try {
      const s = await waitFor(async () => {
        if (player.launchError) throw player.launchError;
        if (player.proc.exitCode !== null) throw new Error(`VLC exited ${player.proc.exitCode}`);
        try { return await player.status(); } catch { return null; }
      }, Boolean, 'VLC HTTP interface');
      player.launchMs = performance.now() - started;
      player.version = s.version;
      await player.status({command: 'volume', val: '0'});
      player.monitor = new Bridge(child(o.bridge, ['--monitor', String(player.proc.pid)], log, true));
      await player.monitor.hello;
      return player;
    } catch (error) { await player.close(); throw error; }
  }
  status(params = {}) {
    return new Promise((resolve, reject) => {
      const req = http.get({host: '127.0.0.1', port: this.port, path: `/requests/status.json?${new URLSearchParams(params)}`, headers: {Authorization: `Basic ${Buffer.from(`:${this.password}`).toString('base64')}`}, timeout: 2000}, response => {
        let body = '';
        response.setEncoding('utf8');
        response.on('data', data => { body += data; });
        response.on('end', () => {
          try {
            assert.equal(response.statusCode, 200, `VLC HTTP ${response.statusCode}`);
            resolve(JSON.parse(body));
          } catch (error) { reject(error); }
        });
      });
      req.on('timeout', () => req.destroy(new Error('VLC HTTP timeout')));
      req.on('error', reject);
    });
  }
  async open(file) { await this.status({command: 'in_play', input: pathToFileURL(file).href}); }
  async seek(seconds, paused = false) {
    await this.pause(paused);
    if (this.seekMode === 'seconds') {
      await this.status({command: 'seek', val: String(seconds)});
      return;
    }
    const s = await this.status();
    assert(s.length > 0, 'VLC needs a known duration for an absolute percentage seek');
    // VLC's HTTP seconds path uses input time; its Ogg demuxer's time path
    // can estimate byte position from bitrate. Percentage uses indexed/bisect
    // position seeking for local Ogg. Keep the target in absolute seconds.
    await this.status({command: 'seek', val: `${seconds / s.length * 100}%`});
  }
  async state() {
    const s = await this.status();
    // VLC time is floored; position*length retains fractional input-clock progress.
    return {...s, position: s.length > 0 ? s.position * s.length : null, paused: s.state === 'paused', ready: s.state === 'playing' || s.state === 'paused'};
  }
  async pause(value) { await this.status({command: value ? 'pl_forcepause' : 'pl_forceresume'}); }
  async stop() { await this.status({command: 'pl_stop'}); }
  async close() {
    if (this.monitor) await this.monitor.close();
    await reap(this.proc, 0); // HTTP has no quit command; terminate only our VLC process.
  }
}

async function operation(player, command, target, kind, paused = false) {
  const start = performance.now();
  await command();
  const ackMs = performance.now() - start;
  let readyMs = null;
  // VLC can retain a preceding compressed-frame timestamp while paused.
  // Record that offset rather than demanding sample-exactness from its UI API.
  const pausedTolerance = player instanceof Vlc ? 0.1 : 0.01;
  const state = await waitFor(async () => {
    const s = await player.state();
    if (s.ready && readyMs === null) readyMs = performance.now() - start;
    return s;
  }, s => s.ready && Number.isFinite(s.position) && s.position >= target + (paused ? -pausedTolerance : 0.10) && s.position < target + (paused ? pausedTolerance : 5) && s.paused === paused, `${kind} to ${target}s`);
  if (player instanceof Lamp) {
    assert.equal(state.underruns, 0, 'LAMP queue underrun during operation');
    assert.equal(state.endpoint_dry, 0, 'LAMP endpoint empty during operation');
  }
  return {kind, target_seconds: target, paused, command_ack_ms: ackMs, ready_observed_ms: readyMs, progress_100ms_observed_ms: paused ? null : performance.now() - start, position_observed_seconds: state.position,
    paused_target_offset_seconds: paused ? state.position - target : null, paused_target_tolerance_seconds: paused ? pausedTolerance : null,
    lamp_counters: player instanceof Lamp ? {underruns: state.underruns, endpoint_dry: state.endpoint_dry} : null};
}

async function sampleWindow(player, seconds, phase) {
  // No player polling during the CPU window. Two passive process/system snapshots.
  const a = await player.monitor.request('sample');
  await delay(seconds * 1000);
  const b = await player.monitor.request('sample');
  const wall = (b.qpc - a.qpc) / b.qpc_frequency;
  const systemTotal = b.system_kernel_100ns + b.system_user_100ns - a.system_kernel_100ns - a.system_user_100ns;
  const cpu = (b.cpu_100ns - a.cpu_100ns) / 1e7;
  return {phase, wall_seconds: wall, process_cpu_seconds: cpu, one_core_equivalent_percent: cpu / wall * 100,
    system_busy_percent: (1 - (b.system_idle_100ns - a.system_idle_100ns) / systemTotal) * 100,
    working_set_start_bytes: a.working_set_bytes, working_set_end_bytes: b.working_set_bytes,
    private_start_bytes: a.private_bytes, private_end_bytes: b.private_bytes,
    wakeups_per_second: null, wakeup_status: 'not measured; process CPU accounting is not a wakeup counter'};
}

async function benchmark(player, file, o) {
  player.file = file;
  const operations = [];
  for (let run = 0; run < o.runs; run++) {
    operations.push({...await operation(player, () => player.open(file), 0, run ? 'reopen' : 'open'), run: run + 1});
    if (player instanceof Mpv) {
      assert.equal(await player.request(['get_property', 'current-ao']), 'wasapi', 'mpv must use a real WASAPI output');
      assert.equal(await player.request(['get_property', 'volume']), 0, 'mpv must remain muted');
    }
    if (player instanceof Vlc) assert.equal((await player.status()).volume, 0, 'VLC must remain muted');
    for (const target of [84, 300, 564]) {
      operations.push({...await operation(player, () => player.seek(target), target, 'seek'), run: run + 1});
    }
  }
  // Start in the middle of the noise section, away from silence transitions.
  await operation(player, () => player.seek(84), 84, 'steady-noise-seek');
  await delay(1000);
  const samples = [await sampleWindow(player, o['sample-seconds'], 'playing_noise')];
  const playEnd = await player.state();
  assert(playEnd.position >= 84 + o['sample-seconds'] * 0.8, 'Playback clock did not advance');
  if (player instanceof Lamp) {
    assert.equal(playEnd.underruns, 0, 'LAMP steady playback queue underrun');
    assert.equal(playEnd.endpoint_dry, 0, 'LAMP steady playback endpoint empty');
  }
  await player.pause(true);
  await delay(500); // Let endpoint stop, counters and reported clocks settle.
  const beforePause = await player.state();
  assert(beforePause.paused, 'Pause request was not accepted');
  samples.push(await sampleWindow(player, o['sample-seconds'], 'paused'));
  const afterPause = await player.state();
  assert(afterPause.paused && Math.abs(afterPause.position - beforePause.position) < 0.05, 'Paused playback clock advanced');
  const pausedSeek = await operation(player, () => player.seek(300, true), 300, 'paused_seek', true);
  await delay(500);
  const pausedSeekStart = await player.state();
  await delay(1000);
  const pausedSeekEnd = await player.state();
  assert(pausedSeekEnd.paused && Math.abs(pausedSeekEnd.position - pausedSeekStart.position) < 0.05, 'Paused seek played unexpectedly');
  const resumed = await operation(player, () => player.pause(false), 300, 'resume');
  const last = await player.state();
  if (player instanceof Lamp) {
    assert.equal(last.underruns, 0, 'LAMP queue underrun');
    assert.equal(last.endpoint_dry, 0, 'LAMP endpoint empty before refill');
  }
  await player.stop();
  await delay(500);
  samples.push(await sampleWindow(player, o['sample-seconds'], 'idle_after_stop'));
  return {operations, samples, paused_seek: pausedSeek, resume: resumed, paused_clock_delta_seconds: afterPause.position - beforePause.position,
    paused_seek_clock_delta_seconds: pausedSeekEnd.position - pausedSeekStart.position,
    lamp_counters: player instanceof Lamp ? {playing_noise: {underruns: playEnd.underruns, endpoint_dry: playEnd.endpoint_dry}, after_resume: {underruns: last.underruns, endpoint_dry: last.endpoint_dry}} : null};
}

async function main() {
  const o = options();
  assert.equal(process.platform, 'win32', 'This benchmark requires Windows/WASAPI');
  o.metadata = JSON.parse(fs.readFileSync(o.metadata, 'utf8').replace(/^\uFEFF/, ''));
  const fixtures = o.codecs.map(codec => {
    const file = path.resolve(o.fixtures, `${codec}-600.${codec === 'vorbis' ? 'ogg' : codec}`);
    assert(fs.existsSync(file), `Generate ten-minute fixtures first: ${file}`);
    return {codec, file, bytes: fs.statSync(file).size, sha256: hash(file)};
  });
  const report = {result: 'incomplete', recorded_utc: new Date().toISOString(), ...o.metadata,
    scope: 'Headless audio-engine comparison, not shipping GUI or audible/physical endpoint latency. LAMP is the unchanged assembly engine in a test-only C/CRT stdin bridge; mpv uses JSON named-pipe IPC and VLC uses authenticated loopback HTTP. All use shared Windows audio and volume zero; decoding still processes noise. Windows process CPU times are coarse. Warm OS cache, no cache eviction, background user processes remain running. Operation timings include controller/IPC polling; readiness and clock semantics differ. No wakeup/ETW, GUI, cold disk, GPU, listening quality or other hardware measurements.',
    timing_definitions: {lamp_ready: '750ms queue prebuffer, before first WASAPI fill/Start', mpv_ready: 'observed playback-restart event', vlc_ready: 'HTTP playlist state playing/paused, not render-ready',
      progress: 'first observed clock >= target+100ms after active operation; LAMP endpoint-consumption position, mpv audio-pts including driver delay, VLC fractional input position*integer duration. Not equivalent audible clocks. Paused operations record target observation only.', polling_delay_ms: 5},
    runs: o.runs, sample_seconds: o['sample-seconds'], requested_load_workers: o['load-workers'], selected_players: o.players, vlc_seek_mode: o['vlc-seek-mode'], fixture_description: '600s 48kHz stereo seeded independent noise: 20s silence/40s noise; MP3 320k, Vorbis q8, Opus 128k',
    players: {lamp: {executable: path.basename(o.bridge), sha256: hash(o.bridge)}, mpv: {executable: path.basename(o.mpv), sha256: hash(o.mpv)}, vlc: {executable: path.basename(o.vlc), sha256: hash(o.vlc)}},
    fixtures: fixtures.map(({file, ...f}) => ({...f, file: path.basename(file)})), checks: []};
  const save = () => fs.writeFileSync(o.report, `${JSON.stringify(report, null, 2)}\n`);
  save();
  try {
    for (const condition of ['baseline', 'cpu_load']) {
      const workers = [];
      try {
        if (condition === 'cpu_load') {
          for (let i = 0; i < o['load-workers']; i++) workers.push(spawn(process.execPath, [__filename, '--load-worker', String(30 * 60 * 1000)], {windowsHide: true, stdio: 'ignore'}));
          await delay(1000);
        }
        for (let i = 0; i < fixtures.length; i++) {
          const fixture = fixtures[i];
          // Rotate order by codec and condition; no concurrent players/encoding.
          const names = o.players;
          const rotation = (i + (condition === 'cpu_load' ? 1 : 0)) % names.length;
          for (const name of [...names.slice(rotation), ...names.slice(0, rotation)]) {
            const logFile = path.join(path.dirname(o.report), `playback-${condition}-${fixture.codec}-${name}.log`);
            const log = fs.openSync(logFile, 'w');
            let player;
            try {
              if (workers.length) assert(workers.every(p => p.exitCode === null && p.signalCode === null), 'A load worker exited early');
              const type = {lamp: Lamp, mpv: Mpv, vlc: Vlc}[name];
              player = await type.launch(o, log);
              report.players[name].version = player.version;
              report.players[name].arguments = player.args.map(x => x.startsWith('--http-password=') ? '--http-password=<unique local benchmark password>' : x.startsWith('--input-ipc-server=') ? '--input-ipc-server=<unique local benchmark pipe>' : x.startsWith('--http-port=') ? '--http-port=<unique loopback port>' : x);
              const result = await benchmark(player, fixture.file, o);
              report.checks.push({condition, added_cpu_workers: workers.length, codec: fixture.codec, player: name, launch_to_control_ready_ms: player.launchMs, ...result});
              save();
              console.log(`${condition} ${fixture.codec} ${name}: passed; noise CPU=${result.samples[0].one_core_equivalent_percent.toFixed(3)}% of one core, working set=${(result.samples[0].working_set_end_bytes / 1048576).toFixed(2)}MiB`);
            } finally {
              if (player) await player.close();
              fs.closeSync(log);
            }
          }
        }
      } finally {
        for (const worker of workers) {
          if (worker.exitCode === null && worker.signalCode === null) worker.kill();
          await reap(worker, 0);
        }
      }
    }
    report.result = 'passed';
  } catch (error) { report.failure = error.message; throw error; }
  finally { report.finished_utc = new Date().toISOString(); save(); }
}

if (process.argv[2] === '--load-worker') {
  // Bounded independent CPU load. The controller also kills its owned workers.
  const deadline = performance.now() + Number(process.argv[3]);
  let value = 1;
  while (performance.now() < deadline) {
    for (let i = 0; i < 100000; i++) value = Math.sqrt(value + 1.23456789);
  }
  process.stdout.write(`${value}\n`);
} else {
  main().catch(error => { console.error(error.stack); process.exitCode = 1; });
}
