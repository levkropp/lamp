#!/usr/bin/env python3
"""HE-AAC spectral band replication against FFmpeg's float decoder.

usage: python3 tests/verify-heaac.py [--skip-playback]
- tests/sbr_vectors.py inserts SBR data drawn by tests/sbr_model.py after the
  channel elements of FFmpeg-encoded (bitexact) AAC-LC streams, so the core
  is a real encoder's while every SBR field is known. Mono, stereo, 3.0, 5.1
  and 7.1 (separate encodes combined element by element; LFE stays plain
  upsampled) at core rates 11.025-48 kHz must match FFmpeg's decode, and the
  model's own rendering must match FFmpeg too, so the streams carry what the
  writer intended. The generator's coverage set proves every frame class,
  coupling mode, delta direction, master table shape, limiter, smoothing,
  sinusoid and transient path ran.
- The same stream in MP4 with implicit, explicit (object type 5) and
  backward-compatible SBR signalling, in Matroska and fragmented MP4 must
  equal the ADTS decode exactly; sbrPresentFlag 0 must decode the core only,
  as FFmpeg does, and so must SBR first seen after the first frame.
- CRC-protected payloads, extended data, SBR before the first channel element
  and corrupted payloads (FFmpeg falls back to plain upsampling for each
  error) must match FFmpeg; more corrupted streams must decode or reject
  cleanly.
- Seeks into steady streams (headers in every frame, nothing a decoder cannot
  recover after a jump) must return the requested positions and match
  continuous decoding apart from the noise generator's phase.
- Parametric stereo (object type 29, PS data in a mono stream) and
  downsampled SBR reject as unsupported; one file plays.
Writes <out>/heaac-verification.json.
"""
import array
import importlib.util
import json
import math
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aac_vectors as vectors
import sbr_model as model
import sbr_vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)

_spec = importlib.util.spec_from_file_location('verify_aac', Path(__file__).resolve().parent / 'verify-aac.py')
aac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aac)

SNR, PEAK = 100.0, 1e-4             # FFmpeg's SBR runs in single precision
SEEK_SNR = 50.0
COVERAGE = {'FIXFIX', 'FIXVAR', 'VARFIX', 'VARVAR', 'coupled pair', 'independent pair', 'time-delta',
            'frequency-delta', '1.5 dB envelopes', '3 dB envelopes', 'linear master table',
            'one-region master table', 'two-region master table', '1 patches', '2 patches', '3 patches',
            'limiter bands', 'one limiter band', 'interpolated envelopes', 'band envelopes', 'smoothing',
            'no smoothing', 'sinusoids', 'transient envelope', 'header reset', 'extended data',
            'limiter table below kx + M'}


def floats(path):
    return array.array('f', Path(path).read_bytes())


