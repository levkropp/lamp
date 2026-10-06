#!/usr/bin/env python3
"""MPEG transport and program stream audio against the raw streams they carry.

usage: python3 tests/verify-mpegts.py [--skip-playback]
- FFmpeg writes raw MPEG Layer II and III, ADTS AAC and AC-3 streams, then
  copies them into transport streams (188-byte packets, 192-byte M2TS,
  204-byte packets made by padding, AC-3 signalled by stream type 0x81 or by
  the DVB descriptor, with video, with a second audio stream) and program
  streams (MPEG-2 VOB and MPEG-1 system streams, with video). Every decode
  must equal LAMP's decode of the raw stream, and one of each codec is also
  compared with FFmpeg's decode of the container.
- Seeks in transport and program streams equal continuous decoding.
- E-AC-3 rejects as unsupported (LATM AAC and LPCM are checked in
  verify-latm.py and verify-lpcm.py); streams without audio or tables reject
  as malformed; a cancelled open stops cleanly.
Writes <out>/mpegts-verification.json.
"""
import array
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ac3_vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)

RAW = {'mp2': ['-c:a', 'mp2', '-b:a', '192k', '-f', 'mp2'],
       'mp3': ['-c:a', 'libmp3lame', '-b:a', '160k', '-write_xing', '0', '-id3v2_version', '0', '-f', 'mp3'],
       'aac': ['-c:a', 'aac', '-b:a', '128k', '-f', 'adts'],
       'ac3': ['-c:a', 'ac3', '-b:a', '192k', '-f', 'ac3'],
       'ac3-5.1': ['-c:a', 'ac3', '-b:a', '448k', '-f', 'ac3']}
FLOAT_DECODER = {'mp2': 'mp2float', 'mp3': 'mp3float'}


def floats(path):
    return array.array('f', Path(path).read_bytes())


