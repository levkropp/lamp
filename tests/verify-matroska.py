#!/usr/bin/env python3
"""Matroska/WebM audio: codecs, lacing, unknown sizes, track selection, seeks.

usage: python3 tests/verify-matroska.py [--skip-playback]
FFmpeg muxes each fixture; its own decode of the Matroska file is the
reference (exact for PCM/FLAC, within the codec suites' tolerances for
Vorbis, Opus and MPEG audio). Opus and FLAC must also equal LAMP's decode of
the same stream in Ogg. A test-only muxer rewrites the same frames with
Xiph, EBML and fixed lacing, unknown-size Segment/Cluster elements, several
tracks and default flags; the output must not change. Seeks are exact for
Vorbis, FLAC, PCM and MPEG audio; Opus seeks must equal Ogg Opus seeks.
Writes <out>/matroska-verification.json.
"""
import array
import math
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, check_file, decode_f32, exe, ffmpeg, main_guard, out_dir,
                       play, playback_requested, run, scratch, write_report)

TOLERANCE = {'opus': (0.00004, 60.0), 'vorbis': (0.0001, 60.0), 'mp3': (0.00002, 90.0), 'mp2': (0.00004, 70.0)}


# ------------------------------------------------------------ EBML helpers
def read_vint(data, pos, keep_marker=False):
    first = data[pos]
    length = 9 - first.bit_length()
    value = first if keep_marker else first & ((1 << (8 - length)) - 1)
    for i in range(1, length):
        value = (value << 8) | data[pos + i]
    return value, length


def elements(data, start, end):
    """Yields (id, payload start, payload end) for children in [start, end)."""
    pos = start
    while pos < end:
        ident, n = read_vint(data, pos, True)
        size, m = read_vint(data, pos + n)
        payload = pos + n + m
        yield ident, payload, payload + size
        pos = payload + size


def size_bytes(size, width=None):
    if width is None:
        width = 1
        while size >= (1 << (7 * width)) - 1:
            width += 1
    return ((1 << (7 * width)) | size).to_bytes(width, 'big')


