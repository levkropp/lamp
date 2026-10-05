#!/usr/bin/env python3
"""MP4/M4A/MOV audio: ALAC, MPEG audio, Opus, FLAC and PCM sample entries.

usage: python3 tests/verify-mp4.py [--skip-playback]
FFmpeg muxes each fixture; its decode of the same file is the reference:
exact for ALAC, FLAC and PCM, within the codec suites' tolerances for Opus
and MPEG audio. Opus and FLAC must also equal LAMP's decode of the same
stream in Ogg/native FLAC, and ALAC in Matroska must equal ALAC in MP4.
Fragmented files (moof/trun, default-base-is-moof and explicit offsets)
must decode like their progressive versions. Seeks are exact for ALAC,
FLAC, PCM and MPEG audio; Opus seeks must equal Ogg Opus seeks. Malformed
tables reject. Writes <out>/mp4-verification.json.
"""
import array
import math
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, check_file, decode_f32, exe, ffmpeg, main_guard, out_dir,
                       play, playback_requested, run, scratch, write_report)

TOLERANCE = {'opus': (0.00004, 60.0), 'mp3': (0.00002, 90.0), 'mp2': (0.00004, 70.0)}


def measure(ours, reference):
    a = array.array('f', Path(ours).read_bytes())
    b = array.array('f', Path(reference).read_bytes())
    if len(a) != len(b):
        return math.inf, -math.inf, len(a), len(b)
    peak = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b)
    snr = math.inf if error == 0 else 10 * math.log10(signal / error) if signal else -math.inf
    return peak, snr, len(a), len(b)


def boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack_from('>I4s', data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, pos + 8)[0]
            header = 16
        elif size == 0:
            size = end - pos
        yield kind, pos, pos + header, pos + size
        pos += size


