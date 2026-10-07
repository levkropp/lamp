#!/usr/bin/env python3
"""AC-3 in raw .ac3, Matroska and MP4 against FFmpeg's float decoder.

usage: python3 tests/verify-ac3.py [--skip-playback]
- FFmpeg's encoder writes raw AC-3 fixtures at all three rates, mono to 5.1,
  32-640 kb/s, with coupling, rematrixing and the alternate bit stream syntax
  varied. Mono and stereo output must match FFmpeg's decode; multichannel
  output must match FFmpeg's channels mixed with LAMP's speaker weights. The
  Python model (tests/ac3_model.py) first reproduces FFmpeg on two of them.
- FFmpeg's encoder uses neither short blocks, delta bit allocation, dynamic
  range words, skip fields, dual mono, phase flags nor the half- and
  quarter-rate bit stream ids, so streams written by tests/ac3_vectors.py
  through the model's own bit allocation cover them; the model's coverage set
  proves every tool and bap was used.
- Matroska, MP4 and fragmented MP4 copies equal the raw decode; an MP4 encoded
  directly (with its 256-sample priming edit) matches FFmpeg; ID3 tags are
  skipped and a truncated final frame is dropped.
- Frames with CRC errors, and frames whose valid CRC covers corrupted data,
  match FFmpeg's concealment; heavily corrupted streams decode cleanly.
- Seeks in dither-free streams equal continuous decoding; dependent E-AC-3 and broken
  streams reject; cancelled open/read stop cleanly; one file plays.
Writes <out>/ac3-verification.json.
"""
import array
import json
import math
import importlib.util
import struct
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ac3_model as model
import ac3_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)

# LAMP's stereo weights per WAVE speaker bit (decoder.s pcm_speaker_weights).
R2, S3, C6 = 0.7071067811865475244, 0.8660254037844386468, 0.6123724356957945245
WEIGHTS = {0: (1.0, 0.0), 1: (0.0, 1.0), 2: (R2, R2), 3: (R2, R2), 4: (S3, 0.5), 5: (0.5, S3), 6: (R2, 0.0),
           7: (0.0, R2), 8: (C6, C6), 9: (S3, 0.5), 10: (0.5, S3)}
# WAVE masks by acmod as src/ac3.s assigns them (LFE adds bit 3); FFmpeg
# orders its channels the same way.
MASKS = [3, 4, 3, 7, 0x103, 0x107, 0x603, 0x607]
# AC-3 channel (L C R SL SR, LFE last) -> FFmpeg output channel (WAVE order).
CHANNEL_MAP = {(0, 0): [0, 1], (0, 1): [0, 1, 2], (1, 0): [0], (1, 1): [0, 1], (2, 0): [0, 1], (2, 1): [0, 1, 2],
               (3, 0): [0, 2, 1], (3, 1): [0, 2, 1, 3], (4, 0): [0, 1, 2], (4, 1): [0, 1, 3, 2],
               (5, 0): [0, 2, 1, 3], (5, 1): [0, 2, 1, 4, 3], (6, 0): [0, 1, 2, 3], (6, 1): [0, 1, 3, 4, 2],
               (7, 0): [0, 2, 1, 3, 4], (7, 1): [0, 2, 1, 4, 5, 3]}
PEAK, SNR = 1e-6, 130.0
COVERAGE = {f'acmod {m}' for m in range(8)} | {f'bap {b}' for b in range(16)} | \
    {f'exponent strategy {s}' for s in range(4)} | {f'rematrixing {n} bands' for n in (2, 3, 4)} | \
    {'short blocks', 'mixed transforms', 'dither 0', 'dither 1', 'dynamic range', 'dynamic range dual mono',
     'coupling', 'coupling band structure', 'partial coupling', 'phase flags', 'bandwidth change',
     'delta bit allocation', 'delta bit allocation coupling', 'delta bit allocation reuse', 'snr offset -960',
     'skip field', 'alternate bit stream syntax', 'additional bit stream information', 'bsid 9', 'bsid 10'}


