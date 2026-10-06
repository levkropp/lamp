#!/usr/bin/env python3
"""G.726 and G.722 ADPCM in WAVE and AU files against FFmpeg.

usage: python3 tests/verify-telephony.py [--skip-playback]
- FFmpeg's encoders write G.726 at 16, 24, 32 and 40 kbit/s (2-5-bit codes)
  at 8 kHz, and at 16 kHz with -strict, into WAVE (tag 0x45, codes from
  the most significant bit) and AU (codes from the least significant bit;
  encodings 23, 25, 26 and "7262" set for each code size, as FFmpeg's muxer
  labels every size 23), and G.722 at 16 kHz into WAVE (tag 0x28f) and AU
  (encoding 24). LAMP's decode equals FFmpeg's exactly.
- WAVE files relabelled with G.726's other tags (0x14, 0x40, 0x64) decode
  as 0x45. Random bytes are valid codes: 24 random streams of every code
  size (and G.722) reach the quantizers' extremes, transitions and
  clipping, and equal FFmpeg's decode; data of 3- and 5-bit codes that end
  inside a code decode the whole codes.
- Seeks equal continuous decoding (tests/seek-oracle.c): the state runs on
  across packets, and a seek decodes three primer packets from a reset
  state, which converge on the continuous state in every case tested.
- Two channels, code sizes 1 and 6 and 7 kHz reject as unsupported
  (decode_error 101), malformed headers otherwise; a cancelled open stops
  cleanly.
Writes <out>/telephony-verification.json.
"""
import array
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)


def ffmpeg_mono(path):
    """FFmpeg's float32 decode, doubled into two channels as LAMP outputs mono."""
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(path), '-f', 'f32le', '-'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # A last packet ending inside a code: FFmpeg decodes its whole codes and says so.
    text = [line for line in result.stderr.decode('utf-8', 'replace').splitlines()
            if 'Frame invalidly split' not in line]
    if result.returncode or text:
        raise Failure(f'FFmpeg on {Path(path).name}: {text[:3]}')
    mono = array.array('f', result.stdout)
    stereo = array.array('f', [0.0]) * (2 * len(mono))
    stereo[0::2] = mono
    stereo[1::2] = mono
    return stereo.tobytes()


