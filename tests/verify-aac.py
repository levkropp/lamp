#!/usr/bin/env python3
"""AAC-LC in MP4/M4A, ADTS and Matroska against FFmpeg's float decoder.

usage: python3 tests/verify-aac.py [--skip-playback]
- FFmpeg's encoder writes M4A fixtures at every supported rate, mono to 7.1,
  with its coder, M/S, intensity, PNS and TNS options varied. Mono and stereo
  output must match FFmpeg's decode of the same file over the presented
  range; multichannel output must match FFmpeg's per-channel decode mixed
  with LAMP's documented speaker weights. aac_features proves which coding
  tools the fixtures used.
- The same streams as ADTS, Matroska and fragmented MP4 must equal the M4A
  decode exactly, offset by the edit list's 1024 priming samples.
- Random valid raw data blocks (tests/aac_vectors.py) add pulse data, every
  TNS parameter, escape values to 8191 and window groupings.
- ISO noise correlation in channel pairs, which FFmpeg 6.1 omits, must give
  identical channels.
- Seeks without PNS equal continuous decoding; malformed and unsupported
  streams reject; cancelled open/read stop cleanly; one file plays.
Writes <out>/aac-verification.json.
"""
import array
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aac_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)

FEATURES = {1: 'short windows', 2: 'start/stop windows', 4: 'KBD windows', 8: 'mid/side', 16: 'intensity',
            32: 'noise substitution', 64: 'TNS', 128: 'pulses', 256: 'escape values', 512: 'window groups',
            1024: 'skipped elements'}
# LAMP's stereo weights per WAVE speaker bit (decoder.s pcm_speaker_weights).
R2, S3, C6 = 0.7071067811865475244, 0.8660254037844386468, 0.6123724356957945245
WEIGHTS = {0: (1.0, 0.0), 1: (0.0, 1.0), 2: (R2, R2), 3: (R2, R2), 4: (S3, 0.5), 5: (0.5, S3), 6: (R2, 0.0),
           7: (0.0, R2), 8: (C6, C6), 9: (S3, 0.5), 10: (0.5, S3)}
# FFmpeg's decoded channel order -> the WAVE speaker LAMP assigns to the same
# element channel. Configuration 7 is 7.1 front-wide in ISO/IEC 14496-3 (C,
# Lc/Rc, L/R, Ls/Rs, LFE); FFmpeg 6.1 labels its pairs FL/FR, SL/SR, BL/BR.
LAYOUTS = {'3.0': [0, 1, 2], '4.0': [0, 1, 2, 8], '5.0': [0, 1, 2, 4, 5], '5.1': [0, 1, 2, 3, 4, 5],
           '7.1': [6, 7, 2, 3, 4, 5, 0, 1]}
PEAK, SNR = 1e-6, 120.0


def floats(path):
    return array.array('f', Path(path).read_bytes())


def compare(ours, reference, frames=None):
    a, b = floats(ours), floats(reference)
    if frames is not None:
        if len(b) < frames * 2:
            raise Failure(f'{Path(reference).name}: reference shorter than {frames} frames')
        b = b[:frames * 2]
    if len(a) != len(b):
        raise Failure(f'{Path(ours).name}: {len(a) // 2} frames, reference {len(b) // 2}')
    peak = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b)
    snr = math.inf if error == 0 else 10 * math.log10(signal / error)
    return peak, snr


def mixed_reference(path, reference):
    """FFmpeg's native multichannel decode, mixed with LAMP's weights."""
    layout = run(['ffprobe', '-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=channel_layout',
                  '-of', 'csv=p=0', path]).strip()
    bits = LAYOUTS[layout]
    native = Path(str(reference) + '.native')
    ffmpeg('-i', path, '-f', 'f32le', native)
    data = floats(native)
    left_sum = sum(WEIGHTS[b][0] for b in bits)
    right_sum = sum(WEIGHTS[b][1] for b in bits)
    scale = (1.0 if len(bits) <= 4 else 2.0) / max(left_sum, right_sum)
    out = array.array('f')
    count = len(bits)
    for i in range(0, len(data), count):
        frame = data[i:i + count]
        out.append(sum(WEIGHTS[b][0] * scale * x for b, x in zip(bits, frame)))
        out.append(sum(WEIGHTS[b][1] * scale * x for b, x in zip(bits, frame)))
    Path(reference).write_bytes(out.tobytes())
    return layout


def features(oracle, path):
    line = json.loads(run([oracle, path]).strip().splitlines()[-1])
    if line['result'] != 'decoded':
        raise Failure(f'{Path(path).name}: {line}')
    return line['features']


def audio_specific_config(data):
    """Offset of the AudioSpecificConfig inside the first esds box."""
    position = data.index(b'esds') + 8                           # after the FullBox header

    def descriptor(position, tag):
        if data[position] != tag:
            raise Failure(f'esds: expected descriptor tag {tag}')
        position += 1
        for _ in range(4):
            more = data[position] & 0x80
            position += 1
            if not more:
                break
        return position
    position = descriptor(position, 3) + 3                       # ES_ID and flags
    position = descriptor(position, 4) + 13                      # decoder configuration
    return descriptor(position, 5)