def floats(path):
    return array.array('f', Path(path).read_bytes())


def compare(ours, reference, frames=None):
    a, b = floats(ours), floats(reference)
    if frames is not None:
        b = b[:frames * 2]
    if len(a) != len(b):
        raise Failure(f'{Path(ours).name}: {len(a) // 2} frames, reference {len(b) // 2}')
    peak = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b)
    snr = math.inf if error == 0 else 10 * math.log10(signal / error)
    return peak, snr


def layout_of(path):
    data = Path(path).read_bytes()
    position = data.find(b'\x0b\x77')
    h = model.header(data[position:position + 8])
    lfe = (int.from_bytes(data[position + 6:position + 8], 'big') >> (12 - _extra(h['acmod']))) & 1
    return h['acmod'], lfe


def _extra(acmod):
    if acmod == 2:
        return 2
    return (2 if acmod & 1 and acmod != 1 else 0) + (2 if acmod & 4 else 0)


def reference(path, output, acmod, lfe, crc=False):
    """FFmpeg's decode as LAMP presents it: mono and stereo directly, other
    layouts mixed with LAMP's weights (normalized as pcm_build_mix does)."""
    native = Path(str(output) + '.native')
    ffmpeg('-cpuflags', '0', *(['-err_detect', 'crccheck'] if crc else []), '-i', path, '-f', 'f32le', native)
    data = floats(native)
    mask = MASKS[acmod] | (8 if lfe else 0)
    bits = [b for b in range(18) if mask >> b & 1]
    count = len(bits)
    out = array.array('f')
    if mask in (3, 4):
        for i in range(0, len(data), count):
            out.append(data[i])
            out.append(data[i + count - 1])
    else:
        left = sum(WEIGHTS[b][0] for b in bits)
        right = sum(WEIGHTS[b][1] for b in bits)
        scale = (1.0 if count <= 4 else 2.0) / max(left, right)
        for i in range(0, len(data), count):
            frame = data[i:i + count]
            out.append(sum(WEIGHTS[b][0] * scale * x for b, x in zip(bits, frame)))
            out.append(sum(WEIGHTS[b][1] * scale * x for b, x in zip(bits, frame)))
    Path(output).write_bytes(out.tobytes())


def against_ffmpeg(path, checks, crc=False, label=None, frames=None):
    acmod, lfe = layout_of(path)
    ours = Path(str(path) + '.f32')
    stats = decode_f32(path, ours)
    ref = Path(str(path) + '.ffmpeg.f32')
    reference(path, ref, acmod, lfe, crc)
    peak, snr = compare(ours, ref, frames)
    amplitude = max((abs(x) for x in floats(ref)), default=0.0) or 1.0
    if peak / max(amplitude, 1.0) > PEAK or snr < SNR:
        raise Failure(f'{Path(path).name}: peak error {peak:.3g}, {snr:.1f} dB against FFmpeg')
    name = label or Path(path).name
    checks.append({'test': name, 'result': 'matched', 'comparator': 'FFmpeg' if acmod in (1, 2) and not lfe or
                   acmod == 0 and not lfe else 'FFmpeg channels mixed with LAMP weights',
                   'acmod': acmod, 'lfe': lfe, 'peak_error': peak, 'snr_db': None if math.isinf(snr) else round(snr, 1),
                   'stats': stats.splitlines()[-1]})
    print(f'{name}: {snr:.1f} dB against FFmpeg', flush=True)
    return snr


