#!/usr/bin/env python3
"""AAC in LOAS/LATM (.loas and .latm files, MPEG-TS stream type 0x11)
against the same AAC frames in ADTS.

usage: python3 tests/verify-latm.py [--skip-playback]
- FFmpeg's LATM muxer copies FFmpeg-encoded ADTS streams: mono at 8-22.05
  kHz, stereo at 32-96 kHz and 5.1 at 48 kHz, with the StreamMuxConfig in
  every frame, every 20 frames (FFmpeg's default) and every 1000. LAMP's
  decode of each equals its decode of the ADTS stream exactly, and FFmpeg's
  decode of each equals FFmpeg's ADTS decode.
- tests/latm_vectors.py writes what FFmpeg's muxer does not: audioMuxVersion
  1 (taraBufferFullness, ascLen, fill bits inside ascLen), other data in
  both versions (version 0's escaped length), the configuration CRC, frames
  before the first configuration (FFmpeg's command line decodes them with
  the configuration its probe found; LAMP too), frames whose payload length
  disagrees with the LOAS length or overruns the frame (skipped, as FFmpeg
  skips them), and 2-4 sub-frames per frame (FFmpeg reads only the first).
  Each equals the ADTS decode of the frames it carries; FFmpeg agrees on
  everything but the sub-frames.
- HE-AAC: SBR streams written by tests/sbr_vectors.py with implicit
  signalling, object type 5 and the backward-compatible sync extension
  (version 1), and a PS stream with object type 29, each equal to its ADTS
  decode; sbrPresentFlag 0 decodes the core only, as FFmpeg does.
- MPEG-TS: FFmpeg's -mpegts_flags latm encode, LOAS streams FFmpeg copies
  into transport streams, streams written by tests/latm_vectors.py (sub-
  frames; LOAS frames straddling PES packets), and an ADTS stream FFmpeg
  labels LATM (-c copy with -mpegts_flags latm), each equal to the raw
  decode, and FFmpeg's decode equal to its raw decode but for sub-frames.
- Seeks (tests/seek-oracle.c) equal continuous decoding.
- ID3v2 before and ID3v1 after the stream leave the decode unchanged.
- Unsupported (decode_error 101): audioMuxVersionA, two programs or two
  layers, fixed and CELP frame lengths, object types 23 (ER AAC LD) and 42
  (USAC, an escaped type), a program config element, 960-sample frames, a
  configuration change. Malformed (100): ascLen shorter than the
  configuration, data between frames, no configuration at all. A cancelled
  open stops cleanly; one file plays.
Writes <out>/latm-verification.json.
"""
import array
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aac_vectors as vectors
import latm_vectors as latm
import sbr_vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, lamp_cli, main_guard, out_dir,
                       play, playback_requested, run, scratch, write_report)

SNR = 100.0


def floats(path):
    return array.array('f', Path(path).read_bytes())


