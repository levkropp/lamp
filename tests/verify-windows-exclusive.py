#!/usr/bin/env python3
"""Silent native exclusive WASAPI lifecycle/EOF/queue/error checks.

This test acquires the default endpoint in exclusive mode. It does not change
the selected device or send desktop input. Build engine-probe with both
--probe-exclusive and --probe-default-device. Requires Windows and FFmpeg.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import threading
import wave

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, timeout=45):
    return subprocess.run([str(x) for x in command], capture_output=True,
                          text=True, timeout=timeout, creationflags=subprocess.CREATE_NO_WINDOW)


def silence(path, frames):
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(48000)
        out.writeframes(bytes(frames * 4))


def stats(text):
    return {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', text)}


def busy_check(exe, primary_path, secondary_path):
    first = subprocess.Popen([str(exe), '--exclusive', str(primary_path)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                creationflags=subprocess.CREATE_NO_WINDOW)
    lines, ready = [], threading.Event()
    def collect():
        for line in first.stdout:
            lines.append(line)
            if 'Playing.' in line:
                ready.set()
    reader = threading.Thread(target=collect, daemon=True)
    reader.start()
    try:
        assert ready.wait(5), 'Primary exclusive stream failed to open: ' + ''.join(lines)
        second = run([exe, '--exclusive', secondary_path], timeout=5)
        first.wait(timeout=8)
        reader.join(timeout=2)
        assert not reader.is_alive(), 'Primary output reader did not close'
        first_text, second_text = ''.join(lines), second.stdout
        assert first.returncode == 0, first_text
        assert second.returncode == 3 and not second.stderr and 'Exclusive output unavailable' in second_text, second_text + second.stderr
        assert stats(first_text)['heard_frames'] == 144000, first_text
        assert stats(second_text)['audio_error'] == 0x8889000A, second_text  # DEVICE_IN_USE
        return {'result': 'passed', 'primary_frames': 144000,
                'secondary_exit': second.returncode, 'secondary_audio_error': '0x8889000a'}
    finally:
        if first.poll() is None:
            first.kill()                 # only this test's own process
            first.wait(timeout=5)
        reader.join(timeout=2)
        first.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', type=Path, default=ROOT / 'bin/exclusive-check')
    args = parser.parse_args()
    if os.name != 'nt':
        raise SystemExit('Native Windows required; this test acquires an exclusive endpoint.')
    binary = args.bin.resolve()
    exe, probe = binary / 'lamp-cli.exe', binary / 'engine-probe.exe'
    scratch = ROOT / 'tests/generated/exclusive-output'
    scratch.mkdir(parents=True, exist_ok=True)
    checks = []
    for name, extension, codec, rate, layout in [
        ('wav', 'wav', 'pcm_s16le', 48000, 'stereo'),
        ('flac', 'flac', 'flac', 44100, '5.1'),
        ('mp3', 'mp3', 'libmp3lame', 44100, 'stereo'),
        ('vorbis', 'ogg', 'libvorbis', 48000, '7.1'),
        ('opus', 'opus', 'libopus', 48000, '5.1'),
        ('aiff', 'aiff', 'pcm_f64be', 48000, '5.1'),
    ]:
        path = scratch / f'silence-{name}.{extension}'
        made = run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi',
                    '-i', f'anullsrc=r={rate}:cl={layout}:d=30', '-c:a', codec, path])
        assert made.returncode == 0, made.stderr
        played = run([probe, path])
        assert played.returncode == 0 and not played.stderr, played.stdout + played.stderr
        assert 'Exclusive output: 48000 Hz session lifecycle passed.' in played.stdout, played.stdout
        assert 'Default-device callback: paused and active restart passed' in played.stdout, played.stdout
        checks.append({'codec': name, 'source_rate': rate, 'source_layout': layout,
                       'session_rate': 48000, 'result': 'passed'})
        print(f'{name}: exclusive pause/resume/stop/reopen/seek/cancel and notification restart passed', flush=True)

    tails = []
    for frames in [0, 1, 2, 3, 17, 257, 511, 512, 513, 1023, 1024, 1025, 14400]:
        path = scratch / f'tail-{frames}.wav'
        silence(path, frames)
        played = run([exe, '--exclusive', path], timeout=8)
        result = stats(played.stdout)
        assert played.returncode == 0 and not played.stderr, played.stdout + played.stderr
        assert 'output_mode=exclusive' in played.stdout, played.stdout
        assert result['frames'] == result['heard_frames'] == frames, played.stdout
        assert result['audio_error'] == result['decode_error'] == result['underruns'] == 0, played.stdout
        tails.append({'frames': frames, 'heard_frames': result['heard_frames'],
                      'output_bits': result['output_bits'], 'output_valid_bits': result['output_valid_bits'],
                      'buffer_frames': result['buffer_frames'], 'result': 'passed'})
    print('13 exact natural EOF/empty/tiny/partial-buffer cases passed', flush=True)

    # Mixed-rate queues exercise the same resampler and real-frame timeline.
    queued = run([exe, '--exclusive', '--rate', '48000', '--start', '29.5',
                  scratch / 'silence-flac.flac', scratch / 'tail-14400.wav'], timeout=8)
    result = stats(queued.stdout)
    assert queued.returncode == 0 and not queued.stderr, queued.stdout + queued.stderr
    # The inherited frames statistic includes the initial seek position.
    # The heard position must end at the same absolute queue-frame boundary.
    assert result['frames'] == result['heard_frames'] == 1440000 + 14400, queued.stdout
    assert result['elapsed_ms'] >= 750, queued.stdout
    assert result['audio_error'] == result['decode_error'] == 0, queued.stdout

    invalid = [['--exclusive', '--check'], ['--decode', '--exclusive'],
               ['--exclusive', '--tags'], ['--exclusive', '--list-devices']]
    for options in invalid:
        bad = run([exe, *options, scratch / 'tail-17.wav'], timeout=5)
        assert 'Usage: lamp-cli.exe' in bad.stdout and 'Playing.' not in bad.stdout, bad.stdout

    # Confirm rates rejected by the read-only probe fail without changing
    # endpoint or silently falling back to shared mode.
    component = json.loads((binary / 'windows-output-format-verification.json').read_text())
    rejected = []
    for choice in component.get('device_profiles', []):
        if choice['hresult'] != '0x88890008':
            continue
        bad = run([exe, '--exclusive', '--rate', str(choice['rate']), scratch / 'tail-17.wav'], timeout=5)
        assert bad.returncode == 3 and 'Exclusive output unavailable' in bad.stdout, bad.stdout
        assert stats(bad.stdout)['audio_error'] == 0x88890008, bad.stdout
        rejected.append(choice['rate'])
    primary = scratch / 'busy-primary.wav'
    silence(primary, 144000)
    busy = busy_check(exe, primary, scratch / 'tail-14400.wav')
    print('Mixed-rate queue, rejected options/rates and busy-endpoint checks passed', flush=True)
    report = {
        'result': 'passed', 'recorded_utc': datetime.now(timezone.utc).isoformat(),
        'platform': platform.platform(), 'exclusive_playback': True,
        'scope': 'Silent native default-endpoint WASAPI, six codec/source-layout lifecycle cases at a 48 kHz session, synthetic paused/active notification restarts, exact clock-mapped natural EOF tails, mixed-rate queue/start, CLI misuse, queried unsupported rates and busy endpoint. No system device selection changes or desktop input. Physical device changes, captured hardware PCM, glitches and latency/performance remain unverified.',
        'lifecycle_checks': checks, 'eof_checks': tails,
        'mixed_rate_queue': {'frames_stat': result['frames'], 'heard_frames': result['heard_frames'], 'start_frame': 1416000, 'played_frames_after_start': 38400, 'result': 'passed'},
        'invalid_option_cases': len(invalid), 'unsupported_rates': rejected, 'busy_endpoint': busy,
        'component_report_sha256': digest(binary / 'windows-output-format-verification.json'),
        'cli_sha256': digest(exe), 'gui_sha256': digest(binary / 'lamp.exe'),
        'engine_probe_sha256': digest(probe), 'player_source_sha256': digest(ROOT / 'src/win/player.s'),
        'ffmpeg': run(['ffmpeg', '-version']).stdout.splitlines()[0],
    }
    output = binary / 'windows-exclusive-verification.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'Exclusive playback report: {output}', flush=True)


if __name__ == '__main__':
    main()