def model_check(path, checks):
    """The model reproduces FFmpeg's channels."""
    data = Path(path).read_bytes()
    channels, decoder = model.decode(data)
    native = Path(str(path) + '.native')
    ffmpeg('-cpuflags', '0', '-i', path, '-f', 'f32le', native)
    ref = floats(native)
    positions = CHANNEL_MAP[(decoder.acmod, decoder.lfe)]
    worst = math.inf
    for ch, samples in enumerate(channels):
        theirs = ref[positions[ch]::len(channels)]
        error = sum((x - y) ** 2 for x, y in zip(samples, theirs))
        signal = sum(y * y for y in theirs) or 1.0
        worst = min(worst, math.inf if error == 0 else 10 * math.log10(signal / error))
    if worst < SNR:
        raise Failure(f'model on {Path(path).name}: {worst:.1f} dB against FFmpeg')
    checks.append({'test': f'model on {Path(path).name}', 'result': 'matched', 'comparator': 'FFmpeg channels',
                   'minimum_snr_db': round(worst, 1)})
    print(f'model on {Path(path).name}: {worst:.1f} dB against FFmpeg', flush=True)
    return decoder.used


def flips(seed, count, fix_crc):
    """A mutate hook: flips count bits after the bit stream information's
    first bytes in about 40% of the frames after the first; optionally
    recomputes the CRCs. (Written streams start with mixed transforms, which
    FFmpeg needs before any later mixed block; see tests/ac3_vectors.py.)"""
    r = random.Random(seed)

    def mutate(index, frame):
        if index == 0 or r.random() > 0.4:
            return None
        frame = bytearray(frame)
        for _ in range(count):
            bit = r.randrange(64, (len(frame) - 2) * 8)
            frame[bit >> 3] ^= 0x80 >> (bit & 7)
        return vectors.recrc(frame) if fix_crc else bytes(frame)
    return mutate


