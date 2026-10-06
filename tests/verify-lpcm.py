#!/usr/bin/env python3
"""DVD LPCM in program streams and Blu-ray LPCM in transport streams.

usage: python3 tests/verify-lpcm.py [--skip-playback]
- FFmpeg writes DVD LPCM (pcm_dvd, 16 and 24 bits at 48 and 96 kHz, mono to
  7.1, and pcm_s16be at 44.1 and 32 kHz) into VOB files, and Blu-ray LPCM
  (pcm_bluray, all ten channel assignments, 16 and 24 bits, 48-192 kHz)
  into M2TS files. LAMP's decode of each equals its decode of FFmpeg's WAVE
  copy of the same stream exactly, channel layout included.
- tests/lpcm_vectors.py writes what FFmpeg's encoders do not: DVD LPCM of
  1-8 channels at 16, 20 and 24 bits at all four rates, with sample blocks
  straddling packets and the emphasis, mute and frame number bits set;
  Blu-ray LPCM of every assignment at 16 and 24 bits in 188- and 192-byte
  transport streams, and packets ending inside a frame (FFmpeg drops the
  partial frame). LAMP's decode equals the WAVE file of the samples written,
  and FFmpeg's decode equals the samples.
- A second DVD substream is skipped; seeks (tests/seek-oracle.c) equal
  continuous decoding.
- Unsupported (decode_error 101): 28-bit DVD samples, a DVD substream whose
  dynamic range byte marks it as MLP (as FFmpeg tells them apart), 20-bit
  Blu-ray samples, reserved Blu-ray rates and assignments, a format change
  in either, and stream type 0x80 without an HDMV registration. Malformed
  (100): a Blu-ray packet too short for its header, streams without
  samples. A cancelled open stops cleanly; one file plays.
Writes <out>/lpcm-verification.json.
"""
import array
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lpcm_vectors as lv
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)


def ours(path):
    out = Path(str(path) + '.f32')
    stats = decode_f32(path, out)
    return out.read_bytes(), stats