def snr(ours, reference):
    a, b = floats(ours), floats(reference)
    if len(a) != len(b):
        raise Failure(f'{Path(ours).name}: {len(a) // 2} frames, FFmpeg {len(b) // 2}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b) or 1.0
    return math.inf if error == 0 else 10 * math.log10(signal / error)


def ours(path):
    out = Path(str(path) + '.f32')
    stats = decode_f32(path, out)
    return out.read_bytes(), stats


def theirs(path):
    """FFmpeg's decode on its C code path (see verify-heaac.py), native channels."""
    out = Path(str(path) + '.ffmpeg.f32')
    ffmpeg('-cpuflags', '0', '-i', path, '-f', 'f32le', out)
    return out.read_bytes()


def adts_stream(blocks, data):
    """An ADTS stream of blocks with the fixed header of ADTS data."""
    rate_index, channels = (data[2] >> 2) & 15, (data[2] & 1) << 2 | data[3] >> 6
    return b''.join(vectors.adts(block, rate_index, channels) for block in blocks)


class Fixtures:
    """FFmpeg-encoded single-element cores for HE-AAC streams (as verify-heaac.py)."""

    def __init__(self, work):
        self.work = work

    def core(self, kind, rate, seed):
        path = self.work / f'core-{kind}-{rate}-{seed}.aac'
        if not path.exists():
            source = f'anoisesrc=r={rate}:d=4.5:a=0.3:seed={seed}'
            channels = 2 if kind == sbr_vectors.CPE else 1
            ffmpeg('-f', 'lavfi', '-i', source, '-ac', str(channels), '-c:a', 'aac', '-b:a', str(4 * rate * channels),
                   '-cutoff', str(rate // 2), '-aac_pns', '0', '-flags', '+bitexact', path)
        return sbr_vectors.raw_blocks(path.read_bytes())

    def stream(self, name, config, rate, seed, frames=36, **options):
        cores = [self.core(kind, rate, seed + i) for i, kind in enumerate(sbr_vectors.LAYOUTS[config])]
        data, _ = sbr_vectors.stream(cores, config, vectors.RATES.index(rate), seed, frames, **options)
        path = self.work / name
        path.write_bytes(data)
        return path


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('latm')
    checks = []

    def same(path, reference, label, ffmpeg_reference=None, note=None):
        """LAMP's decode of path equals reference (bytes of a LAMP decode);
        FFmpeg's decode of path equals ffmpeg_reference when given."""
        pcm, stats = ours(path)
        if pcm != reference:
            raise Failure(f'{path.name}: differs from {label} ({stats})')
        entry = {'test': path.name, 'result': 'exact', 'comparator': label}
        if ffmpeg_reference is not None:
            if theirs(path) != ffmpeg_reference:
                raise Failure(f'{path.name}: FFmpeg decodes it differently from {label}')
            entry['ffmpeg'] = 'equal to its decode of ' + label
        if note:
            entry['note'] = note
        checks.append(entry)
        return stats

    # FFmpeg's muxer.
    sources = [('mono-8k', 8000, 1, '24k'), ('mono-16k', 16000, 1, '48k'), ('mono-22k', 22050, 1, '64k'),
               ('stereo-32k', 32000, 2, '96k'), ('stereo-44k', 44100, 2, '128k'), ('stereo-48k', 48000, 2, '256k'),
               ('stereo-96k', 96000, 2, '320k'), ('5.1-48k', 48000, 6, '384k')]
    adts = {}
    for k, (name, rate, channels, bitrate) in enumerate(sources):
        path = work / f'{name}.aac'
        layout = ['-af', 'aformat=channel_layouts=5.1'] if channels == 6 else ['-ac', str(channels)]
        ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d=3:a=0.3:seed={k + 1}', *layout, '-c:a', 'aac',
               '-b:a', bitrate, '-aac_pns', '0', path)
        adts[name] = (path, ours(path)[0], theirs(path))
        for interval in (1, 20, 1000):
            loas = work / f'{name}-smc{interval}.loas'
            ffmpeg('-i', path, '-c', 'copy', '-smc-interval', str(interval), '-f', 'latm', loas)
            same(loas, adts[name][1], path.name, adts[name][2])
    print(f'{len(sources) * 3} FFmpeg LATM streams: exact against ADTS, FFmpeg agreeing', flush=True)
    level = snr(Path(str(work / 'stereo-48k-smc20.loas') + '.f32'),
                Path(str(work / 'stereo-48k-smc20.loas') + '.ffmpeg.f32'))
    if level < SNR:
        raise Failure(f'stereo-48k-smc20.loas: {level:.1f} dB against FFmpeg')
    checks.append({'test': 'stereo-48k-smc20.loas against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})

    # Written streams.
    base, pcm, reference = adts['stereo-48k']
    data = base.read_bytes()
    blocks, asc = latm.raw_blocks(data), latm.adts_config(data)
    if max(map(len, blocks)) < 510:
        raise Failure('stereo-48k.aac: expected payloads of more than 510 bytes')
    variants = {
        'version1.loas': dict(version=1),
        'version1-fill.loas': dict(version=1, asc_fill=11, interval=3),
        'version1-other.loas': dict(version=1, other_bits=137, crc=True, interval=5),
        'version0-other.loas': dict(other_bits=200, other_escape=2, crc=True, interval=7),
        'version0-other-byte.loas': dict(other_bits=96),
        'late-config.loas': dict(skip_first=5, interval=50),
    }
    for name, options in variants.items():
        path = work / name
        path.write_bytes(latm.stream(blocks, asc, **options))
        same(path, pcm, base.name, reference)

    # Frames whose lengths disagree with the LOAS frame are skipped.
    bad = {3: 'short', 9: 'long', 17: 'short', 30: 'long'}
    out = bytearray()
    for f, block in enumerate(blocks):
        smc = latm.stream_mux_config(asc) if f % 20 == 0 else None
        if bad.get(f) == 'short':                      # more than 256 bits after the payload
            element = latm.element([block[:len(block) - 40]], smc) + bytes(40)
        elif bad.get(f) == 'long':                     # a payload past the frame
            element = latm.element([block], smc, lengths=[len(block) + 2])
        else:
            element = latm.element([block], smc)
        out += latm.loas(element)
    path = work / 'skipped-frames.loas'
    path.write_bytes(out)
    kept = [b for f, b in enumerate(blocks) if f not in bad]
    expected = work / 'skipped-frames.aac'
    expected.write_bytes(adts_stream(kept, data))
    same(path, ours(expected)[0], expected.name, theirs(expected), 'mismatched frames skipped, as FFmpeg skips them')

    # Sub-frames: every payload decodes (FFmpeg reads only the first).
    for count in (2, 3, 4):
        path = work / f'subframes-{count}.loas'
        used = blocks[:len(blocks) // count * count]
        path.write_bytes(latm.stream(used, asc, subframes=count, interval=4))
        expected = work / f'subframes-{count}.aac'
        expected.write_bytes(adts_stream(used, data))
        same(path, ours(expected)[0], expected.name, None, 'FFmpeg 6.1 reads only the first sub-frame')
    print('Written versions 0 and 1, other data, CRC, late configuration, skipped frames, sub-frames: exact',
          flush=True)

    # HE-AAC.
    fixtures = Fixtures(work)
    he = fixtures.stream('sbr-stereo.aac', 2, 24000, 7)
    he_pcm, he_ref = ours(he)[0], theirs(he)
    he_blocks = latm.raw_blocks(he.read_bytes())
    he_configs = {
        'sbr-implicit.loas': (latm.config([(2, 5), (6, 4), (2, 4), (0, 3)]), {}),
        'sbr-explicit.loas': (latm.config([(5, 5), (6, 4), (2, 4), (3, 4), (2, 5), (0, 3)]), {}),
        'sbr-sync-extension.loas': (latm.config([(2, 5), (6, 4), (2, 4), (0, 3), (0x2b7, 11), (5, 5), (1, 1),
                                                 (3, 4)]), dict(version=1)),
    }
    for name, (config, options) in he_configs.items():
        path = work / name
        path.write_bytes(latm.stream(he_blocks, config, interval=8, **options))
        stats = same(path, he_pcm, he.name, he_ref)
        if 'rate=48000' not in stats:
            raise Failure(f'{name}: expected 48 kHz output, {stats}')
    path = work / 'sbr-absent.loas'
    path.write_bytes(latm.stream(he_blocks, latm.config([(2, 5), (6, 4), (2, 4), (0, 3), (0x2b7, 11), (5, 5),
                                                         (0, 1)]), version=1))
    stats = ours(path)[1]
    level = snr(Path(str(path) + '.f32'), Path(str(path) + '.ffmpeg.f32')) if theirs(path) else 0
    if 'rate=24000' not in stats or level < SNR:
        raise Failure(f'sbr-absent.loas: {stats}, {level:.1f} dB against FFmpeg')
    checks.append({'test': path.name, 'result': 'core only, matched FFmpeg', 'snr_db': round(level, 1)})
    ps = fixtures.stream('ps-mono.aac', 1, 24000, 11, ps=True)
    ps_pcm, ps_ref = ours(ps)[0], theirs(ps)
    ps_blocks = latm.raw_blocks(ps.read_bytes())
    for name, config in (('ps-implicit.loas', latm.config([(2, 5), (6, 4), (1, 4), (0, 3)])),
                         ('ps-object.loas', latm.config([(29, 5), (6, 4), (1, 4), (3, 4), (2, 5), (0, 3)]))):
        path = work / name
        path.write_bytes(latm.stream(ps_blocks, config, interval=8))
        same(path, ps_pcm, ps.name, ps_ref)
    print('HE-AAC: implicit, object type 5, sync extension, PS: exact; sbrPresentFlag 0: core only', flush=True)

    # Transport streams.
    ts = work / 'encoded-latm.ts'
    ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=r=48000:d=3:a=0.3:seed=21', '-ac', '2', '-c:a', 'aac', '-b:a', '160k',
           '-aac_pns', '0', '-f', 'mpegts', '-mpegts_flags', 'latm', ts)
    if b'\x11\xe1\x00' not in ts.read_bytes()[:4096]:
        raise Failure(f'{ts.name}: expected stream type 0x11')
    raw = work / 'encoded-latm.loas'
    ffmpeg('-i', ts, '-c', 'copy', '-f', 'latm', raw)
    if int.from_bytes(raw.read_bytes()[:2], 'big') & 0xffe0 != 0x56e0:
        raise Failure(f'{raw.name}: expected LOAS frames')
    same(ts, ours(raw)[0], raw.name, theirs(raw))
    level = snr(Path(str(ts) + '.f32'), Path(str(ts) + '.ffmpeg.f32'))
    if level < SNR:
        raise Failure(f'{ts.name}: {level:.1f} dB against FFmpeg')
    checks.append({'test': f'{ts.name} against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})
    for name in ('version1-other.loas', 'sbr-explicit.loas', 'stereo-44k-smc20.loas'):
        source = work / name
        path = work / (name[:-5] + '.ts')
        ffmpeg('-i', source, '-c', 'copy', '-f', 'mpegts', path)
        same(path, ours(source)[0], source.name, theirs(source))
    # Written transport streams: sub-frames, and frames straddling PES packets.
    for name, rate, options in (('subframes-3.loas', 48000, dict(per_pes=1)),
                                ('version0-other.loas', 48000, dict(per_pes=3, split=17)),
                                ('mono-22k-smc20.loas', 22050, dict(per_pes=2, split=-40))):
        source = work / name
        path = work / f'written-{name[:-5]}.ts'
        path.write_bytes(latm.transport(source.read_bytes(), rate, **options))
        same(path, ours(source)[0], source.name, None if 'subframes' in name else theirs(source))
    path = work / 'adts-labelled-latm.ts'
    ffmpeg('-i', base, '-c', 'copy', '-f', 'mpegts', '-mpegts_flags', 'latm', path)
    same(path, pcm, base.name, None, 'FFmpeg writes ADTS frames under stream type 0x11 here')
    print('Transport streams: exact', flush=True)

    # Seeks.
    for name in ('stereo-44k-smc20.loas', 'version0-other.loas', 'subframes-3.loas', 'encoded-latm.ts',
                 'mono-22k-smc1000.loas'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Tags.
    title = b'\x00LATM title'
    frame = b'TIT2' + len(title).to_bytes(4, 'big') + b'\x00\x00' + title
    id3v2 = b'ID3\x03\x00\x00' + bytes([0, 0, 0, len(frame) + 10]) + frame + bytes(10)
    id3v1 = b'TAG' + b'Other title'.ljust(30, b'\0') + bytes(94) + b'\xff'
    path = work / 'tagged.loas'
    path.write_bytes(id3v2 + (work / 'stereo-48k-smc20.loas').read_bytes() + id3v1)
    same(path, pcm, base.name)
    tags = run([lamp_cli(), '--tags', path])
    if 'title=LATM title' not in tags or 'Other title' in tags:
        raise Failure(f'{path.name}: tags {tags!r}')
    checks.append({'test': f'{path.name} tags', 'result': 'ID3v2 title read, ID3v1 ignored, as FFmpeg does'})

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

    def custom(asc_value, **mux):
        out = bytearray()
        for f, block in enumerate(blocks[:12]):
            smc = latm.stream_mux_config(asc_value, **mux) if f % 4 == 0 else None
            out += latm.loas(latm.element([block], smc))
        return bytes(out)

    rate_index, channels = (data[2] >> 2) & 15, (data[2] & 1) << 2 | data[3] >> 6
    unsupported = {
        'version-a.loas': custom(asc, version=1, version_a=1),
        'two-programs.loas': custom(asc, programs=1),
        'two-layers.loas': custom(asc, layers=1),
        'fixed-length.loas': custom(asc, frame_length_type=1),
        'celp-length.loas': custom(asc, frame_length_type=3),
        'er-aac-ld.loas': custom(latm.config([(23, 5), (rate_index, 4), (channels, 4), (0, 3)])),
        'usac.loas': custom(latm.config([(31, 5), (10, 6), (rate_index, 4), (channels, 4), (0, 3)])),
        'pce.loas': custom(latm.config([(2, 5), (rate_index, 4), (0, 4), (0, 3)])),
        'frame-960.loas': custom(latm.config([(2, 5), (rate_index, 4), (channels, 4), (1, 1), (0, 2)])),
    }
    changed = bytearray(custom(asc))
    changed += latm.loas(latm.element([blocks[12]], latm.stream_mux_config(
        latm.config([(2, 5), (rate_index + 1, 4), (channels, 4), (0, 3)]))))
    unsupported['config-change.loas'] = bytes(changed)
    for name, stream in unsupported.items():
        reject(name, stream, 101)
    reject('short-asclen.loas', custom(asc, version=1, asc_length=asc[1] - 1), 100)
    junk = bytearray(latm.stream(blocks[:20], asc))
    cut = len(latm.stream(blocks[:10], asc))
    reject('junk-between-frames.loas', bytes(junk[:cut]) + bytes(5) + bytes(junk[cut:]), 100)
    no_config = b''.join(latm.loas(latm.element([b])) for b in blocks[:10])
    reject('no-config.loas', no_config, 100)
    print(f'Rejected {rejected} unsupported or malformed streams', flush=True)

    line = run([chain, 'cancel-open', work / 'stereo-48k-smc20.loas']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open stereo-48k-smc20.loas', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'LATM playback', 'result': 'played', 'stats': play(work / 'sbr-explicit.loas')})
    write_report('latm', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                          'scope': 'AAC-LC and HE-AAC in LOAS/LATM files and MPEG-TS (stream type 0x11): FFmpeg '
                                   'and test-written streams (mux versions 0 and 1, other data, CRC, late '
                                   'configuration, skipped frames, sub-frames) exact against ADTS; seeks; tags; '
                                   'unsupported and malformed streams; cancellation.'})
    print(f'Passed {len(checks)} LATM checks.')


if __name__ == '__main__':
    main_guard(main)