def snr(ours, reference):
    a, b = floats(ours), floats(reference)
    if len(a) != len(b):
        raise Failure(f'{Path(ours).name}: {len(a) // 2} frames, reference {len(b) // 2}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b) or 1.0
    peak = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    amplitude = max((abs(y) for y in b), default=0.0) or 1.0
    return (math.inf if error == 0 else 10 * math.log10(signal / error)), peak / amplitude


class Fixtures:
    """FFmpeg-encoded single-element cores and the HE-AAC streams built on them."""

    def __init__(self, work):
        self.work = work

    def core(self, kind, rate, seed):
        path = self.work / f'core-{kind}-{rate}-{seed}.aac'
        if not path.exists():
            if kind == sbr_vectors.LFE:
                source, channels = f'sine=f=55:r={rate}:d=4.5', 1
            else:
                source = f'anoisesrc=r={rate}:d=4.5:a=0.3:seed={seed}'
                channels = 2 if kind == sbr_vectors.CPE else 1
            # Full band: random headers may cross over anywhere up to 32 subbands,
            # and limiter gains near 10^5 on an encoder's empty top bands would
            # leave only rounding noise to compare.
            ffmpeg('-f', 'lavfi', '-i', source, '-ac', str(channels), '-c:a', 'aac', '-b:a', str(4 * rate * channels),
                   '-cutoff', str(rate // 2), '-aac_pns', '0', '-flags', '+bitexact', path)
        return sbr_vectors.raw_blocks(path.read_bytes())

    def stream(self, name, config, rate, seed, frames=36, **options):
        cores = [self.core(kind, rate, seed + i) for i, kind in enumerate(sbr_vectors.LAYOUTS[config])]
        data, used = sbr_vectors.stream(cores, config, vectors.RATES.index(rate), seed, frames, **options)
        path = self.work / name
        path.write_bytes(data)
        return path, used


def reference(path, config):
    """FFmpeg's decode on its C code path: its x86 gain filter writes one
    subband past an odd M from uninitialized memory, which corrupted streams
    can read back. Multichannel output is mixed with LAMP's weights."""
    out = Path(str(path) + '.ffmpeg.f32')
    if config < 3:
        upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if config == 1 else []
        ffmpeg('-cpuflags', '0', '-i', path, *upmix, '-f', 'f32le', out)
        return out
    layout = run(['ffprobe', '-v', 'quiet', '-select_streams', 'a', '-show_entries', 'stream=channel_layout',
                  '-of', 'csv=p=0', path]).strip()
    bits = aac.LAYOUTS[layout]
    native = Path(str(out) + '.native')
    ffmpeg('-cpuflags', '0', '-i', path, '-f', 'f32le', native)
    data = floats(native)
    weights = aac.WEIGHTS
    scale = (1.0 if len(bits) <= 4 else 2.0) / max(sum(weights[b][0] for b in bits), sum(weights[b][1] for b in bits))
    mixed = array.array('f')
    for i in range(0, len(data), len(bits)):
        frame = data[i:i + len(bits)]
        mixed.append(sum(weights[b][0] * scale * x for b, x in zip(bits, frame)))
        mixed.append(sum(weights[b][1] * scale * x for b, x in zip(bits, frame)))
    out.write_bytes(mixed.tobytes())
    return out


def against_ffmpeg(path, config, checks, label=None, minimum=SNR):
    ours = Path(str(path) + '.f32')
    stats = decode_f32(path, ours)
    level, peak = snr(ours, reference(path, config))
    if level < minimum or peak > PEAK:
        raise Failure(f'{path.name}: {level:.1f} dB, relative peak error {peak:.2g} against FFmpeg')
    checks.append({'test': label or path.name, 'result': 'matched', 'comparator': 'FFmpeg',
                   'snr_db': None if math.isinf(level) else round(level, 1), 'stats': stats.splitlines()[-1]})
    print(f'{label or path.name}: {level:.1f} dB against FFmpeg', flush=True)
    return ours, level


def model_check(fixtures, work, checks):
    """The Python model renders one stream from LAMP's core PCM; FFmpeg must
    agree, so the writer's structured data is what the streams carry."""
    rate, frames = 24000, 10
    blocks = fixtures.core(sbr_vectors.SCE, rate, 3)[:frames]
    core = work / 'model-core.aac'
    core.write_bytes(b''.join(vectors.adts(b, vectors.RATES.index(rate), 1) for b in blocks))
    decode_f32(core, Path(str(core) + '.f32'))
    pcm = floats(Path(str(core) + '.f32'))
    r = random.Random(3)
    element = model.Element(2 * rate, 1)
    head = sbr_vectors.header(r, 2 * rate)
    stream, rendered = bytearray(), array.array('f')
    for f, block in enumerate(blocks):
        payload = vectors.Bits()
        element.write_payload(r, payload, head if f % 4 == 0 else None)
        bits = vectors.Bits()
        value, count = sbr_vectors.element(block)
        bits.put(value, count)
        fill = sbr_vectors.fill(payload)
        bits.put(fill.value, fill.count)
        bits.put(7, 3)
        stream += vectors.adts(bits.data(), vectors.RATES.index(rate), 1)
        for sample in element.apply([[pcm[2 * (1024 * f + i)] for i in range(1024)]])[0]:
            rendered.extend((sample, sample))
    path = work / 'model.aac'
    path.write_bytes(bytes(stream))
    rendered_path = work / 'model.rendered.f32'
    rendered_path.write_bytes(rendered.tobytes())
    level, _ = snr(rendered_path, reference(path, 1))
    if level < SNR:
        raise Failure(f'model rendering: {level:.1f} dB against FFmpeg')
    checks.append({'test': 'model rendering', 'result': 'matched', 'comparator': 'FFmpeg', 'snr_db': round(level, 1)})
    print(f'model rendering: {level:.1f} dB against FFmpeg', flush=True)


def containers(work, adts, checks):
    """Implicit, explicit and backward-compatible signalling; Matroska and
    fragmented MP4. Stereo 24 kHz core."""
    pcm = Path(str(adts) + '.f32').read_bytes()
    m4a = work / 'implicit.m4a'
    ffmpeg('-i', adts, '-c', 'copy', '-bsf:a', 'aac_adtstoasc', m4a)
    base = m4a.read_bytes()
    implicit = sbr_vectors.config_bits([(2, 5), (6, 4), (2, 4), (0, 3)])
    if base[aac.audio_specific_config(base):][:2] != implicit:
        raise Failure('implicit.m4a: unexpected AudioSpecificConfig')
    variants = {
        'implicit.m4a': None,
        'explicit.m4a': sbr_vectors.config_bits([(5, 5), (6, 4), (2, 4), (3, 4), (2, 5), (0, 3)]),
        'sync-extension.m4a': sbr_vectors.config_bits([(2, 5), (6, 4), (2, 4), (0, 3), (0x2b7, 11), (5, 5), (1, 1),
                                                       (3, 4)]),
    }
    for name, config in variants.items():
        path = work / name
        if config:
            path.write_bytes(sbr_vectors.replace_config(base, config))
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        if ours.read_bytes() != pcm:
            raise Failure(f'{name}: differs from the ADTS decode')
        checks.append({'test': name, 'result': 'exact', 'comparator': adts.name})
    for name, flags in (('stereo.mka', []), ('fragmented.m4a', ['-movflags', 'frag_keyframe+empty_moov'])):
        path = work / name
        ffmpeg('-i', m4a, '-c', 'copy', *flags, path)
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        if ours.read_bytes() != pcm:
            raise Failure(f'{name}: differs from the ADTS decode')
        checks.append({'test': name, 'result': 'exact', 'comparator': adts.name})
    print('Implicit, explicit and sync-extension MP4, Matroska and fragmented MP4: exact', flush=True)
    # sbrPresentFlag 0: the SBR data is skipped and the core plays at 24 kHz.
    path = work / 'sbr-absent.m4a'
    path.write_bytes(sbr_vectors.replace_config(
        base, sbr_vectors.config_bits([(2, 5), (6, 4), (2, 4), (0, 3), (0x2b7, 11), (5, 5), (0, 1)])))
    against_ffmpeg(path, 2, checks, 'sbr-absent.m4a (core only)')
    if 'rate=24000' not in decode_f32(path, Path(str(path) + '.f32')):
        raise Failure('sbr-absent.m4a: expected the 24 kHz core rate')


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'chain-oracle': 'chain-oracle.c', 'aac-oracle': 'aac-oracle.c'}, library)
    chain, oracle = exe('chain-oracle'), exe('aac-oracle')
    work = scratch('heaac')
    fixtures = Fixtures(work)
    checks = []
    used = set()

    model_check(fixtures, work, checks)

    # Layouts and rates.
    cases = [('mono-24k', 1, 24000), ('mono-22k', 1, 22050), ('mono-16k', 1, 16000), ('mono-11k', 1, 11025),
             ('stereo-24k', 2, 24000), ('stereo-22k', 2, 22050), ('stereo-12k', 2, 12000), ('stereo-32k', 2, 32000),
             ('stereo-44k', 2, 44100), ('stereo-48k', 2, 48000), ('3.0-24k', 3, 24000), ('5.1-24k', 6, 24000),
             ('7.1-22k', 7, 22050)]
    worst = math.inf
    for k, (name, config, rate) in enumerate(cases):
        extension = (lambda f: bytes([0x40 | f % 64, 0x5a]) if f % 5 == 2 else None) if k % 3 == 0 else None
        path, tools = fixtures.stream(f'{name}.aac', config, rate, 100 + 10 * k, extension=extension)
        used |= tools
        _, level = against_ffmpeg(path, config, checks)
        worst = min(worst, level)
    missing = COVERAGE - used
    if missing:
        raise Failure(f'generated streams did not use: {sorted(missing)}')
    checks.append({'test': 'SBR coverage', 'result': 'complete', 'tools': sorted(used)})

    containers(work, work / 'stereo-24k.aac', checks)

    # Signalling and payload variants.
    path, _ = fixtures.stream('crc.aac', 2, 24000, 7, crc=True)
    against_ffmpeg(path, 2, checks)
    cores = [fixtures.core(sbr_vectors.SCE, 24000, 9)]
    data, _ = sbr_vectors.stream(cores, 1, vectors.RATES.index(24000), 9, 24)
    blocks = sbr_vectors.raw_blocks(data)
    early = vectors.Bits()                                   # fill element before the channel element
    payload = vectors.Bits()
    model.Element(48000, 1).write_payload(random.Random(1), payload, sbr_vectors.header(random.Random(2), 48000))
    early_fill = sbr_vectors.fill(payload)
    early.put(early_fill.value, early_fill.count)
    first = int.from_bytes(blocks[0], 'big'), len(blocks[0]) * 8
    early.put(*first)
    path = work / 'sbr-before-element.aac'
    path.write_bytes(vectors.adts(early.data(), vectors.RATES.index(24000), 1) +
                     b''.join(vectors.adts(b, vectors.RATES.index(24000), 1) for b in blocks[1:]))
    plain = work / 'sbr-plain.aac'
    plain.write_bytes(data)
    decode_f32(path, Path(str(path) + '.f32'))
    decode_f32(plain, Path(str(plain) + '.f32'))
    # FFmpeg 6.1 returns from such a fill element without skipping its payload
    # and loses the frame; ISO skips it, so the stream must equal the plain one.
    if Path(str(path) + '.f32').read_bytes() != Path(str(plain) + '.f32').read_bytes():
        raise Failure('sbr-before-element.aac: SBR data before the first channel element was not skipped')
    checks.append({'test': path.name, 'result': 'exact', 'comparator': 'the stream without that fill element',
                   'note': 'FFmpeg 6.1 does not skip the payload and drops the frame'})
    # Implicit SBR must appear in the first frame. FFmpeg locks the output
    # configuration after it in MP4 (in ADTS it switches rate mid-stream).
    late = work / 'sbr-after-first-frame.aac'
    late.write_bytes(vectors.adts(cores[0][0], vectors.RATES.index(24000), 1) +
                     b''.join(vectors.adts(b, vectors.RATES.index(24000), 1) for b in blocks[1:]))
    late_m4a = work / 'sbr-after-first-frame.m4a'
    ffmpeg('-i', late, '-c', 'copy', '-bsf:a', 'aac_adtstoasc', late_m4a)
    against_ffmpeg(late_m4a, 1, checks, 'sbr-after-first-frame.m4a (core only)')
    decode_f32(late, Path(str(late) + '.f32'))
    if Path(str(late_m4a) + '.f32').read_bytes() != Path(str(late) + '.f32').read_bytes():
        raise Failure('sbr-after-first-frame.aac: differs from the MP4 decode')
    checks.append({'test': late.name, 'result': 'exact', 'comparator': late_m4a.name,
                   'note': 'FFmpeg 6.1 switches ADTS output to the SBR rate mid-stream'})

    # Corrupted payloads: FFmpeg turns SBR off for each error the same way.
    def flips(seed, count):
        r = random.Random(seed)

        def mutate(f, index, payload):
            if r.random() > 0.4:
                return None
            value = payload.value
            for _ in range(count):
                value ^= 1 << r.randrange(payload.count)
            out = vectors.Bits()
            out.put(value, payload.count)
            return out
        return mutate
    for seed in range(12):                                   # mono could name parametric stereo
        config = 2 if seed % 2 else 6 if seed % 4 == 0 else 3
        path, _ = fixtures.stream(f'corrupt-{seed}.aac', config, 24000, 500 + seed, frames=24,
                                  mutate=flips(seed, 1 + seed % 4))
        against_ffmpeg(path, config, checks)
    clean = rejected = 0
    for seed in range(60):
        config = (1, 2, 3, 6)[seed % 4]
        path, _ = fixtures.stream('fuzz.aac', config, (24000, 22050, 16000, 44100, 48000)[seed % 5], 900 + seed,
                                  frames=10, mutate=flips(1000 + seed, (1, 4, 16, 64)[seed % 4]))
        line = json.loads(run([oracle, path]).strip().splitlines()[-1])
        if line['decode_error'] == 0 and line['result'] == 'decoded':
            clean += 1
        elif line['decode_error'] == 101 and config == 1:
            rejected += 1                                   # flipped bits named parametric stereo
        else:
            raise Failure(f'fuzz seed {seed}: {line}')
    checks.append({'test': '60 heavily corrupted streams', 'result': 'handled', 'decoded': clean,
                   'parametric_stereo_rejected': rejected})
    print(f'60 corrupted streams: {clean} decoded, {rejected} rejected as parametric stereo', flush=True)

    # Seeks into steady streams.
    for name, config in (('steady-mono.aac', 1), ('steady-stereo.aac', 2)):
        path, _ = fixtures.stream(name, config, 24000, 77 + config, frames=40, steady=True)
        whole = Path(str(path) + '.f32')
        decode_f32(path, whole)
        pcm = floats(whole)
        lowest = math.inf
        for target in (0, 2048, 5000, 20480, 40000, 61000, 79000):
            dump = work / 'seek.f32'
            line = json.loads(run([chain, 'dump', path, str(target), '2048', dump]).strip().splitlines()[-1])
            if line.get('result') != 'dumped' or line['base'] != target // 2048 * 2048:
                raise Failure(f'{name} seek to {target}: {line}')
            expected = pcm[2 * target:2 * (target + 2048)]
            got = floats(dump)
            error = sum((x - y) ** 2 for x, y in zip(got, expected))
            signal = sum(y * y for y in expected) or 1.0
            level = math.inf if error == 0 else 10 * math.log10(signal / error)
            if len(got) != len(expected) or level < SEEK_SNR:
                raise Failure(f'{name} seek to {target}: {level:.1f} dB against continuous decoding')
            lowest = min(lowest, level)
        checks.append({'test': f'{name} seeks', 'result': 'matched continuous decoding', 'targets': 7,
                       'minimum_snr_db': None if math.isinf(lowest) else round(lowest, 1)})
        print(f'{name}: 7 seeks, at least {lowest:.1f} dB against continuous decoding', flush=True)

    # Unsupported: parametric stereo and downsampled SBR.
    base = (work / 'implicit.m4a').read_bytes()
    unsupported = {
        'ps-object.m4a': sbr_vectors.config_bits([(29, 5), (6, 4), (1, 4), (3, 4), (2, 5), (0, 3)]),
        'ps-sync-extension.m4a': sbr_vectors.config_bits([(2, 5), (6, 4), (2, 4), (0, 3), (0x2b7, 11), (5, 5),
                                                          (1, 1), (3, 4), (0x548, 11), (1, 1)]),
        'downsampled-sbr.m4a': sbr_vectors.config_bits([(5, 5), (6, 4), (2, 4), (6, 4), (2, 5), (0, 3)]),
    }
    for name, config in unsupported.items():
        path = work / name
        path.write_bytes(sbr_vectors.replace_config(base, config))
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 101:
            raise Failure(f'{name}: expected decode_error 101, got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
    cores = [fixtures.core(sbr_vectors.SCE, 24000, 9)]
    data, _ = sbr_vectors.stream(cores, 1, vectors.RATES.index(24000), 9, 8,
                                 extension=lambda f: bytes([0x80, 0, 0]))        # EXTENSION_ID_PS
    path = work / 'ps-data.aac'
    path.write_bytes(data)
    line = run([chain, 'reject', path]).strip().splitlines()[-1]
    if json.loads(line).get('decode_error') != 101:
        raise Failure(f'ps-data.aac: expected decode_error 101, got {line}')
    checks.append({'test': path.name, 'result': 'rejected', 'oracle': line})
    print('Parametric stereo and downsampled SBR reject as unsupported', flush=True)

    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'HE-AAC playback', 'result': 'played', 'stats': play(work / 'stereo-24k.aac')})
    write_report('heaac', {'result': 'passed', 'checks': checks, 'minimum_snr_db': round(worst, 1),
                           'scope': 'HE-AAC SBR in ADTS, MP4 (implicit, explicit and backward-compatible '
                                    'signalling) and Matroska: generated SBR data on FFmpeg-encoded cores, mono to '
                                    '7.1 at core rates 11.025-48 kHz, against FFmpeg; CRC, extended data, '
                                    'corrupted payloads; seeks; parametric stereo rejects.'})
    print(f'Passed {len(checks)} HE-AAC checks.')


if __name__ == '__main__':
    main_guard(main)