def mutate_file(data, hook):
    out = bytearray()
    for k, frame in enumerate(model.frames(data)):
        out += hook(k, frame) or frame
    return bytes(out)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('ac3')
    checks = []
    tone = 'aevalsrc=0.3*sin(2*PI*997*t)+0.05*sin(2*PI*5100*t)|0.2*sin(2*PI*431*t)+0.1*sin(2*PI*7000*t):s={rate}:d=1.5'
    noise = 'anoisesrc=r={rate}:d=1.5:a=0.3:seed={seed}'
    correlated = ("aevalsrc='0.4*sin(2*PI*523*t)+0.2*sin(2*PI*3100*t)+0.02*sin(2*PI*9000*t)|"
                  "0.4*sin(2*PI*523*t)+0.2*sin(2*PI*3100*t)-0.02*sin(2*PI*9000*t)':s={rate}:d=1.5")
    clicks = ("aevalsrc='if(lt(mod(t,0.25),0.004),0.7,0)*sin(2*PI*3000*t)+0.05*sin(2*PI*300*t)|"
              "0.4*sin(2*PI*220*t)*if(lt(mod(t,0.3),0.01),1,0.05)':s={rate}:d=1.5")
    fixtures = [
        ('mono-48k', noise, 48000, 'mono', ['-b:a', '96k']),
        ('stereo-48k', tone, 48000, 'stereo', ['-b:a', '192k']),
        ('stereo-44k', noise, 44100, 'stereo', ['-b:a', '128k']),
        ('stereo-32k', noise, 32000, 'stereo', ['-b:a', '64k']),
        ('rematrix', correlated, 48000, 'stereo', ['-b:a', '192k', '-stereo_rematrixing', '1']),
        ('no-coupling', noise, 48000, 'stereo', ['-b:a', '96k', '-channel_coupling', '0']),
        ('early-coupling', noise, 48000, 'stereo', ['-b:a', '96k', '-channel_coupling', '1', '-cpl_start_band', '1']),
        ('32k-bitrate', noise, 48000, 'stereo', ['-b:a', '32k']),
        ('640k-bitrate', tone, 48000, 'stereo', ['-b:a', '640k']),
        ('transients', clicks, 48000, 'stereo', ['-b:a', '192k']),
        ('alternate-syntax', noise, 48000, 'stereo', ['-b:a', '192k', '-dmix_mode', 'ltrt', '-ad_conv_type', 'hdcd',
                                                       '-dsurex_mode', 'on']),
        ('2.1', noise, 48000, '2.1', ['-b:a', '192k']),
        ('3.0', noise, 48000, '3.0', ['-b:a', '256k']),
        ('3.0-back', noise, 48000, '3.0(back)', ['-b:a', '256k']),
        ('4.0', noise, 48000, '4.0', ['-b:a', '320k']),
        ('quad-side', noise, 48000, 'quad(side)', ['-b:a', '320k']),
        ('5.0-side', noise, 48000, '5.0(side)', ['-b:a', '384k']),
        ('5.1-side', noise, 48000, '5.1(side)', ['-b:a', '448k', '-center_mixlev', '0.5', '-surround_mixlev', '0']),
        ('5.1-44k', noise, 44100, '5.1(side)', ['-b:a', '384k']),
        ('4.1-32k', noise, 32000, '4.1', ['-b:a', '320k']),
    ]
    for k, (name, source, rate, layout, coding) in enumerate(fixtures):
        path = work / f'{name}.ac3'
        ffmpeg('-f', 'lavfi', '-i', source.format(rate=rate, seed=k + 1), '-af', f'aformat=channel_layouts={layout}',
               '-ar', str(rate), '-c:a', 'ac3', *coding, path)
        against_ffmpeg(path, checks)
    used = model_check(work / 'rematrix.ac3', checks) | model_check(work / '5.1-side.ac3', checks)
    if 'rematrixing 4 bands' not in used:
        raise Failure('the rematrix fixture did not rematrix')

    # Containers and tags.
    for name in ('stereo-48k', '5.1-side', 'mono-48k'):
        raw = work / f'{name}.ac3'
        pcm = Path(str(raw) + '.f32').read_bytes()
        mp4 = work / f'{name}.mp4'
        ffmpeg('-i', raw, '-c', 'copy', mp4)
        for other, flags, source in ((work / f'{name}.mka', [], raw), (mp4, None, raw),
                                     (work / f'{name}.frag.mp4', ['-frag_duration', '100000', '-movflags', 'delay_moov'],
                                      mp4)):
            if flags is not None:
                ffmpeg('-i', source, '-c', 'copy', *flags, other)
            ours = Path(str(other) + '.f32')
            decode_f32(other, ours)
            if ours.read_bytes() != pcm:
                raise Failure(f'{other.name}: differs from {raw.name}')
            checks.append({'test': other.name, 'result': 'exact', 'comparator': raw.name})
        print(f'{name}: Matroska, MP4 and fragmented MP4 exact', flush=True)
    path = work / 'direct-44k.mp4'
    ffmpeg('-f', 'lavfi', '-i', noise.format(rate=44100, seed=99), '-ac', '2', '-c:a', 'ac3', '-b:a', '192k', path)
    edit = decode_f32(path, Path(str(path) + '.f32'))
    frames = int(edit.split(' frames=')[1].split()[0])
    # End padding varies by muxer version. Independently compute the bounded
    # edit from its movie/media clocks and packet-duration table.
    spec = importlib.util.spec_from_file_location('mp4_tests', Path(__file__).with_name('verify-mp4.py'))
    mp4_tests = importlib.util.module_from_spec(spec); spec.loader.exec_module(mp4_tests)
    data = path.read_bytes()
    mvhd, _ = mp4_tests.find(data, 'moov/mvhd')
    mdhd, _ = mp4_tests.find(data, 'moov/trak/mdia/mdhd')
    elst, _ = mp4_tests.find(data, 'moov/trak/edts/elst')
    stts, _ = mp4_tests.find(data, 'moov/trak/mdia/minf/stbl/stts')
    if data[mvhd] or data[mdhd] or data[elst] or struct.unpack_from('>I',data,elst+4)[0]!=1:
        raise Failure('expected single version-0 priming edit')
    movie_clock = struct.unpack_from('>I',data,mvhd+12)[0]
    media_clock = struct.unpack_from('>I',data,mdhd+12)[0]
    duration, begin = struct.unpack_from('>Ii',data,elst+8)
    runs = struct.unpack_from('>I',data,stts+4)[0]
    raw_frames = sum(n*d for n,d in (struct.unpack_from('>II',data,stts+8+i*8) for i in range(runs)))
    presented = min(raw_frames-begin, duration*media_clock//movie_clock)
    if begin != 256 or frames != presented:
        raise Failure(f'{path.name}: {frames} frames, bounded edit {presented}, priming {begin}')
    against_ffmpeg(path, checks, label='direct-44k.mp4 (priming edit)', frames=frames)
    plain = (work / 'stereo-48k.ac3').read_bytes()
    pcm = Path(str(work / 'stereo-48k.ac3') + '.f32').read_bytes()
    frame_list = model.frames(plain)
    tagged = work / 'tagged.ac3'
    tagged.write_bytes(b'ID3\x04\x00\x00\x00\x00\x00\x0a' + bytes(10) + plain + b'TAG' + bytes(125))
    truncated = work / 'truncated.ac3'
    truncated.write_bytes(plain[:len(plain) - len(frame_list[-1]) // 2])
    for path, expected in ((tagged, pcm), (truncated, pcm[:(len(frame_list) - 1) * 1536 * 8])):
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        if ours.read_bytes() != expected:
            raise Failure(f'{path.name}: differs from the plain stream')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': 'stereo-48k.ac3'})
    print('ID3v2/ID3v1 tags skipped and a truncated final frame dropped', flush=True)

    # Written streams: every tool.
    grid = [(2, 0, 0, 8), (2, 1, 0, 8), (1, 0, 0, 8), (1, 1, 1, 8), (0, 0, 0, 8), (0, 1, 2, 8), (3, 0, 0, 8),
            (3, 1, 1, 6), (4, 0, 0, 4), (4, 1, 2, 8), (5, 0, 0, 8), (5, 1, 0, 8), (6, 0, 1, 8), (6, 1, 0, 8),
            (7, 0, 2, 8), (7, 1, 0, 8), (2, 0, 0, 9), (7, 1, 1, 9), (2, 0, 2, 10), (1, 0, 0, 10), (2, 0, 1, 6),
            (6, 1, 0, 0), (7, 1, 0, 6), (2, 1, 0, 8)]
    worst = math.inf
    for k, (acmod, lfe, fscod, bsid) in enumerate(grid):
        data, tags = vectors.stream(100 + k, 16, acmod, lfe, fscod, bsid, frmsizecod=(36, 37, 32, 28)[k % 4])
        used |= tags
        path = work / f'written-{k}.ac3'
        path.write_bytes(data)
        worst = min(worst, against_ffmpeg(path, checks))
    missing = COVERAGE - used
    if missing:
        raise Failure(f'streams did not use: {sorted(missing)}')
    checks.append({'test': 'coverage', 'result': 'complete', 'tools': sorted(used)})
    print(f'{len(grid)} written streams: at least {worst:.1f} dB, every tool and bap', flush=True)

    # Corrupted frames: CRC failures (FFmpeg checks with crccheck) and valid
    # CRCs over corrupted data both repeat earlier blocks.
    sources = [(work / f'written-{k}.ac3').read_bytes() for k in (1, 15, 4, 6)]
    for seed in range(12):
        data = mutate_file(sources[seed % 4], flips(500 + seed, 1 + seed % 3, fix_crc=seed >= 6))
        path = work / f'corrupt-{seed}.ac3'
        path.write_bytes(data)
        against_ffmpeg(path, checks, crc=seed < 6)
    clean = 0
    sources += [plain, (work / '5.1-side.ac3').read_bytes()]
    for seed in range(60):
        data = mutate_file(sources[seed % 6], flips(900 + seed, (2, 8, 32, 128)[seed % 4], fix_crc=seed % 2 == 0))
        path = work / 'fuzz.ac3'
        path.write_bytes(data)
        stats = decode_f32(path, Path(str(path) + '.f32'))
        if 'decode_error=0' not in stats:
            raise Failure(f'fuzz seed {seed}: {stats}')
        clean += 1
    checks.append({'test': f'{clean} heavily corrupted streams', 'result': 'decoded'})
    print(f'{clean} heavily corrupted streams decoded', flush=True)

    # Seeks: dither-free streams equal continuous decoding.
    for name, acmod, lfe in (('seek-stereo.ac3', 2, 0), ('seek-5.1.ac3', 7, 1), ('seek-mono.ac3', 1, 0)):
        data, _ = vectors.stream(700 + acmod, 60, acmod, lfe, dither=0.0)
        path = work / name
        path.write_bytes(data)
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        line = run([seek, path, ours, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)
    mka = work / 'seek-5.1.mka'
    ffmpeg('-i', work / 'seek-5.1.ac3', '-c', 'copy', mka)
    line = run([seek, mka, Path(str(work / 'seek-5.1.ac3') + '.f32'), '0']).strip().splitlines()[-1]
    checks.append({'test': 'seek-5.1.mka seeks', 'result': line})
    print(f'seek-5.1.mka seeks: {line}', flush=True)

    # Unsupported and malformed streams.
    rejected = 0
    # Independent E-AC-3 now has its own suite; dependent channel substreams
    # remain unsupported by the shared decoder.
    eac3 = work / 'eac3.ec3'
    ffmpeg('-f', 'lavfi', '-i', noise.format(rate=48000, seed=5), '-ac', '2', '-c:a', 'eac3', '-f', 'eac3', eac3)
    frames = []
    data = eac3.read_bytes()
    while data:
        size = 2 * (((data[2] & 7) << 8 | data[3]) + 1)
        b = bytearray(data[:size]); data = data[size:]
        b[2] = (b[2] & 63) | 64
        b[-2:] = model.crc16(b[2:-2]).to_bytes(2, 'big')
        frames.append(bytes(b))
    eac3.write_bytes(b''.join(frames))
    line = run([chain, 'reject', eac3]).strip().splitlines()[-1]
    if json.loads(line).get('decode_error') != 101:
        raise Failure(f'dependent E-AC-3: {line}')
    rejected += 1
    checks.append({'test': 'dependent E-AC-3', 'result': 'rejected', 'oracle': line})
    five = (work / '5.1-side.ac3').read_bytes()
    broken = {
        'layout-change': plain[:len(frame_list[0]) * 3] + five,
        'garbage': plain[:len(frame_list[0]) * 2] + bytes(range(256)) * 8,
        'bad-frame-size': plain[:len(frame_list[0])] + plain[len(frame_list[0]):len(frame_list[0]) + 4] +
        bytes([plain[len(frame_list[0]) + 4] | 0x3f]) + plain[len(frame_list[0]) + 5:],
    }
    for name, data in broken.items():
        path = work / f'bad-{name}.ac3'
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 100:
            raise Failure(f'{path.name}: expected decode_error 100, got {line}')
        rejected += 1
        checks.append({'test': path.name, 'result': 'rejected', 'oracle': line})
    print(f'Rejected {rejected} unsupported or malformed streams', flush=True)

    for mode in ('cancel-open', 'cancel-read'):
        line = run([chain, mode, work / '5.1-side.ac3']).strip().splitlines()[-1]
        checks.append({'test': f'{mode} 5.1-side.ac3', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'AC-3 playback', 'result': 'played', 'stats': play(work / '5.1-side.ac3')})
    write_report('ac3', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': 'AC-3 in raw .ac3, Matroska and MP4: FFmpeg-encoded fixtures at 32, 44.1 and '
                                  '48 kHz, mono to 5.1, against FFmpeg (multichannel via LAMP mix weights); the '
                                  'model against FFmpeg; written streams covering every tool and bap; container '
                                  'exactness, tags and truncation; corrupted frames against FFmpeg\'s concealment; '
                                  'fuzzing; exact seeks; dependent E-AC-3 and malformed rejections; cancellation.'})
    print(f'Passed {len(checks)} AC-3 checks.')


if __name__ == '__main__':
    main_guard(main)
