#!/usr/bin/env python3
"""Sun/NeXT AU files.

usage: python3 tests/verify-au.py
- From FFmpeg's muxer: signed 8-32-bit, float32/64, A-law and µ-law, mono
  and stereo at 8-96 kHz, exact against FFmpeg; 5.1 exact against the same
  audio in WAVE.
- Rewritten here: an unknown data size (0xFFFFFFFF), a long annotation, a
  data size shorter than the file and a file cut inside a frame decode as
  the original's audio.
- Seeks equal continuous decoding; malformed and unsupported headers reject.
Writes <out>/au-verification.json.
"""
import json
from pathlib import Path
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, run, scratch,
                       stereo_view, write_report)


def ffmpeg_native(path, output):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(path), '-f', 'f32le',
                             str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode or result.stdout.strip():
        raise Failure(f'FFmpeg on {Path(path).name}: {result.stdout[-300:]}')
    return Path(output).read_bytes()


def header(offset, size, encoding, rate, channels):
    return b'.snd' + struct.pack('>5I', offset, size, encoding, rate, channels)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('au')
    checks = []

    def lamp(path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def source(rate, channels, seconds, seed):
        tones = '|'.join(f'0.4*sin(2*PI*{89 * (k + 3) + seed}*t)*sin(2*PI*0.9*t+{k})+0.1*random({k})-0.05'
                         for k in range(channels))
        return ['-f', 'lavfi', '-i', f'aevalsrc={tones}:s={rate}:d={seconds}']

    def exact(path, reference, comparator, note=''):
        ours, stats = lamp(path)
        if ours != reference:
            raise Failure(f'{path.name}: differs from {comparator}')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': comparator, 'note': note, 'stats': stats})
        print(f'{path.name}: exact against {comparator}', flush=True)

    seed = 0
    rates = (8000, 22050, 44100, 48000, 96000)
    for k, codec in enumerate(('pcm_s8', 'pcm_s16be', 'pcm_s24be', 'pcm_s32be', 'pcm_f32be', 'pcm_f64be', 'pcm_alaw',
                               'pcm_mulaw')):
        for channels in (1, 2):
            seed += 1
            path = work / f'{codec}-{channels}.au'
            ffmpeg(*source(rates[(k + channels) % len(rates)], channels, 0.7, seed), '-c:a', codec, path)
            native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
            exact(path, stereo_view(native, channels, 0), 'FFmpeg')
    seed += 1
    au, wav = work / 'pcm-5.1.au', work / 'pcm-5.1.wav'
    for target, codec in ((au, 'pcm_s16be'), (wav, 'pcm_s16le')):
        ffmpeg(*source(48000, 6, 0.6, seed), '-af', 'aformat=channel_layouts=5.1', '-c:a', codec, target)
    exact(au, lamp(wav)[0], 'the same audio in WAVE (5.1)', 'default layout')

    # Rewritten headers.
    base = work / 'pcm_s24be-2.au'
    data = base.read_bytes()
    offset, size = struct.unpack_from('>2I', data, 4)
    payload = data[offset:offset + size]
    encoding, rate, channels = struct.unpack_from('>3I', data, 12)
    reference = lamp(base)[0]
    annotation = b'Title=Long annotation\n' + b'x' * 300 + b'\0' * 6
    for name, contents, note in (
            ('unknown-size.au', header(offset, 0xffffffff, encoding, rate, channels) + data[24:], 'data size 0xFFFFFFFF'),
            ('annotation.au', header(24 + len(annotation), size, encoding, rate, channels) + annotation + payload,
             'a 328-byte annotation'),
            ('trailing.au', data + b'TRAILING DATA' * 10, 'bytes after the declared data'),
            ('minimal.au', header(24, size, encoding, rate, channels) + payload, 'no annotation')):
        path = work / name
        path.write_bytes(contents)
        exact(path, reference, base.name, note)
    frame = 3 * channels
    path = work / 'cut.au'
    path.write_bytes(data[:offset + 100 * frame + 2])
    exact(path, reference[:100 * 8], f'the first 100 frames of {base.name}', 'a file cut inside a frame')
    path = work / 'cut-unknown.au'
    path.write_bytes(header(offset, 0xffffffff, encoding, rate, channels) + data[24:offset + 50 * frame + 1])
    exact(path, reference[:50 * 8], f'the first 50 frames of {base.name}', 'unknown size, cut inside a frame')

    # Seeks.
    for name in ('pcm_s16be-2.au', 'pcm_s8-1.au', 'pcm_f64be-2.au', 'pcm_alaw-1.au', 'pcm-5.1.au', 'unknown-size.au'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0', '0', '0']).strip().splitlines()[-1]
        result = json.loads(line)
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {result["checks"]} checks', flush=True)

    # Rejections.
    pcm = b'\0' * 400
    bad = {
        'g721.au': (header(24, 400, 23, 8000, 1) + pcm, 101),
        'g722.au': (header(24, 400, 24, 16000, 1) + pcm, 101),
        'zero-channels.au': (header(24, 400, 3, 44100, 0) + pcm, 100),
        'nine-channels.au': (header(24, 400, 3, 44100, 9) + pcm, 101),
        'zero-rate.au': (header(24, 400, 3, 0, 2) + pcm, 100),
        'slow-rate.au': (header(24, 400, 3, 4000, 2) + pcm, 101),
        'small-offset.au': (header(16, 400, 3, 44100, 2) + pcm, 100),
        'offset-past-end.au': (header(5000, 400, 3, 44100, 2) + pcm, 100),
        'short-header.au': (header(24, 400, 3, 44100, 2)[:20], None),
    }
    rejected = 0
    for name, (contents, code) in bad.items():
        (work / name).write_bytes(contents)
        line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
        result = json.loads(line)
        if result.get('result') != 'rejected' or (code is not None and result.get('decode_error') != code):
            raise Failure(f'{name}: expected a rejection ({code}), got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
        rejected += 1
    print(f'Rejected {rejected} malformed or unsupported files', flush=True)

    write_report('au', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                        'scope': 'Sun/NeXT AU (signed 8-32-bit, float32/64, G.711, mono to 5.1) against FFmpeg or '
                                 'the same audio in WAVE; rewritten headers, unknown sizes and truncation; seeks; '
                                 'malformed and unsupported headers.'})
    print(f'Passed {len(checks)} AU checks.')


if __name__ == '__main__':
    main_guard(main)