def names(mask):
    return [name for bit, name in FEATURES.items() if mask & bit]


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c',
                              'aac-oracle': 'aac-oracle.c'}, library)
    seek, chain, oracle = exe('seek-oracle'), exe('chain-oracle'), exe('aac-oracle')
    work = scratch('aac')
    checks = []
    tone = 'aevalsrc=0.3*sin(2*PI*997*t)+0.05*sin(2*PI*5100*t)|0.2*sin(2*PI*431*t)+0.1*sin(2*PI*7000*t):s={rate}:d=1.5'
    noise = 'anoisesrc=r={rate}:d=1.5:a=0.3:seed={seed}'
    clicks = ("aevalsrc='if(lt(mod(t,0.25),0.004),0.7,0)*sin(2*PI*3000*t)+0.05*sin(2*PI*300*t)|"
              "0.4*sin(2*PI*220*t)*if(lt(mod(t,0.3),0.01),1,0.05)':s={rate}:d=1.5")
    fixtures = [
        ('tone', tone, 44100, 2, ['-b:a', '128k']),
        ('noise', noise, 44100, 2, ['-b:a', '128k']),
        ('noise-48k-low', noise, 48000, 2, ['-b:a', '48k']),
        ('noise-320k', noise, 48000, 2, ['-b:a', '320k']),
        ('transients', clicks, 48000, 2, ['-b:a', '96k']),
        ('mono', noise, 22050, 1, ['-b:a', '64k']),
        ('fast-coder', noise, 44100, 2, ['-b:a', '128k', '-aac_coder', 'fast']),
        ('no-ms-is', noise, 44100, 2, ['-b:a', '96k', '-aac_ms', '0', '-aac_is', '0']),
        ('plain', noise, 44100, 2, ['-b:a', '128k', '-aac_pns', '0', '-aac_tns', '0', '-aac_is', '0']),
        ('tone-no-pns', tone, 48000, 2, ['-b:a', '160k', '-aac_pns', '0']),
        ('noise-no-pns', noise, 44100, 2, ['-b:a', '128k', '-aac_pns', '0']),
    ]
    for rate in (8000, 11025, 12000, 16000, 22050, 24000, 32000, 64000, 88200, 96000):
        fixtures.append((f'rate-{rate}', noise if rate % 2 else tone, rate, 2, ['-b:a', '96k']))
    for layout in ('3.0', '4.0', '5.0', '5.1', '7.1'):
        fixtures.append((f'layout-{layout}', noise, 48000, layout, ['-b:a', '320k']))
    used = 0
    for k, (name, source, rate, channels, coding) in enumerate(fixtures):
        path = work / f'{name}.m4a'
        layout = ['-af', f'aformat=channel_layouts={channels}'] if isinstance(channels, str) else ['-ac', str(channels)]
        ffmpeg('-f', 'lavfi', '-i', source.format(rate=rate, seed=k + 1), *layout, '-ar', str(rate), '-c:a', 'aac',
               *coding, path)
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        reference = Path(str(path) + '.ffmpeg.f32')
        presented = int(run(['ffprobe', '-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=duration_ts',
                             '-of', 'csv=p=0', path]).strip())
        if isinstance(channels, str):
            comparator = 'FFmpeg channels mixed with LAMP weights (' + mixed_reference(path, reference) + ')'
        else:
            upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
            ffmpeg('-i', path, *upmix, '-f', 'f32le', reference)
            comparator = 'FFmpeg'
        # FFmpeg decodes the final packet whole; LAMP ends with the edit list.
        peak, snr = compare(ours, reference, presented)
        if peak > PEAK or snr < SNR:
            raise Failure(f'{name}: peak error {peak:.3g}, SNR {snr:.1f} dB against {comparator}')
        mask = features(oracle, path)
        used |= mask
        checks.append({'test': path.name, 'result': 'matched', 'comparator': comparator, 'peak_error': peak,
                       'snr_db': None if math.isinf(snr) else round(snr, 1), 'tools': names(mask),
                       'stats': stats.splitlines()[-1]})
        print(f'{path.name}: matched {comparator}, peak {peak:.2g}, {snr:.1f} dB, {", ".join(names(mask))}', flush=True)
        # The same stream in ADTS, Matroska and fragmented MP4.
        if name in ('noise', 'transients', 'mono', 'layout-5.1', 'rate-8000', 'rate-96000'):
            m4a = ours.read_bytes()
            for suffix, flags in (('aac', []), ('mka', []), ('frag.m4a', ['-movflags', 'frag_keyframe+empty_moov'])):
                other = work / f'{name}.{suffix}'
                ffmpeg('-i', path, '-c', 'copy', *flags, other)
                other_pcm = Path(str(other) + '.f32')
                decode_f32(other, other_pcm)
                data = other_pcm.read_bytes()
                # ADTS and Matroska keep the 1024 priming samples; fragments have no edit list.
                if data[1024 * 8:1024 * 8 + len(m4a)] != m4a:
                    raise Failure(f'{other.name}: differs from {path.name} after the priming samples')
                if suffix == 'aac':
                    adts_reference = Path(str(other) + '.ffmpeg.f32')
                    upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
                    if isinstance(channels, str):
                        mixed_reference(other, adts_reference)
                    else:
                        ffmpeg('-i', other, *upmix, '-f', 'f32le', adts_reference)
                    peak, snr = compare(other_pcm, adts_reference)
                    if peak > PEAK or snr < SNR:
                        raise Failure(f'{other.name}: peak error {peak:.3g}, SNR {snr:.1f} dB against FFmpeg')
                checks.append({'test': other.name, 'result': 'exact', 'comparator': f'{path.name} after priming'})
            print(f'{name}: ADTS, Matroska and fragmented MP4 exact', flush=True)
    missing = [FEATURES[bit] for bit in FEATURES if bit != 128 and not used & bit]
    if missing:
        raise Failure(f'FFmpeg fixtures did not use: {missing}')

    # Random valid streams.
    random_used, random_count = 0, 48
    worst = math.inf
    for seed in range(random_count):
        data, rate, channels = vectors.stream(seed)
        path = work / f'random-{seed}.aac'
        path.write_bytes(data)
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        reference = Path(str(path) + '.ffmpeg.f32')
        upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
        ffmpeg('-i', path, *upmix, '-f', 'f32le', reference)
        peak, snr = compare(ours, reference)
        amplitude = max(abs(x) for x in floats(reference)) or 1.0
        if peak / amplitude > PEAK or snr < SNR:
            raise Failure(f'{path.name}: relative peak error {peak / amplitude:.3g}, SNR {snr:.1f} dB against FFmpeg')
        worst = min(worst, snr)
        random_used |= features(oracle, path)
    if random_used != (1 << len(FEATURES)) - 1:
        raise Failure(f'random streams did not use: {[n for b, n in FEATURES.items() if not random_used & b]}')
    checks.append({'test': f'{random_count} random streams', 'result': 'matched', 'comparator': 'FFmpeg',
                   'minimum_snr_db': round(worst, 1), 'tools': names(random_used)})
    print(f'{random_count} random streams: matched FFmpeg, at least {worst:.1f} dB, all tools', flush=True)

    # ISO noise correlation: identical channels where FFmpeg differs.
    path = work / 'correlated-noise.aac'
    path.write_bytes(vectors.correlated_noise_stream())
    ours = Path(str(path) + '.f32')
    decode_f32(path, ours)
    pcm = floats(ours)
    if any(pcm[i] != pcm[i + 1] for i in range(0, len(pcm), 2)) or not any(pcm):
        raise Failure('correlated noise bands differ between channels')
    checks.append({'test': path.name, 'result': 'identical channels',
                   'note': 'FFmpeg 6.1 draws independent noise for these bands'})

    # Seeks: exact without PNS (noise substitution draws a running generator).
    for name in ('tone-no-pns.m4a', 'noise-no-pns.m4a', 'plain.m4a', 'noise-no-pns.aac'):
        path = work / name
        if not path.exists():
            ffmpeg('-i', work / 'noise-no-pns.m4a', '-c', 'copy', path)
        ours = Path(str(path) + '.f32')
        if not ours.exists():
            decode_f32(path, ours)
        line = run([seek, path, ours, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Malformed and unsupported streams.
    rejected = 0
    for name, (data, code) in vectors.malformed().items():
        path = work / f'bad-{name}.aac'
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != code:
            raise Failure(f'{path.name}: expected decode_error {code}, got {line}')
        rejected += 1
        checks.append({'test': path.name, 'result': 'rejected', 'oracle': line})
    good = (work / 'noise.m4a').read_bytes()
    config = audio_specific_config(good)
    for name, first in (('ltp-object', 0x20), ('object-escape', 0xf8)):
        data = bytearray(good)
        data[config] = first | (data[config] & 7)
        path = work / f'bad-{name}.m4a'
        path.write_bytes(bytes(data))
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 101:
            raise Failure(f'{path.name}: expected decode_error 101, got {line}')
        rejected += 1
        checks.append({'test': path.name, 'result': 'rejected', 'oracle': line})
    print(f'Rejected {rejected} malformed or unsupported streams', flush=True)

    for mode in ('cancel-open', 'cancel-read'):
        line = run([chain, mode, work / 'noise.m4a']).strip().splitlines()[-1]
        checks.append({'test': f'{mode} noise.m4a', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'AAC playback', 'result': 'played', 'stats': play(work / 'noise.m4a')})
    write_report('aac', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': 'AAC-LC in MP4/M4A, ADTS and Matroska: FFmpeg-encoded fixtures at all twelve '
                                  'rates, mono to 7.1, against FFmpeg (multichannel via LAMP mix weights); '
                                  'cross-container exactness; random valid streams with every coding tool; ISO '
                                  'noise correlation; exact seeks without PNS; malformed and unsupported streams; '
                                  'cancellation.'})
    print(f'Passed {len(checks)} AAC checks.')


if __name__ == '__main__':
    main_guard(main)