def wave(tag, rate, bits, data, block=1):
    fmt = struct.pack('<HHIIHHH', tag, 1, rate, rate * bits // 8, block, bits, 0)
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
    if len(data) & 1:
        body += b'\0'
    return b'RIFF' + struct.pack('<I', len(body)) + body


def au(encoding, rate, data):
    return b'.snd' + struct.pack('>IIIII', 24, len(data), encoding, rate, 1) + data


def chunk_of(data, name):
    at = data.index(name) + 8
    return at, struct.unpack_from('<I', data, at - 4)[0]


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('telephony')
    checks = []

    def lamp(path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def compare(path, note):
        native = ffmpeg_mono(path)
        ours, stats = lamp(path)
        if ours != native:
            raise Failure(f'{path.name}: {len(ours) // 8} frames differ from FFmpeg\'s {len(native) // 8}')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': 'FFmpeg', 'note': note, 'stats': stats})
        return native

    def source(rate, duration, seed):
        voice = (f'(0.6*sin(2*PI*{180 + seed}*t)+0.25*sin(2*PI*{1200 + 7 * seed}*t)+0.15*(random({seed})-0.5))'
                 f'*sin(2*PI*0.9*t)*if(lt(mod(t\\,1.7)\\,0.3)\\,0\\,1)')
        return ['-f', 'lavfi', '-i', f'aevalsrc={voice}:s={rate}:d={duration}']

    # FFmpeg's encoders, in WAVE and AU.
    au_encoding = {2: 0x37323632, 3: 25, 4: 23, 5: 26}
    for k, bits in enumerate((2, 3, 4, 5)):
        for rate in (8000, 16000):
            strict = [] if rate == 8000 else ['-strict', '-2']
            path = work / f'g726-{bits}bit-{rate}.wav'
            ffmpeg(*source(rate, 6, k), '-c:a', 'g726', '-code_size', str(bits), *strict, path)
            compare(path, f'G.726 {bits}-bit, tag 0x45')
        raw = subprocess.run(['ffmpeg', '-v', 'error', *source(8000, 6, 10 + k), '-c:a', 'g726le', '-code_size',
                              str(bits), '-f', 'au', '-'], stdout=subprocess.PIPE, check=True).stdout
        offset = struct.unpack_from('>I', raw, 4)[0]
        path = work / f'g726-{bits}bit.au'
        path.write_bytes(au(au_encoding[bits], 8000, raw[offset:]))
        compare(path, f'G.726 {bits}-bit in AU, encoding {au_encoding[bits]:#x}')
    for container in ('wav', 'au'):
        path = work / f'g722.{container}'
        ffmpeg(*source(16000, 6, 20), '-c:a', 'g722', path)
        compare(path, 'G.722')
    print(f'{len(checks)} FFmpeg-encoded G.726 and G.722 files: exact', flush=True)

    # G.726's other WAVE tags.
    base = (work / 'g726-4bit-8000.wav').read_bytes()
    fmt_at = base.index(b'fmt ') + 8
    reference = Path(str(work / 'g726-4bit-8000.wav') + '.f32').read_bytes()
    for tag in (0x14, 0x40, 0x64):
        data = bytearray(base)
        struct.pack_into('<H', data, fmt_at, tag)
        path = work / f'g726-tag-{tag:#06x}.wav'
        path.write_bytes(bytes(data))
        ours, stats = lamp(path)
        if ours != reference:
            raise Failure(f'{path.name}: differs from tag 0x45')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': 'tag 0x45'})
    print('tags 0x14, 0x40 and 0x64 decode as 0x45', flush=True)

    # Random codes.
    r = random.Random(726)
    streams = 0
    for bits in (2, 3, 4, 5):
        for n in range(5):
            size = r.choice((1, 2, 7, 4095, 4096, 9001, 20000))
            data = bytes(r.randrange(256) for _ in range(size))
            path = work / f'random-{bits}bit-{n}.wav'
            path.write_bytes(wave(0x45, 8000, bits, data, bits if bits in (3, 5) else 1))
            compare(path, f'random {bits}-bit codes, {size} bytes')
            if n < 2:
                path = work / f'random-{bits}bit-{n}.au'
                path.write_bytes(au(au_encoding[bits], 8000, data))
                compare(path, f'random {bits}-bit codes in AU, {size} bytes')
                streams += 1
            streams += 1
    for n, size in enumerate((1, 333, 4096, 30001)):
        data = bytes(r.randrange(256) for _ in range(size))
        path = work / f'random-g722-{n}.wav'
        path.write_bytes(wave(0x28f, 16000, 4, data))
        compare(path, f'random G.722 codewords, {size} bytes')
        streams += 1
    print(f'{streams} random code streams: exact', flush=True)

    # Seeks.
    for name in ('g726-2bit-8000.wav', 'g726-3bit-16000.wav', 'g726-4bit-8000.wav', 'g726-5bit-8000.wav',
                 'g726-3bit.au', 'g722.wav', 'g722.au'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Rejections.
    def patch(data, offset, fmt, value):
        data = bytearray(data)
        struct.pack_into(fmt, data, offset, value)
        return bytes(data)
    g722 = (work / 'g722.wav').read_bytes()
    g722_fmt = g722.index(b'fmt ') + 8
    au4 = (work / 'g726-4bit.au').read_bytes()
    unsupported = {'g726-stereo.wav': patch(base, fmt_at + 2, '<H', 2), 'g726-1bit.wav': patch(base, fmt_at + 14, '<H', 1),
                   'g726-6bit.wav': patch(base, fmt_at + 14, '<H', 6), 'g722-stereo.wav': patch(g722, g722_fmt + 2, '<H', 2),
                   'g726-stereo.au': patch(au4, 20, '>I', 2), 'g726-7khz.wav': patch(base, fmt_at + 4, '<I', 7000)}
    malformed = {'g726-no-channels.wav': patch(base, fmt_at + 2, '<H', 0),
                 'g726-no-block.wav': patch(base, fmt_at + 12, '<H', 0),
                 'g726-no-data.au': au4[:24]}
    rejected = 0
    for group, files in (('unsupported', unsupported), ('malformed', malformed)):
        for name, data in files.items():
            (work / name).write_bytes(data)
            line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
            result = json.loads(line)
            unsupported_error = result.get('decode_error') == 101
            if result.get('result') != 'rejected' or unsupported_error != (group == 'unsupported'):
                raise Failure(f'{name}: expected a {group} rejection, got {line}')
            checks.append({'test': name, 'result': 'rejected', 'oracle': line})
            rejected += 1
    print(f'Rejected {rejected} unsupported and malformed files', flush=True)
    line = run([chain, 'cancel-open', work / 'g726-4bit-8000.wav']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open g726-4bit-8000.wav', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'G.722 playback', 'result': 'played', 'stats': play(work / 'g722.wav')})
    write_report('telephony', {'result': 'passed', 'checks': checks, 'random_streams': streams,
                               'rejections': rejected,
                               'scope': 'G.726 (2-5-bit codes, 8 and 16 kHz) and G.722 in WAVE and AU, FFmpeg-encoded '
                                        'and random code streams, exact against FFmpeg; other G.726 tags; seeks; '
                                        'unsupported and malformed files; cancellation.'})
    print(f'Passed {len(checks)} G.726/G.722 checks.')


if __name__ == '__main__':
    main_guard(main)
