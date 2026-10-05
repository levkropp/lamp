#!/usr/bin/env python3
"""MPEG audio Layer I/II decoding against FFmpeg's float decoders.

usage: python3 tests/verify-mp2.py [--skip-playback]
Random valid Layer I/II streams (tests/mpa12_vectors.py) cover every
allocation table, quantizer, scalefactor selection pattern, joint stereo
bound, MPEG-1 and MPEG-2 lower sampling frequencies, and CRC protection.
Encoder files from FFmpeg's mp2 encoder and libtwolame cover real bit
allocation. Exact indexed seeks, malformed frames and playback follow.
Writes <out>/mp2-verification.json.
"""
import array
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mpa12_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, check_file, decode_f32, exe, ffmpeg, lamp_cli, main_guard,
                       out_dir, play, playback_requested, run, scratch, write_report)

MIN_SNR = 105.0
MAX_RELATIVE = 0.00002


def measure(ours, reference):
    a = array.array('f', Path(ours).read_bytes())
    b = array.array('f', Path(reference).read_bytes())
    if len(a) != len(b):
        raise Failure(f'Frame count {len(a) // 2}, FFmpeg {len(b) // 2}: {Path(ours).name}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b)
    peak = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    reference_peak = max((abs(y) for y in b), default=0.0)
    snr = math.inf if error == 0 else 10 * math.log10(signal / error) if signal else -math.inf
    return snr, peak / reference_peak if reference_peak else peak


def frames_of(data):
    """Splits a Layer I/II stream into frames using header sizes."""
    out, i = [], 0
    while i + 4 <= len(data):
        h = int.from_bytes(data[i:i + 4], 'big')
        layer = 4 - ((h >> 17) & 3)
        version = 1 if (h >> 19) & 1 else 2
        kbps = vectors.BITRATES[(version, layer)][(h >> 12) & 15]
        rate = vectors.RATES[version][(h >> 10) & 3]
        padding = (h >> 9) & 1
        size = (12000 * kbps // rate + padding) * 4 if layer == 1 else 144000 * kbps // rate + padding
        out.append(data[i:i + size])
        i += size
    return out


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c'}, library)
    seek = exe('seek-oracle')
    work = scratch('mp2')
    checks = []

    def compare(path, layer, mono, label):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        reference = Path(str(path) + '.ffmpeg.f32')
        upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if mono else ['-ac', '2']
        ffmpeg('-c:a', 'mp1float' if layer == 1 else 'mp2float', '-i', path, *upmix, '-f', 'f32le', reference)
        snr, relative = measure(ours, reference)
        if snr < MIN_SNR or relative > MAX_RELATIVE:
            raise Failure(f'{label}: SNR {snr:.1f} dB, relative peak error {relative:.3g}')
        checks.append({'test': label, 'result': 'matched', 'snr_db': None if math.isinf(snr) else round(snr, 1),
                       'relative_peak_error': relative, 'stats': stats.splitlines()[-1]})
        print(f'{label}: {snr:.1f} dB, relative peak {relative:.2g}', flush=True)

    # Random valid streams: both layers, MPEG-1 and MPEG-2 rates, all modes.
    modes = {0: 'stereo', 1: 'joint', 2: 'dual', 3: 'mono'}
    for layer in (1, 2):
        for version in (1, 2):
            for rate_index in range(3):
                for mode in range(4):
                    for density in (0.3, 1.0):
                        seed = layer * 1000 + version * 100 + rate_index * 10 + mode + int(density * 7)
                        name = f'random-l{layer}-v{version}-r{rate_index}-{modes[mode]}-d{density}.mp{layer}'
                        path = work / name
                        path.write_bytes(vectors.stream(seed, layer, version, rate_index, mode, frames=16,
                                                        density=density))
                        compare(path, layer, mode == 3, name)

    # Encoder files with real bit allocation.
    tone = 'aevalsrc=0.3*sin(2*PI*997*t)+0.1*sin(2*PI*7000*t)+0.02*sin(2*PI*15000*t)|0.2*sin(2*PI*431*t)+0.05*sin(2*PI*9100*t)'
    encoders = []
    for rate in (32000, 44100, 48000):
        for kbps in (64, 128, 192, 384):
            encoders.append((f'ffmpeg-{rate}-{kbps}-stereo.mp2', rate, ['-c:a', 'mp2', '-b:a', f'{kbps}k'], False))
        encoders.append((f'ffmpeg-{rate}-64-mono.mp2', rate, ['-c:a', 'mp2', '-b:a', '64k', '-ac', '1'], True))
    for rate in (16000, 22050, 24000):
        encoders.append((f'ffmpeg-{rate}-64-stereo.mp2', rate, ['-c:a', 'mp2', '-b:a', '64k'], False))
        encoders.append((f'twolame-{rate}-32-mono-crc.mp2', rate,
                         ['-c:a', 'libtwolame', '-b:a', '32k', '-ac', '1', '-error_protection', '1'], True))
    for mode in ('stereo', 'joint_stereo', 'dual_channel'):
        for kbps, rate in ((96, 32000), (160, 44100), (256, 48000)):
            encoders.append((f'twolame-{rate}-{kbps}-{mode}.mp2', rate,
                             ['-c:a', 'libtwolame', '-b:a', f'{kbps}k', '-mode', mode, '-error_protection', '1'], False))
    # Nearly identical channels make libtwolame code every frame as joint stereo.
    for kbps, rate in ((64, 48000), (112, 48000), (96, 44100), (96, 32000)):
        encoders.append((f'twolame-{rate}-{kbps}-correlated-joint.mp2', rate,
                         ['-c:a', 'libtwolame', '-b:a', f'{kbps}k', '-mode', 'joint_stereo'], False))
    for name, rate, coding, mono in encoders:
        path = work / name
        if 'correlated' in name:
            source = f'anoisesrc=r={rate}:d=1:a=0.3:seed={rate},asplit[a][b];[b]volume=0.9[c];[a][c]amerge=inputs=2'
            ffmpeg('-f', 'lavfi', '-i', source, *coding, path)
        else:
            ffmpeg('-f', 'lavfi', '-i', f'{tone}:s={rate}:d=1.2', *coding, path)
        # FFmpeg's demuxer skips leading frames until two consecutive headers
        # agree in mode; drop those so both decoders see the same frames.
        frames = frames_of(path.read_bytes())
        mask = 0xfffe0ccf
        while len(frames) > 2 and (int.from_bytes(frames[0][:4], 'big') & mask) != (int.from_bytes(frames[1][:4], 'big') & mask):
            frames.pop(0)
        path.write_bytes(b''.join(frames))
        joint = sum(1 for f in frames if (f[3] >> 6) & 3 == 1)
        compare(path, 2, mono, name)
        checks[-1]['joint_stereo_frames'] = joint

    # Exact indexed seeks against continuous decoding.
    for name, data in (('seek-layer1.mp1', vectors.stream(77, 1, 1, 1, 1, frames=120)),
                       ('seek-layer2.mp2', vectors.stream(78, 2, 1, 0, 0, frames=60)),
                       ('seek-layer2-lsf.mp2', vectors.stream(79, 2, 2, 2, 3, frames=60))):
        path = work / name
        path.write_bytes(data)
        reference = Path(str(path) + '.f32')
        decode_f32(path, reference)
        line = run([seek, path, reference, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name}: {line}', flush=True)

    # Malformed frames must reject.
    good = vectors.stream(80, 2, 1, 1, 0, frames=8, crc=1)
    frames = frames_of(good)
    rejected = 0

    def reject(name, data):
        nonlocal rejected
        path = work / name
        path.write_bytes(data)
        code, stats = check_file(path)
        if code != 2:
            raise Failure(f'Malformed Layer I/II accepted: {name} {stats}')
        rejected += 1
        checks.append({'test': name, 'result': 'rejected', 'stats': stats})
    crc_bad = bytearray(frames[3])
    crc_bad[6] ^= 0x10                                   # inside the protected allocation
    reject('bad-crc.mp2', b''.join(frames[:3]) + bytes(crc_bad) + b''.join(frames[4:]))
    layer1 = vectors.stream(81, 1, 1, 1, 0, frames=2)
    reject('layer-change.mp2', b''.join(frames[:4]) + layer1)
    reject('truncated.mp2', good[:-40])
    header = bytearray(frames[0])
    header[1] &= 0xe7                                    # MPEG 2.5 with Layer II
    reject('mpeg25-layer2.mp2', bytes(header) + b''.join(frames[1:]))
    header = bytearray(frames[0])
    header[2] |= 0xf0                                    # bitrate index 15
    reject('bad-bitrate.mp2', bytes(header) + b''.join(frames[1:]))
    header = bytearray(frames[0])
    header[2] &= 0x0f                                    # free format
    reject('free-format.mp2', bytes(header) + b''.join(frames[1:]))
    header = bytearray(frames[0])
    header[2] |= 0x0c                                    # reserved sample rate
    reject('bad-rate.mp2', bytes(header) + b''.join(frames[1:]))
    print(f'Rejected {rejected} malformed streams', flush=True)

    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'Layer II playback', 'result': 'played', 'stats': play(work / 'ffmpeg-48000-192-stereo.mp2')})
    write_report('mp2', {'result': 'passed', 'checks': checks, 'minimum_snr_db': MIN_SNR,
                         'maximum_relative_peak_error': MAX_RELATIVE,
                         'scope': 'MPEG audio Layer I/II: random valid streams for every allocation table, quantizer, scalefactor pattern, stereo mode/bound, MPEG-1 and MPEG-2 rates and CRC; FFmpeg mp2 and libtwolame encoder files; comparisons with FFmpeg mp1float/mp2float; exact seeks; malformed frames.'})
    print(f'Passed {len(checks)} Layer I/II checks.')


if __name__ == '__main__':
    main_guard(main)
