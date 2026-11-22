#!/usr/bin/env python3
"""Compare native Windows and WSL Linux exports from the same source checkout.

Run on Windows after building both targets. Requires FFmpeg and WSL Ubuntu.
This checks platform parity, not independent codec conformance or audio devices.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(command):
    result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited {result.returncode}: '
                           + result.stdout.decode('utf-8', 'replace')[-4000:])
    return result.stdout.decode('utf-8', 'replace').strip()


def wsl_path(path):
    path = Path(path).resolve()
    return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows', type=Path, default=ROOT/'bin/caught-up/lamp-cli.exe')
    parser.add_argument('--linux', type=Path, default=ROOT/'build/caught-up/lamp-cli')
    parser.add_argument('--distribution', default='Ubuntu')
    args = parser.parse_args()
    windows, linux = args.windows.resolve(), args.linux.resolve()
    scratch = ROOT/'tests/generated/windows-crossbuild'
    scratch.mkdir(parents=True, exist_ok=True)
    cases = [
        ('pcm16.wav', 'pcm_s16le', 48000, 2, []),
        ('float64.wav', 'pcm_f64le', 44100, 1, []),
        ('signed.aiff', 'pcm_s24be', 48000, 2, []),
        ('lossless.flac', 'flac', 44100, 2, []),
        ('mpeg.mp3', 'libmp3lame', 44100, 2, []),
        ('vorbis.ogg', 'libvorbis', 48000, 2, []),
        ('opus.opus', 'libopus', 48000, 2, []),
        ('aac.m4a', 'aac', 44100, 2, []),
        ('aac.adts', 'aac', 48000, 1, ['-f', 'adts']),
        ('alac.m4a', 'alac', 48000, 2, []),
        ('mpeg2.mp2', 'mp2', 48000, 2, []),
        ('dolby.ac3', 'ac3', 48000, 2, []),
        ('enhanced.eac3', 'eac3', 48000, 2, []),
        ('alaw.wav', 'pcm_alaw', 8000, 1, []),
        ('mulaw.au', 'pcm_mulaw', 8000, 1, []),
        ('ima.wav', 'adpcm_ima_wav', 22050, 2, []),
        ('ms.wav', 'adpcm_ms', 22050, 2, []),
        ('ima.caf', 'adpcm_ima_qt', 44100, 2, []),
        ('alac.caf', 'alac', 48000, 2, []),
        ('wave64.w64', 'pcm_s24le', 44100, 2, []),
        ('flash.flv', 'adpcm_swf', 22050, 2, []),
        ('matroska.mka', 'flac', 48000, 2, []),
        ('webm.webm', 'libopus', 48000, 2, []),
        ('avi.avi', 'pcm_s16le', 44100, 2, []),
        ('asf.asf', 'libmp3lame', 44100, 2, []),
        ('fragmented.mp4', 'aac', 48000, 2,
         ['-movflags', 'frag_keyframe+empty_moov']),
    ]
    # Tiny 24-bit files reach every Wave64 alignment residue. The old reader
    # rejected FFmpeg files whose declared padding ended in a partial frame.
    cases += [(f'padding-{channels}-{frames}.w64', 'pcm_s24le', 44100, channels,
               ['-af', f'atrim=end_sample={frames}'])
              for channels in (1, 2) for frames in range(1, 18)]
    results = []
    for name, codec, rate, channels, extra in cases:
        fixture = scratch/name
        run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi',
             '-i', f'sine=frequency=317:sample_rate={rate}:duration=0.173',
             '-ac', channels, '-c:a', codec, *extra, fixture])
        exports = [scratch/(name+'.windows.f32'), scratch/(name+'.linux.f32')]
        for output in exports:
            output.unlink(missing_ok=True)
        run([windows, '--decode', fixture, exports[0]])
        run(['wsl.exe', '-d', args.distribution, '--', wsl_path(linux),
             '--decode', wsl_path(fixture), wsl_path(exports[1])])
        native, reference = [p.read_bytes() for p in exports]
        if not native or len(native) % 8 or native != reference:
            raise RuntimeError(f'{name}: native Windows/Linux PCM differs '
                               f'({len(native)}/{len(reference)} bytes)')
        samples = [x[0] for x in struct.iter_unpack('<f', native)]
        if not all(abs(x) < 16 for x in samples) or (not name.startswith('padding-')
                                                   and max(map(abs, samples)) < .01):
            raise RuntimeError(f'{name}: invalid or silent PCM')
        if fixture.suffix == '.w64':
            reference_file = scratch/(name+'.ffmpeg.f32')
            run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', fixture,
                 *(['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else ['-ac', 2]),
                 '-f', 'f32le', reference_file])
            if native != reference_file.read_bytes():
                raise RuntimeError(f'{name}: Wave64 PCM differs from FFmpeg')
        results.append(dict(file=name, codec=codec, source_rate=rate,
                            source_channels=channels, frames=len(native)//8,
                            pcm_sha256=hashlib.sha256(native).hexdigest(), result='passed'))
        print(f'{name}: {len(native)//8} frames, exact', flush=True)
    seek_checks = 0
    continuous = (scratch/'wave64.w64.windows.f32').read_bytes()
    for milliseconds in (0, 1, 17, 1000):
        for label, prefix, fixture in (
                ('windows', [str(windows)], str(scratch/'wave64.w64')),
                ('linux', ['wsl.exe', '-d', args.distribution, '--', wsl_path(linux)],
                 wsl_path(scratch/'wave64.w64'))):
            output = scratch/f'seek-{label}-{milliseconds}.f32'
            output.unlink(missing_ok=True)
            run([*prefix, '--start', f'{milliseconds/1000:.3f}', '--decode', fixture,
                 wsl_path(output) if label == 'linux' else str(output)])
            if output.read_bytes() != continuous[(milliseconds*44100//1000)*8:]:
                raise RuntimeError(f'{label}: Wave64 seek mismatch at {milliseconds}ms')
            seek_checks += 1
    invalid = scratch/'incomplete-frame.wav'
    fmt = struct.pack('<HHIIHH', 1, 2, 48000, 192000, 4, 16)
    body = b'WAVEfmt ' + struct.pack('<I', 16) + fmt + b'data' + struct.pack('<I', 3) + bytes(4)
    invalid.write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
    unaligned = scratch/'unaligned-partial.w64'
    data = bytearray((scratch/'wave64.w64').read_bytes())
    at = data.index(bytes.fromhex('64617461f3acd3118cd100c04f8edb8a'))
    struct.pack_into('<Q', data, at+16, struct.unpack_from('<Q', data, at+16)[0]-1)
    data.pop()
    struct.pack_into('<Q', data, 16, len(data))
    unaligned.write_bytes(data)
    for fixture in (invalid, unaligned):
        for command in ([str(windows), '--check', str(fixture)],
                        ['wsl.exe', '-d', args.distribution, '--', wsl_path(linux),
                         '--check', wsl_path(fixture)]):
            result = subprocess.run(command, capture_output=True, timeout=30)
            if result.returncode != 2:
                raise RuntimeError(f'{fixture.name}: expected clean rejection, got {result.returncode}')
    report = dict(result='passed', scope=__doc__.strip(),
                  ffmpeg=run(['ffmpeg', '-version']).splitlines()[0],
                  binaries=[dict(file=str(p.relative_to(ROOT)),
                                 sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                            for p in (windows, linux)], checks=results,
                  rejections=[invalid.name, unaligned.name], exact_seek_checks=seek_checks)
    output = windows.parent/'windows-crossbuild-verification.json'
    output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'Passed {len(results)} native Windows/Linux PCM comparisons.')


if __name__ == '__main__':
    main()