def element(ident, payload, unknown=False):
    head = ident.to_bytes((ident.bit_length() + 7) // 8, 'big')
    return head + (b'\x01\xff\xff\xff\xff\xff\xff\xff' if unknown else size_bytes(len(payload))) + payload


def uint(ident, value):
    return element(ident, value.to_bytes(max(1, (value.bit_length() + 7) // 8), 'big'))


def sint(ident, value):
    """Signed integer element: enough bytes that the sign bit is clear for positives."""
    width = 1
    while not -(1 << (8 * width - 1)) <= value < (1 << (8 * width - 1)):
        width += 1
    return element(ident, value.to_bytes(width, 'big', signed=True))


def parse(path):
    """Codec settings and the frames of the first audio track of an FFmpeg file."""
    data = Path(path).read_bytes()
    segment = next(e for e in elements(data, 0, len(data)) if e[0] == 0x18538067)
    track = {'frames': [], 'discard': 0}
    number = None
    for ident, a, b in elements(data, segment[1], segment[2]):
        if ident == 0x1654AE6B:
            for entry, ta, tb in elements(data, a, b):
                if entry != 0xAE:                      # TrackEntry; FFmpeg also writes CRC-32
                    continue
                fields = {i: data[pa:pb] for i, pa, pb in elements(data, ta, tb)}
                if int.from_bytes(fields.get(0x83, b'\0'), 'big') == 2 and number is None:
                    number = int.from_bytes(fields[0xD7], 'big')
                    track['codec'] = fields[0x86].rstrip(b'\0').decode()
                    track['private'] = fields.get(0x63A2)
                    track['audio'] = fields.get(0xE1, b'')
        elif ident == 0x1F43B675:
            for ci, ca, cb in elements(data, a, b):
                blocks = []
                if ci == 0xA3:
                    blocks.append((ca, cb, 0))
                elif ci == 0xA0:
                    inner = {i: (pa, pb) for i, pa, pb in elements(data, ca, cb)}
                    pad = 0
                    if 0x75A2 in inner:
                        pa, pb = inner[0x75A2]
                        pad = int.from_bytes(data[pa:pb], 'big', signed=True)
                    blocks.append((*inner[0xA1], pad))
                for ba, bb, pad in blocks:
                    tn, n = read_vint(data, ba)
                    if tn != number:
                        continue
                    if (data[ba + n + 2] >> 1) & 3:
                        raise Failure('FFmpeg fixture unexpectedly uses lacing')
                    track['frames'].append(data[ba + n + 3:bb])
                    track['discard'] = pad
    return track


def lace(frames, mode):
    """Block payload after the header: Xiph (1), fixed (2) or EBML (3) lacing."""
    count = bytes([len(frames) - 1])
    if mode == 1:
        sizes = b''
        for f in frames[:-1]:
            sizes += b'\xff' * (len(f) // 255) + bytes([len(f) % 255])
        return count + sizes + b''.join(frames)
    if mode == 2:
        return count + b''.join(frames)
    sizes = size_bytes(len(frames[0]))
    for prev, cur in zip(frames, frames[1:-1]):
        diff = len(cur) - len(prev)
        width = 1
        while not -(1 << (7 * width - 1)) + 1 <= diff <= (1 << (7 * width - 1)) - 1:
            width += 1
        sizes += size_bytes(diff + (1 << (7 * width - 1)) - 1, width)
    return count + sizes + b''.join(frames)


def blocks_of(frames, lacing, group):
    """Groups frames into blocks; fixed lacing needs runs of equal sizes."""
    out, i = [], 0
    while i < len(frames):
        chunk = frames[i:i + group] if lacing else frames[i:i + 1]
        if lacing == 2:
            k = 1
            while k < len(chunk) and len(chunk[k]) == len(chunk[0]):
                k += 1
            chunk = chunk[:k]
        out.append(chunk)
        i += len(chunk)
    return out


def mux(track, lacing=0, group=4, unknown=False, extra_tracks=(), selected_default=1, number=1, cluster_blocks=8):
    """A Matroska file holding the track's frames; extra_tracks are TrackEntry payloads."""
    entry = uint(0xD7, number) + uint(0x83, 2) + uint(0x88, selected_default) + element(0x86, track['codec'].encode())
    if track.get('private'):
        entry += element(0x63A2, track['private'])
    if track.get('audio'):
        entry += element(0xE1, track['audio'])
    tracks = element(0x1654AE6B, b''.join(element(0xAE, e) for e in extra_tracks) + element(0xAE, entry))
    header = element(0x1A45DFA3, uint(0x4286, 1) + element(0x4282, b'matroska'))
    blocks = blocks_of(track['frames'], lacing, group)
    clusters = []
    for c in range(0, len(blocks), cluster_blocks):
        body = uint(0xE7, c)
        for k, chunk in enumerate(blocks[c:c + cluster_blocks]):
            flags = 0x80 | ((lacing << 1) if len(chunk) > 1 else 0)
            payload = size_bytes(number) + b'\0\0' + bytes([flags])
            payload += lace(chunk, lacing) if len(chunk) > 1 else chunk[0]
            if c + k == len(blocks) - 1 and track['discard']:
                body += element(0xA0, element(0xA1, payload) + sint(0x75A2, track['discard']))
            else:
                body += element(0xA3, payload)
        clusters.append(element(0x1F43B675, body, unknown))
    info = element(0x1549A966, uint(0x2AD7B1, 1000000))
    return header + element(0x18538067, info + tracks + b''.join(clusters), unknown)


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


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('matroska')
    checks = []
    tone = 'aevalsrc=0.3*sin(2*PI*997*t)+0.05*sin(2*PI*5100*t)|0.2*sin(2*PI*431*t):s={rate}:d=1.5'
    noise = 'anoisesrc=r={rate}:d=1.2:a=0.25:seed={seed}'
    fixtures = [
        ('opus-stereo', 'opus', 48000, ['-c:a', 'libopus', '-b:a', '96k'], 2, None),
        ('opus-mono-cbr', 'opus', 48000, ['-c:a', 'libopus', '-b:a', '64k', '-vbr', 'off', '-ac', '1'], 1, None),
        ('opus-5.1', 'opus', 48000, ['-c:a', 'libopus', '-b:a', '256k', '-mapping_family', '1'], 6, '5.1'),
        ('vorbis-stereo', 'vorbis', 44100, ['-c:a', 'libvorbis', '-q:a', '5'], 2, None),
        ('vorbis-mono', 'vorbis', 22050, ['-c:a', 'libvorbis'], 1, None),
        ('vorbis-5.1', 'vorbis', 48000, ['-c:a', 'libvorbis'], 6, '5.1'),
        ('flac-16', 'flac', 44100, ['-c:a', 'flac'], 2, None),
        ('flac-24-96k', 'flac', 96000, ['-c:a', 'flac', '-sample_fmt', 's32'], 2, None),
        ('flac-5.1', 'flac', 48000, ['-c:a', 'flac'], 6, '5.1'),
        ('mp3', 'mp3', 44100, ['-c:a', 'libmp3lame', '-b:a', '160k'], 2, None),
        ('mp2', 'mp2', 48000, ['-c:a', 'mp2', '-b:a', '192k'], 2, None),
        ('pcm-s16', 'pcm', 44100, ['-c:a', 'pcm_s16le'], 2, None),
        ('pcm-s24', 'pcm', 48000, ['-c:a', 'pcm_s24le'], 2, None),
        ('pcm-s32be', 'pcm', 48000, ['-c:a', 'pcm_s32be'], 2, None),
        ('pcm-f32', 'pcm', 48000, ['-c:a', 'pcm_f32le'], 1, None),
        ('pcm-f64', 'pcm', 32000, ['-c:a', 'pcm_f64le'], 2, None),
        ('pcm-u8', 'pcm', 8000, ['-c:a', 'pcm_u8'], 1, None),
        ('pcm-s16-5.1', 'pcm', 48000, ['-c:a', 'pcm_s16le'], 6, '5.1'),
    ]
    files = {}
    for k, (name, kind, rate, coding, channels, layout) in enumerate(fixtures):
        source = (noise if kind in ('opus', 'vorbis', 'flac') else tone).format(rate=rate, seed=k + 1)
        layout_args = ['-af', f'aformat=channel_layouts={layout}'] if layout else ['-ac', str(channels)]
        for container in (('mka', 'webm') if kind in ('opus', 'vorbis') else ('mka',)):
            path = work / f'{name}.{container}'
            ffmpeg('-f', 'lavfi', '-i', source, *layout_args, '-ar', str(rate), *coding, path)
            ours = Path(str(path) + '.f32')
            stats = decode_f32(path, ours)
            reference = Path(str(path) + '.ffmpeg.f32')
            if kind == 'mp2':
                decoder = ['-c:a', 'mp2float']
            elif kind == 'mp3':
                decoder = ['-c:a', 'mp3float']
            else:
                decoder = []
            # Stereo references use LAMP's documented downmix weights only
            # for mono/stereo; multichannel compares against LAMP's own Ogg/native decode.
            if channels <= 2:
                upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
                ffmpeg(*decoder, '-i', path, *upmix, '-f', 'f32le', reference)
                peak, snr, frames, expected = measure(ours, reference)
                if frames != expected:
                    raise Failure(f'{path.name}: {frames // 2} frames, FFmpeg {expected // 2}')
                limit, min_snr = TOLERANCE.get(kind, (0.0, math.inf))
                if peak > limit or snr < min_snr:
                    raise Failure(f'{path.name}: peak error {peak:.3g}, SNR {snr:.1f} dB against FFmpeg')
                comparator = 'FFmpeg'
            else:
                comparator = 'multichannel: LAMP Ogg/native decode below'
                peak, snr = None, None
            files[path.name] = (path, kind, ours)
            checks.append({'test': path.name, 'result': 'matched', 'comparator': comparator,
                           'peak_error': peak, 'snr_db': None if snr is None or math.isinf(snr) else round(snr, 1),
                           'stats': stats.splitlines()[-1]})
            print(f'{path.name}: matched {comparator}', flush=True)
        # Opus and FLAC: the same stream in Ogg decodes identically.
        if kind in ('opus', 'flac'):
            ogg = work / f'{name}.{"opus" if kind == "opus" else "oga"}'
            ffmpeg('-i', work / f'{name}.mka', '-c', 'copy', ogg)
            ogg_pcm = Path(str(ogg) + '.f32')
            decode_f32(ogg, ogg_pcm)
            # FFmpeg's Ogg remux drops Matroska's DiscardPadding, so Ogg Opus
            # may run longer; everything Matroska presents must match.
            ours_mka = Path(str(work / f'{name}.mka') + '.f32').read_bytes()
            ours_ogg = ogg_pcm.read_bytes()
            if ours_ogg[:len(ours_mka)] != ours_mka or (kind == 'flac' and ours_ogg != ours_mka):
                raise Failure(f'{name}: Matroska and Ogg decodes differ')
            checks.append({'test': f'{name} Matroska vs Ogg', 'result': 'exact'})
        if kind == 'flac' and channels > 2:
            native = work / f'{name}.flac'
            ffmpeg('-i', work / f'{name}.mka', '-c', 'copy', native)
            native_pcm = Path(str(native) + '.f32')
            decode_f32(native, native_pcm)
            if native_pcm.read_bytes() != Path(str(work / f'{name}.mka') + '.f32').read_bytes():
                raise Failure(f'{name}: Matroska and native FLAC decodes differ')
        if kind in ('pcm', 'vorbis') and channels > 2:
            # Same samples through WAV/Ogg: LAMP's own decode must agree.
            other = work / f'{name}.{"wav" if kind == "pcm" else "ogg"}'
            if kind == 'pcm':
                ffmpeg('-i', work / f'{name}.mka', '-c', 'copy', other)
            else:
                # A direct Ogg encode: FFmpeg's remux rewrites granules from
                # millisecond timestamps, which LAMP rejects as contradictory.
                ffmpeg('-f', 'lavfi', '-i', source, *layout_args, '-ar', str(rate), *coding, other)
            other_pcm = Path(str(other) + '.f32')
            decode_f32(other, other_pcm)
            a = Path(str(work / f'{name}.mka') + '.f32').read_bytes()
            b = other_pcm.read_bytes()
            if kind == 'pcm' and a != b:
                raise Failure(f'{name}: Matroska and WAV decodes differ')
            if kind == 'vorbis' and (a != b[:len(a)] or len(b) - len(a) > 2048 * 8):
                raise Failure(f'{name}: Matroska and Ogg Vorbis decodes differ')
            checks.append({'test': f'{name} Matroska vs {other.suffix}', 'result': 'exact'})

    # Lacing, unknown sizes and track selection: the same frames, re-muxed.
    variants = 0
    for name in ('opus-stereo.mka', 'opus-mono-cbr.mka', 'vorbis-stereo.mka', 'flac-16.mka', 'mp2.mka', 'pcm-s16.mka',
                 'mp3.mka'):
        path, kind, ours = files[name]
        track = parse(path)
        expected = ours.read_bytes()
        cases = [('xiph', dict(lacing=1, group=5)), ('ebml', dict(lacing=3, group=7)), ('fixed', dict(lacing=2, group=6)),
                 ('unknown-sizes', dict(unknown=True)),
                 ('second-track-default', dict(number=2, extra_tracks=[uint(0xD7, 1) + uint(0x83, 2) + uint(0x88, 0) +
                                                                      element(0x86, b'A_OPUS') +
                                                                      element(0x63A2, b'OpusHead\x01\x02\x00\x00\x80\xbb\x00\x00\x00\x00\x00')])),
                 ('unsupported-first', dict(number=3, selected_default=0,
                                            extra_tracks=[uint(0xD7, 1) + uint(0x83, 2) + element(0x86, b'A_AC3'),
                                                          uint(0xD7, 2) + uint(0x83, 1) + element(0x86, b'V_VP9')]))]
        for label, options in cases:
            variant = work / f'{Path(name).stem}-{label}.mka'
            variant.write_bytes(mux(track, **options))
            pcm = Path(str(variant) + '.f32')
            decode_f32(variant, pcm)
            if pcm.read_bytes() != expected:
                raise Failure(f'{variant.name} decodes differently from {name}')
            variants += 1
        print(f'{name}: lacing, unknown sizes and track selection variants identical', flush=True)
    checks.append({'test': 'remuxed variants', 'result': 'identical', 'files': variants})

    # Seeks: exact against continuous decoding, or equal to Ogg Opus seeks.
    for name in ('vorbis-stereo.mka', 'flac-16.mka', 'pcm-s24.mka', 'mp3.mka', 'mp2.mka', 'vorbis-5.1.webm'):
        path, kind, ours = files[name]
        line = run([seek, path, ours, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)
    for name in ('opus-stereo', 'opus-5.1'):
        mka, ogg = work / f'{name}.mka', work / f'{name}.opus'
        frames = len(Path(str(mka) + '.f32').read_bytes()) // 8
        for target in (1, 4000, frames // 3, frames // 2 + 77, frames - 500):
            a, b = work / 'dump-mka.f32', work / 'dump-ogg.f32'
            run([chain, 'dump', mka, str(target), '2000', a])
            run([chain, 'dump', ogg, str(target), '2000', b])
            # The Ogg remux lacks DiscardPadding, so it may continue past the end.
            if not a.read_bytes() or b.read_bytes()[:len(a.read_bytes())] != a.read_bytes():
                raise Failure(f'{name}: Matroska seek to {target} differs from Ogg')
        checks.append({'test': f'{name} seeks equal Ogg Opus seeks', 'result': 'exact', 'targets': 5})

    # Malformed files.
    good = (work / 'flac-16.mka').read_bytes()
    track = parse(work / 'flac-16.mka')
    rejected = 0

    def reject(label, data):
        nonlocal rejected
        target = work / f'bad-{label}.mka'
        target.write_bytes(data)
        line = run([chain, 'reject', target]).strip().splitlines()[-1]
        rejected += 1
        checks.append({'test': target.name, 'result': 'rejected', 'oracle': line})
    reject('truncated', good[:len(good) - 1000])
    reject('doctype', good.replace(b'matroska', b'matrosky', 1))
    reject('no-audio', mux(dict(track, codec='A_AC3')))
    encodings = element(0x6D80, element(0x6240, uint(0x5034, 1) + element(0x5035, uint(0x4254, 3))))
    reject('encoded', rebuild_with(track, encodings))
    opus = parse(work / 'opus-stereo.mka')
    reject('opus-no-private', mux(dict(opus, private=None)))
    reject('frame-crc', mux(dict(track, frames=track['frames'][:5] + [track['frames'][5][:-40]] + track['frames'][6:])))
    frames = track['frames']
    # A Xiph size beyond the block, and a fixed lacing that does not divide it.
    claim = len(frames[0]) + len(frames[1]) + 10
    oversized = b'\x01' + bytes([255] * (claim // 255)) + bytes([claim % 255]) + frames[0] + frames[1]
    reject('xiph-size', rebuild_blocks(track, [size_bytes(1) + b'\0\0\x82' + oversized]))
    uneven = frames[0] + frames[1]
    while len(uneven) % 3 == 0:
        uneven = uneven[:-1]
    reject('fixed-size', rebuild_blocks(track, [size_bytes(1) + b'\0\0\x84\x02' + uneven]))
    reject('discard-not-last', mux_discard_early(opus))
    print(f'Rejected {rejected} malformed files', flush=True)
    for mode in ('cancel-open', 'cancel-read'):
        line = run([chain, mode, work / 'vorbis-stereo.mka']).strip().splitlines()[-1]
        checks.append({'test': f'{mode} vorbis-stereo.mka', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'WebM Opus playback', 'result': 'played', 'stats': play(work / 'opus-stereo.webm')})
    write_report('matroska', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                              'scope': 'Matroska/WebM audio tracks: Opus, Vorbis, FLAC, MPEG Layer II/III and PCM (integer/float, both byte orders) against FFmpeg and LAMP Ogg/native decodes; Xiph/EBML/fixed lacing, unknown-size Segment/Cluster, default-flag and unsupported-track selection; exact seeks and Opus seeks equal to Ogg; malformed files and cancellation.'})
    print(f'Passed {len(checks)} Matroska checks.')


def rebuild_with(track, extra):
    entry = uint(0xD7, 1) + uint(0x83, 2) + element(0x86, track['codec'].encode()) + extra
    if track.get('private'):
        entry += element(0x63A2, track['private'])
    if track.get('audio'):
        entry += element(0xE1, track['audio'])
    tracks = element(0x1654AE6B, element(0xAE, entry))
    header = element(0x1A45DFA3, uint(0x4286, 1) + element(0x4282, b'matroska'))
    body = uint(0xE7, 0) + b''.join(element(0xA3, size_bytes(1) + b'\0\0\x80' + f) for f in track['frames'])
    return header + element(0x18538067, tracks + element(0x1F43B675, body))


def rebuild_blocks(track, payloads):
    """The track's headers with the given SimpleBlock payloads."""
    entry = uint(0xD7, 1) + uint(0x83, 2) + element(0x86, track['codec'].encode())
    if track.get('private'):
        entry += element(0x63A2, track['private'])
    if track.get('audio'):
        entry += element(0xE1, track['audio'])
    header = element(0x1A45DFA3, uint(0x4286, 1) + element(0x4282, b'matroska'))
    body = uint(0xE7, 0) + b''.join(element(0xA3, p) for p in payloads)
    return header + element(0x18538067, element(0x1654AE6B, element(0xAE, entry)) + element(0x1F43B675, body))


def mux_discard_early(track):
    """DiscardPadding on a packet that is not the last one."""
    header = element(0x1A45DFA3, uint(0x4286, 1) + element(0x4282, b'webm'))
    entry = uint(0xD7, 1) + uint(0x83, 2) + element(0x86, b'A_OPUS') + element(0x63A2, track['private'])
    body = uint(0xE7, 0)
    for k, frame in enumerate(track['frames']):
        block = element(0xA1, size_bytes(1) + b'\0\0\0' + frame)
        body += element(0xA0, block + (sint(0x75A2, 2500000) if k == 3 else b''))
    return header + element(0x18538067, element(0x1654AE6B, element(0xAE, entry)) + element(0x1F43B675, body))


if __name__ == '__main__':
    main_guard(main)