def ffmpeg_ints(path):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(path), '-f', 's32le', '-'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Failure(f'FFmpeg on {Path(path).name}: {result.stderr.decode()[:200]}')
    return array.array('i', result.stdout)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('lpcm')
    checks = []

    def same(path, reference, note=None):
        """LAMP's decode of path equals its decode of the WAVE file reference."""
        pcm, stats = ours(path)
        if 'codec=18 ' not in stats:
            raise Failure(f'{path.name}: {stats}')
        expected, _ = ours(reference)
        if pcm != expected:
            raise Failure(f'{path.name}: differs from {reference.name} ({stats})')
        entry = {'test': path.name, 'result': 'exact', 'comparator': reference.name}
        if note:
            entry['note'] = note
        checks.append(entry)

    def written(path, data, frames, rate, bits, mask, note=None):
        """A written stream: LAMP equals the WAVE of its samples, FFmpeg
        equals the samples."""
        path.write_bytes(data)
        reference = Path(str(path) + '.wav')
        reference.write_bytes(lv.wave(frames, rate, bits, mask))
        same(path, reference, note)
        expected = [v << (32 - bits) for row in frames for v in row]
        if list(ffmpeg_ints(path)) != expected:
            raise Failure(f'{path.name}: FFmpeg does not decode the samples written')
        checks[-1]['ffmpeg'] = 'equal to the samples written'

    # FFmpeg's DVD LPCM.
    count = 0
    for layout, channels in (('mono', 1), ('stereo', 2), ('5.1', 6), ('7.1', 8)):
        for fmt, bits in (('s16', 16), ('s32', 24)):
            for rate in (48000, 96000):
                if channels * bits * rate > 9_800_000:
                    continue                           # above FFmpeg's encoder limit
                name = f'dvd-{layout}-{bits}-{rate // 1000}k.vob'
                path = work / name
                ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d=1.5:a=0.3:seed={count + 1}', '-af',
                       f'aformat=channel_layouts={layout}', '-c:a', 'pcm_dvd', '-sample_fmt', fmt, '-f', 'vob', path)
                reference = work / (name + '.wav')
                ffmpeg('-i', path, '-c:a', f'pcm_s{bits}le', reference)
                same(path, reference)
                count += 1
    for rate in (44100, 32000):
        for channels in (1, 2):
            path = work / f'dvd-s16be-{channels}ch-{rate // 1000}k.vob'
            ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d=1.5:a=0.3:seed={count + 1}', '-ac', str(channels),
                   '-c:a', 'pcm_s16be', '-f', 'vob', path)
            reference = Path(str(path) + '.wav')
            ffmpeg('-i', path, '-c:a', 'pcm_s16le', reference)
            same(path, reference)
            count += 1
    print(f'{count} FFmpeg DVD LPCM files: exact', flush=True)

    # FFmpeg's Blu-ray LPCM.
    layouts = {1: 'mono', 3: 'stereo', 4: '3.0', 5: '3.0(back)', 6: '4.0', 7: 'quad(side)', 8: '5.0(side)',
               9: '5.1(side)', 10: '7.0', 11: '7.1'}
    count = 0
    for code, layout in layouts.items():
        for fmt, bits in (('s16', 16), ('s32', 24)):
            rate = (48000, 96000, 192000)[(code + bits) % 3]
            name = f'bd-{layout.replace("(", "-").replace(")", "")}-{bits}-{rate // 1000}k.m2ts'
            path = work / name
            ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d=1:a=0.3:seed={code}', '-af',
                   f'aformat=channel_layouts={layout}', '-c:a', 'pcm_bluray', '-sample_fmt', fmt, '-f', 'mpegts',
                   '-mpegts_m2ts_mode', '1', path)
            reference = work / (name + '.wav')
            ffmpeg('-i', path, '-c:a', f'pcm_s{bits}le', reference)
            same(path, reference)
            count += 1
    print(f'{count} FFmpeg Blu-ray LPCM files: exact', flush=True)

    # Written DVD LPCM: every channel count, 20 bits, every rate.
    count = 0
    for channels in range(1, 9):
        for bits in (16, 20, 24):
            rate = lv.DVD_RATES[(channels + bits) % 4]
            block = lv.dvd_block_frames(channels, bits)
            frames = lv.samples(channels * 100 + bits, (2400 // block) * block, channels, bits)
            path = work / f'written-dvd-{channels}ch-{bits}.vob'
            written(path, lv.dvd_stream(frames, rate, bits, packet=1999), frames, rate, bits,
                    lv.DVD_MASKS[channels - 1])
            count += 1
    frames = lv.samples(7, 2400, 2, 24)
    second = lv.samples(8, 2400, 2, 24)
    path = work / 'written-dvd-two-substreams.vob'
    written(path, lv.dvd_stream(frames, 48000, 24, extra=second), frames, 48000, 24, 0x3,
            'the first substream (0xA0) plays')
    print(f'{count + 1} written DVD LPCM streams: exact, FFmpeg agreeing', flush=True)

    # Written Blu-ray LPCM.
    count = 0
    for code in lv.BD_LAYOUTS:
        for bits in (16, 24):
            rate = (48000, 96000, 192000)[(code * 2 + bits) % 3]
            mask = lv.BD_LAYOUTS[code][1]
            frames = lv.samples(code * 10 + bits, 2400, bin(mask).count('1'), bits)
            path = work / f'written-bd-{code}-{bits}.{"m2ts" if code % 2 else "ts"}'
            written(path, lv.bluray_stream(frames, code, rate, bits, m2ts=code % 2 == 1), frames, rate, bits, mask)
            count += 1
    frames = lv.samples(99, 2400, 6, 24)
    path = work / 'written-bd-partial.m2ts'
    written(path, lv.bluray_stream(frames, 9, 48000, 24, partial=7), frames, 48000, 24, 0x60f,
            'seven bytes of a cut frame end each packet; FFmpeg and LAMP drop them')
    print(f'{count + 1} written Blu-ray LPCM streams: exact, FFmpeg agreeing', flush=True)

    # Seeks.
    for name in ('written-dvd-6ch-20.vob', 'written-dvd-1ch-24.vob', 'dvd-stereo-24-48k.vob',
                 'written-bd-9-24.m2ts', 'written-bd-partial.m2ts', 'bd-stereo-16-96k.m2ts'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Unsupported and malformed streams.
    rejected = 0

    def reject(name, data, code):
        nonlocal rejected
        path = work / name
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != code:
            raise Failure(f'{name}: expected decode_error {code}, got {line}')
        rejected += 1
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})

    stereo16 = lv.samples(1, 2400, 2, 16)
    stereo24 = lv.samples(2, 2400, 2, 24)
    surround = lv.samples(3, 2400, 6, 16)
    reject('dvd-28-bit.vob', lv.dvd_stream(stereo24, 48000, 24, header=0xc1), 101)
    reject('dvd-mlp.vob', lv.dvd_stream(stereo24, 48000, 24, drc=0x40), 101)
    reject('dvd-change.vob', lv.dvd_stream(stereo16, 48000, 16, change=(1, 0x11)), 101)
    reject('bd-20-bit.m2ts', lv.bluray_stream(stereo24, 3, 48000, 20), 101)
    reject('bd-rate.m2ts', lv.bluray_stream(stereo16, 3, 48000, 16, header=3 << 12 | 2 << 8 | 1 << 6), 101)
    reject('bd-assignment.m2ts', lv.bluray_stream(stereo16, 3, 48000, 16, header=2 << 12 | 1 << 8 | 1 << 6), 101)
    reject('bd-change.m2ts', lv.bluray_stream(surround, 9, 48000, 16, change=(2, 9 << 12 | 4 << 8 | 1 << 6)), 101)
    reject('bd-no-hdmv.ts', lv.bluray_stream(stereo16, 3, 48000, 16, hdmv=False, m2ts=False), 101)
    short = lv.latm_vectors.transport_pes([b'\x00\x04'], 900, 0x80, stream_id=0xbd, program_info=b'\x05\x04HDMV')
    reject('bd-short.ts', short, 100)
    header_only = lv.latm_vectors.transport_pes([b'\x00\x00\x31\x40'] * 3, 900, 0x80, stream_id=0xbd,
                                                program_info=b'\x05\x04HDMV', m2ts=True)
    reject('bd-empty.m2ts', header_only, 100)
    reject('dvd-empty.vob', lv.dvd_stream([[0, 0]], 48000, 24), 100)
    print(f'Rejected {rejected} unsupported or malformed streams', flush=True)

    line = run([chain, 'cancel-open', work / 'written-dvd-6ch-20.vob']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open written-dvd-6ch-20.vob', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'LPCM playback', 'result': 'played', 'stats': play(work / 'written-bd-9-24.m2ts')})
    write_report('lpcm', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                          'scope': 'DVD LPCM in program streams (16/20/24-bit, 1-8 channels, four rates) and '
                                   'Blu-ray LPCM in transport streams (ten channel assignments, 16/24-bit, '
                                   '48-192 kHz): FFmpeg-written files exact against FFmpeg WAVE copies, written '
                                   'streams exact against their samples in LAMP and FFmpeg; seeks; unsupported '
                                   'and malformed streams; cancellation.'})
    print(f'Passed {len(checks)} LPCM checks.')


if __name__ == '__main__':
    main_guard(main)