def snr(ours, reference):
    a, b = floats(ours), floats(reference)
    if len(a) != len(b):
        raise Failure(f'{Path(ours).name}: {len(a) // 2} frames, FFmpeg {len(b) // 2}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b) or 1.0
    return math.inf if error == 0 else 10 * math.log10(signal / error)


def pad_packets(source, target):
    """188-byte packets -> 204-byte packets (16 zero bytes in place of the
    Reed-Solomon parity)."""
    data = Path(source).read_bytes()
    out = bytearray()
    for i in range(0, len(data), 188):
        out += data[i:i + 188] + bytes(16)
    Path(target).write_bytes(bytes(out))


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('mpegts')
    checks = []
    noise = 'anoisesrc=r=48000:d=3:a=0.3:seed={seed}'
    video = ['-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=25:duration=3']
    raw = {}
    for k, (name, coding) in enumerate(RAW.items()):
        layout = ['-af', 'aformat=channel_layouts=5.1(side)'] if name.endswith('5.1') else ['-ac', '2']
        path = work / f'{name}.raw'
        ffmpeg('-f', 'lavfi', '-i', noise.format(seed=k + 1), *layout, *coding, path)
        pcm = Path(str(path) + '.f32')
        decode_f32(path, pcm)
        raw[name] = (path, pcm.read_bytes())

    def exact(container, name, note):
        ours = Path(str(container) + '.f32')
        stats = decode_f32(container, ours)
        if ours.read_bytes() != raw[name][1]:
            raise Failure(f'{container.name}: differs from the raw {name} stream')
        checks.append({'test': container.name, 'result': 'exact', 'comparator': f'raw {name}', 'layout': note,
                       'stats': stats.splitlines()[-1]})

    variants = 0
    for name, (path, _) in raw.items():
        ts = work / f'{name}.ts'
        ffmpeg('-i', path, '-c', 'copy', '-f', 'mpegts', ts)
        exact(ts, name, '188-byte packets')
        m2ts = work / f'{name}.m2ts'
        ffmpeg('-i', path, '-c', 'copy', '-f', 'mpegts', '-mpegts_m2ts_mode', '1', m2ts)
        exact(m2ts, name, '192-byte M2TS packets')
        padded = work / f'{name}-204.ts'
        pad_packets(ts, padded)
        exact(padded, name, '204-byte packets')
        with_video = work / f'{name}-video.ts'
        ffmpeg(*video, '-i', path, '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg2video', '-c:a', 'copy', '-f', 'mpegts',
               with_video)
        exact(with_video, name, 'with video')
        variants += 4
        if name.startswith('ac3'):
            dvb = work / f'{name}-dvb.ts'
            ffmpeg('-i', path, '-c', 'copy', '-f', 'mpegts', '-mpegts_flags', 'system_b', dvb)
            exact(dvb, name, 'stream type 0x06 with the DVB AC-3 descriptor')
            variants += 1
        if name in ('mp2', 'ac3', 'mp3'):
            for muxer, suffix in (('vob', 'vob'), ('mpeg', 'mpg')):
                if muxer == 'mpeg' and name == 'ac3':
                    continue
                ps = work / f'{name}.{suffix}'
                ffmpeg('-i', path, '-c', 'copy', '-f', muxer, ps)
                exact(ps, name, 'MPEG-2 program stream' if muxer == 'vob' else 'MPEG-1 system stream')
                variants += 1
            ps_video = work / f'{name}-video.vob'
            ffmpeg(*video, '-i', path, '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg2video', '-c:a', 'copy', '-f', 'vob',
                   ps_video)
            exact(ps_video, name, 'program stream with video')
            variants += 1
        print(f'{name}: transport and program stream copies exact', flush=True)
    # The first audio stream of the program is selected.
    two = work / 'two-audio.ts'
    ffmpeg('-i', raw['ac3'][0], '-i', raw['mp2'][0], '-map', '0:a', '-map', '1:a', '-c', 'copy', '-f', 'mpegts', two)
    exact(two, 'ac3', 'two audio streams, the first selected')
    variants += 1
    checks.append({'test': 'container variants', 'result': 'exact', 'files': variants})

    # Against FFmpeg's decode of the container.
    for name in ('mp2', 'mp3', 'aac', 'ac3', 'ac3-5.1'):
        ts = work / f'{name}.ts'
        reference = Path(str(ts) + '.ffmpeg.f32')
        decoder = ['-c:a', FLOAT_DECODER[name]] if name in FLOAT_DECODER else []
        if name.endswith('5.1'):
            continue                                   # mixed output; the raw decode is checked in verify-ac3.py
        ffmpeg('-cpuflags', '0', *decoder, '-i', ts, '-f', 'f32le', reference)
        level = snr(Path(str(ts) + '.f32'), reference)
        if level < 110:
            raise Failure(f'{ts.name}: {level:.1f} dB against FFmpeg')
        checks.append({'test': f'{ts.name} against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})
        print(f'{ts.name}: {level:.1f} dB against FFmpeg', flush=True)

    # Seeks (exact: FFmpeg's AC-3 is dithered, so a dither-free written
    # stream stands in for it).
    data, _ = ac3_vectors.stream(42, 60, 7, 1, dither=0.0)
    (work / 'written.ac3').write_bytes(data)
    ffmpeg('-i', work / 'written.ac3', '-c', 'copy', '-f', 'mpegts', work / 'written-ac3.ts')
    decode_f32(work / 'written-ac3.ts', work / 'written-ac3.ts.f32')
    for name in ('written-ac3.ts', 'mp2.m2ts', 'mp3-video.ts', 'mp2.vob'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Unsupported and malformed streams.
    rejected = 0
    unsupported = {
        'eac3.ts': ['-c:a', 'eac3', '-f', 'mpegts'],
        'eac3-dvb.ts': ['-c:a', 'eac3', '-f', 'mpegts', '-mpegts_flags', 'system_b'],
    }
    for name, coding in unsupported.items():
        path = work / name
        ffmpeg('-f', 'lavfi', '-i', noise.format(seed=9), '-ac', '2', *coding, path)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 101:
            raise Failure(f'{name}: expected decode_error 101, got {line}')
        rejected += 1
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
    video_only = work / 'video-only.ts'
    ffmpeg(*video, '-c:v', 'mpeg2video', '-f', 'mpegts', video_only)
    no_tables = work / 'no-tables.ts'
    data = bytearray((work / 'mp2.ts').read_bytes())
    for i in range(0, len(data), 188):
        pid = (data[i + 1] & 0x1f) << 8 | data[i + 2]
        if pid in (0, 0x1000):                         # PAT and FFmpeg's PMT
            data[i + 1] = (data[i + 1] & 0xe0) | 0x1f
            data[i + 2] = 0xff                         # null packets
    no_tables.write_bytes(bytes(data))
    video_ps = work / 'video-only.vob'
    ffmpeg(*video, '-c:v', 'mpeg2video', '-f', 'vob', video_ps)
    for path in (video_only, no_tables, video_ps):
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 100:
            raise Failure(f'{path.name}: expected decode_error 100, got {line}')
        rejected += 1
        checks.append({'test': path.name, 'result': 'rejected', 'oracle': line})
    print(f'Rejected {rejected} unsupported or malformed streams', flush=True)

    line = run([chain, 'cancel-open', work / 'ac3-video.ts']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open ac3-video.ts', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'transport stream playback', 'result': 'played', 'stats': play(work / 'ac3-video.ts')})
    write_report('mpegts', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                            'scope': 'MPEG transport streams (188/192/204-byte packets, stream type and DVB '
                                     'descriptor signalling, video and second audio streams) and program streams '
                                     '(MPEG-2 VOB, MPEG-1 system streams, video) carrying MPEG Layer II/III, ADTS '
                                     'AAC and AC-3, exact against the raw streams and close to FFmpeg; seeks; '
                                     'unsupported and malformed streams; cancellation.'})
    print(f'Passed {len(checks)} MPEG-TS/PS checks.')


if __name__ == '__main__':
    main_guard(main)