def find(data, path, start=0, end=None):
    """Payload range of the first box along a path such as moov/trak/mdia."""
    end = len(data) if end is None else end
    for name in path.split('/'):
        for kind, pos, payload, stop in boxes(data, start, end):
            if kind == name.encode():
                start, end = payload, stop
                break
        else:
            return None
    return start, end


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('mp4')
    checks = []
    tone = 'aevalsrc=0.3*sin(2*PI*997*t)+0.05*sin(2*PI*5100*t)|0.2*sin(2*PI*431*t):s={rate}:d=1.5'
    noise = 'anoisesrc=r={rate}:d=1.2:a=0.25:seed={seed}'
    fixtures = [
        ('alac-16', 'alac', 44100, ['-c:a', 'alac', '-sample_fmt', 's16p'], 2, None, 'm4a'),
        ('alac-24-96k', 'alac', 96000, ['-c:a', 'alac', '-sample_fmt', 's32p'], 2, None, 'm4a'),
        ('alac-mono', 'alac', 22050, ['-c:a', 'alac', '-sample_fmt', 's16p'], 1, None, 'm4a'),
        ('alac-5.1', 'alac', 48000, ['-c:a', 'alac'], 6, '5.1', 'm4a'),
        ('alac-small-frames', 'alac', 48000, ['-c:a', 'alac', '-sample_fmt', 's16p', '-frame_size', '1024',
                                                '-compression_level', '2'], 2, None, 'm4a'),
        ('mp3', 'mp3', 44100, ['-c:a', 'libmp3lame', '-b:a', '160k'], 2, None, 'mp4'),
        ('mp2', 'mp2', 48000, ['-c:a', 'mp2', '-b:a', '192k'], 2, None, 'mp4'),
        ('opus', 'opus', 48000, ['-c:a', 'libopus', '-b:a', '96k'], 2, None, 'mp4'),
        ('opus-5.1', 'opus', 48000, ['-c:a', 'libopus', '-b:a', '256k', '-mapping_family', '1'], 6, '5.1', 'mp4'),
        ('flac', 'flac', 44100, ['-c:a', 'flac', '-sample_fmt', 's16', '-strict', '-2'], 2, None, 'mp4'),
        ('flac-24', 'flac', 48000, ['-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-strict', '-2'], 2,
         None, 'mp4'),
        ('pcm-s16le', 'pcm', 44100, ['-c:a', 'pcm_s16le'], 2, None, 'mov'),
        ('pcm-s16be', 'pcm', 48000, ['-c:a', 'pcm_s16be'], 2, None, 'mov'),
        ('pcm-s24be', 'pcm', 48000, ['-c:a', 'pcm_s24be'], 2, None, 'mov'),
        ('pcm-s24le', 'pcm', 48000, ['-c:a', 'pcm_s24le'], 2, None, 'mov'),
        ('pcm-s32be', 'pcm', 32000, ['-c:a', 'pcm_s32be'], 2, None, 'mov'),
        ('pcm-f32be', 'pcm', 48000, ['-c:a', 'pcm_f32be'], 1, None, 'mov'),
        ('pcm-f64le', 'pcm', 48000, ['-c:a', 'pcm_f64le'], 2, None, 'mov'),
        ('pcm-u8', 'pcm', 8000, ['-c:a', 'pcm_u8'], 1, None, 'mov'),
        ('pcm-s8', 'pcm', 8000, ['-c:a', 'pcm_s8'], 1, None, 'mov'),
    ]
    files = {}
    for k, (name, kind, rate, coding, channels, layout, container) in enumerate(fixtures):
        source = (noise if kind in ('opus', 'flac', 'alac') else tone).format(rate=rate, seed=k + 1)
        layout_args = ['-af', f'aformat=channel_layouts={layout}'] if layout else ['-ac', str(channels)]
        variants = [(f'{name}.{container}', [])]
        if kind in ('alac', 'opus', 'flac', 'pcm') and container != 'mov':
            variants.append((f'{name}-frag.{container}', ['-movflags', 'frag_keyframe+empty_moov']))
            variants.append((f'{name}-dash.{container}', ['-movflags', 'frag_keyframe+empty_moov+default_base_moof',
                                                          '-frag_duration', '200000']))
        for filename, flags in variants:
            path = work / filename
            ffmpeg('-f', 'lavfi', '-i', source, *layout_args, '-ar', str(rate), *coding, *flags, path)
            ours = Path(str(path) + '.f32')
            stats = decode_f32(path, ours)
            depth = {'alac-16': 16, 'alac-mono': 16, 'alac-small-frames': 16, 'alac-24-96k': 24, 'alac-5.1': 24,
                     'flac': 16, 'flac-24': 24}.get(name)
            if depth and f' bits={depth} ' not in stats.splitlines()[-1]:
                raise Failure(f'{filename}: expected {depth}-bit source, got {stats.splitlines()[-1]}')
            if channels <= 2:
                reference = Path(str(path) + '.ffmpeg.f32')
                decoder = {'mp2': ['-c:a', 'mp2float'], 'mp3': ['-c:a', 'mp3float']}.get(kind, [])
                upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
                ffmpeg(*decoder, '-i', path, *upmix, '-f', 'f32le', reference)
                if kind in ('mp3', 'mp2', 'opus'):
                    # FFmpeg's decode keeps the whole final frame; LAMP ends where the
                    # edit or the sample durations end: FFmpeg's demuxer duration, which
                    # without an edit list still includes Opus pre-skip.
                    presented = int(run(['ffprobe', '-v', 'error', '-select_streams', 'a', '-show_entries',
                                         'stream=duration_ts', '-of', 'csv=p=0', path]).strip())
                    data = path.read_bytes()
                    if kind == 'opus' and find(data, 'moov/trak/edts') is None:
                        presented -= struct.unpack_from('>H', data, data.index(b'dOps') + 6)[0]
                    pcm = reference.read_bytes()
                    if len(pcm) < presented * 8:
                        raise Failure(f'{filename}: FFmpeg decoded fewer frames than the edit presents')
                    reference.write_bytes(pcm[:presented * 8])
                peak, snr, frames, expected = measure(ours, reference)
                if frames != expected:
                    raise Failure(f'{filename}: {frames // 2} frames, FFmpeg {expected // 2}')
                limit, min_snr = TOLERANCE.get(kind, (0.0, math.inf))
                if peak > limit or snr < min_snr:
                    raise Failure(f'{filename}: peak error {peak:.3g}, SNR {snr:.1f} dB against FFmpeg')
                comparator = 'FFmpeg'
            else:
                comparator = 'multichannel: LAMP decode of the same stream below'
                peak, snr = None, None
            if flags:
                base = Path(str(work / f'{name}.{container}') + '.f32').read_bytes()
                if ours.read_bytes() != base:
                    raise Failure(f'{filename}: fragmented file decodes differently from {name}.{container}')
                comparator += ', progressive version'
            files[filename] = (path, kind, ours)
            checks.append({'test': filename, 'result': 'matched', 'comparator': comparator, 'peak_error': peak,
                           'snr_db': None if snr is None or math.isinf(snr) else round(snr, 1),
                           'stats': stats.splitlines()[-1]})
            print(f'{filename}: matched {comparator}', flush=True)
        main_file = work / f'{name}.{container}'
        # The same stream in other containers decodes identically.
        if kind in ('opus', 'flac', 'alac'):
            other = work / f'{name}.{"opus" if kind == "opus" else "flac" if kind == "flac" else "mka"}'
            ffmpeg('-i', main_file, '-c', 'copy', other)
            other_pcm = Path(str(other) + '.f32')
            decode_f32(other, other_pcm)
            a = Path(str(main_file) + '.f32').read_bytes()
            b = other_pcm.read_bytes()
            if (b[:len(a)] != a) if kind == 'opus' else (a != b):
                raise Failure(f'{name}: {main_file.suffix} and {other.suffix} decodes differ')
            checks.append({'test': f'{name} {main_file.suffix} vs {other.suffix}', 'result': 'exact'})

    # Seeks.
    for name in ('alac-16.m4a', 'alac-5.1.m4a', 'alac-small-frames-dash.m4a', 'flac.mp4', 'mp3.mp4', 'mp2.mp4',
                 'pcm-s24be.mov', 'pcm-s16le.mov'):
        path, kind, ours = files[name]
        line = run([seek, path, ours, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)
    opus_mp4, opus_ogg = work / 'opus.mp4', work / 'opus.opus'
    frames = len(Path(str(opus_mp4) + '.f32').read_bytes()) // 8
    for target in (1, 4000, frames // 3, frames // 2 + 77, frames - 500):
        a, b = work / 'dump-mp4.f32', work / 'dump-ogg.f32'
        run([chain, 'dump', opus_mp4, str(target), '2000', a])
        run([chain, 'dump', opus_ogg, str(target), '2000', b])
        if not a.read_bytes() or b.read_bytes()[:len(a.read_bytes())] != a.read_bytes():
            raise Failure(f'MP4 Opus seek to {target} differs from Ogg')
    checks.append({'test': 'opus.mp4 seeks equal Ogg Opus seeks', 'result': 'exact', 'targets': 5})

    # Malformed files.
    good = (work / 'alac-16.m4a').read_bytes()
    rejected = 0

    def reject(label, data):
        nonlocal rejected
        target = work / f'bad-{label}.m4a'
        target.write_bytes(data)
        line = run([chain, 'reject', target]).strip().splitlines()[-1]
        rejected += 1
        checks.append({'test': target.name, 'result': 'rejected', 'oracle': line})

    def patched(path, offset, value, fmt='>I'):
        data = bytearray(good)
        location = find(good, path)
        struct.pack_into(fmt, data, location[0] + offset, value)
        return bytes(data)
    reject('truncated', good[:len(good) - 2000])
    moov = find(good, 'moov')
    reject('no-moov', good.replace(b'moov', b'moox', 1))
    reject('sample-count', patched('moov/trak/mdia/minf/stbl/stsz', 8, 99999))
    reject('chunk-offset', patched('moov/trak/mdia/minf/stbl/stco', 8, len(good) + 10))
    reject('box-size', patched('moov', -8, len(good) * 2))
    reject('stsc-empty', patched('moov/trak/mdia/minf/stbl/stsc', 4, 0))
    reject('description-index', patched('moov/trak/mdia/minf/stbl/stsc', 16, 2))
    data = bytearray(good)
    stsd = find(good, 'moov/trak/mdia/minf/stbl/stsd')
    struct.pack_into('>4s', data, stsd[0] + 12, b'mp4a')                # no esds: unsupported
    reject('unsupported-entry', bytes(data))
    alac = find(good, 'moov/trak/mdia/minf/stbl/stsd')
    data = bytearray(good)
    position = good.index(b'alac', alac[0] + 16 + 4) + 4 + 4 + 5         # ALAC bit depth
    data[position] = 12
    reject('alac-depth', bytes(data))
    data = bytearray(good)
    mdat = find(good, 'mdat')
    data[mdat[0]] = 0x40                                               # a coupling-channel element
    reject('alac-frame', bytes(data))
    print(f'Rejected {rejected} malformed files', flush=True)
    for mode in ('cancel-open', 'cancel-read'):
        line = run([chain, mode, work / 'alac-16.m4a']).strip().splitlines()[-1]
        checks.append({'test': f'{mode} alac-16.m4a', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'ALAC playback', 'result': 'played', 'stats': play(work / 'alac-16.m4a')})
    write_report('mp4', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': 'MP4/M4A/MOV audio tracks: ALAC 16/24-bit, mono to 5.1, MPEG Layer II/III, Opus, FLAC and QuickTime PCM entries against FFmpeg and LAMP decodes of the same streams in Ogg, native FLAC and Matroska; fragmented (moof/trun) files equal their progressive versions; exact seeks and Opus seeks equal to Ogg; malformed tables, entries and frames; cancellation.'})
    print(f'Passed {len(checks)} MP4 checks.')


if __name__ == '__main__':
    main_guard(main)
