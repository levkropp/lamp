#!/usr/bin/env python3
"""AVI audio streams.

usage: python3 tests/verify-avi.py [--skip-playback]
- From FFmpeg's muxer, with and without a video stream: PCM (8-32-bit
  integers, float32/64), G.711 and IMA/Microsoft ADPCM, mono and stereo,
  exact against FFmpeg; 5.1 and 7.1 PCM exact against the same audio in
  WAVE; MPEG Layer II/III and AC-3 exact against the raw streams and close
  to FFmpeg's float decoders; AAC exact against its ADTS copy and close to
  FFmpeg.
- Stream selection: the first audio stream LAMP decodes, past an unsupported
  one.
- Rewritten here: OpenDML files continuing in RIFF AVIX lists, LIST rec
  groups, JUNK chunks, audio re-cut into odd chunk sizes splitting ADPCM
  blocks and MPEG frames, AAC carried as ADTS without an AudioSpecificConfig
  and a file truncated inside an audio chunk.
- Seeks equal continuous decoding; malformed and unsupported files reject; a
  cancelled open stops cleanly.
Writes <out>/avi-verification.json.
"""
import array
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ac3_vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, stereo_view, write_report)


def ffmpeg_native(path, output, *options):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(path), *options,
                             '-f', 'f32le', str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = result.stdout.decode('utf-8', 'replace').strip()
    if result.returncode or text:
        raise Failure(f'FFmpeg on {Path(path).name}: {text[:300]}')
    return Path(output).read_bytes()


def snr(ours, reference):
    a, b = array.array('f', ours), array.array('f', reference)
    if len(a) != len(b):
        raise Failure(f'{len(a) // 2} frames, reference {len(b) // 2}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b) or 1.0
    return math.inf if error == 0 else 10 * math.log10(signal / error)


# ---------------------------------------------------------------- RIFF/AVI
def riff_chunks(data, pos, end):
    out = []
    while pos + 8 <= end:
        ident, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        out.append((ident, data[pos + 8:pos + 8 + size]))
        pos += 8 + size + (size & 1)
    return out


def chunk(ident, body):
    return ident + struct.pack('<I', len(body)) + body + (b'\0' if len(body) & 1 else b'')


def lst(form, body):
    return chunk(b'LIST', form + body)


def avi_parts(data):
    """An FFmpeg AVI file -> (hdrl payload after its form type, movi chunks)."""
    if data[:4] != b'RIFF' or data[8:12] != b'AVI ':
        raise Failure('not an AVI file')
    hdrl, movi = None, []
    for ident, body in riff_chunks(data, 12, len(data)):
        if ident == b'LIST' and body[:4] == b'hdrl':
            hdrl = body[4:]
        elif ident == b'LIST' and body[:4] == b'movi':
            movi += riff_chunks(body, 4, len(body))
    return hdrl, movi


def avi_file(hdrl, groups, rec=0, junk=False):
    """A RIFF AVI holding hdrl and the first group of movi chunks, then a RIFF
    AVIX per further group; rec wraps that many chunks in LIST rec groups."""
    out = b''
    for k, chunks in enumerate(groups):
        if rec:
            movi = b''.join(lst(b'rec ', b''.join(chunk(i, b) for i, b in chunks[j:j + rec]))
                            for j in range(0, len(chunks), rec))
        else:
            movi = b''.join(chunk(i, b) for i, b in chunks)
        body = lst(b'hdrl', hdrl) if k == 0 else b''
        if junk:
            body += chunk(b'JUNK', bytes(13)) + chunk(b'ISFT', b'test')
            movi = chunk(b'JUNK', bytes(7)) + movi
        out += chunk(b'RIFF', (b'AVI ' if k == 0 else b'AVIX') + body + lst(b'movi', movi))
    return out


def replace_strf(hdrl, stream, strf):
    """hdrl with stream's format chunk replaced."""
    out, number = b'', 0
    for ident, body in riff_chunks(hdrl, 0, len(hdrl)):
        if ident == b'LIST' and body[:4] == b'strl':
            if number == stream:
                body = b'strl' + b''.join(chunk(i, strf if i == b'strf' else b)
                                          for i, b in riff_chunks(body, 4, len(body)))
            number += 1
        out += chunk(ident, body)
    return out


def stream_format(hdrl, stream):
    number = 0
    for ident, body in riff_chunks(hdrl, 0, len(hdrl)):
        if ident == b'LIST' and body[:4] == b'strl':
            if number == stream:
                return dict(riff_chunks(body, 4, len(body)))[b'strf']
            number += 1
    raise Failure('no such stream')


def recut(movi, ident, sizes):
    """The stream's chunks re-cut into the cycle of sizes, one piece after
    each other chunk and the rest at the end."""
    audio = b''.join(b for i, b in movi if i == ident)
    others = [(i, b) for i, b in movi if i != ident]
    pieces, pos, k = [], 0, 0
    while pos < len(audio):
        pieces.append((ident, audio[pos:pos + sizes[k % len(sizes)]]))
        pos += sizes[k % len(sizes)]
        k += 1
    out = []
    for other in others:
        out.append(other)
        if pieces:
            out.append(pieces.pop(0))
    return out + pieces


def movi_audio(data, ident):
    """-> (offset of the stream's last chunk in the first movi list, its size,
    the stream's bytes)."""
    pos, total, last = 12, 0, None
    while pos + 8 <= len(data):
        size = struct.unpack_from('<I', data, pos + 4)[0]
        if data[pos:pos + 4] == b'LIST' and data[pos + 8:pos + 12] == b'movi':
            inner, end = pos + 12, pos + 8 + size
            while inner + 8 <= end:
                length = struct.unpack_from('<I', data, inner + 4)[0]
                if data[inner:inner + 4] == ident:
                    last, total = (inner, length), total + length
                inner += 8 + length + (length & 1)
            return last[0], last[1], total
        pos += 8 + size + (size & 1)
    raise Failure('no movi list')


def adts_frames(data):
    frames, pos = [], 0
    while pos + 7 <= len(data):
        if data[pos] != 0xff or data[pos + 1] & 0xf0 != 0xf0:
            raise Failure('ADTS sync')
        size = (data[pos + 3] & 3) << 11 | data[pos + 4] << 3 | data[pos + 5] >> 5
        frames.append(data[pos:pos + size])
        pos += size
    return frames


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('avi')
    checks = []

    def lamp(path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def source(rate, channels, duration, seed):
        tones = '|'.join(f'0.4*sin(2*PI*{89 * (k + 3) + seed}*t)*sin(2*PI*0.9*t+{k})+0.1*random({k})-0.05'
                         for k in range(channels))
        return ['-f', 'lavfi', '-i', f'aevalsrc={tones}:s={rate}:d={duration}']

    def video(duration):
        return ['-f', 'lavfi', '-i', f'testsrc=size=64x48:rate=25:duration={duration}']

    def exact(path, reference, comparator, note=''):
        ours, stats = lamp(path)
        if ours != reference:
            raise Failure(f'{path.name}: differs from {comparator}')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': comparator, 'note': note, 'stats': stats})
        print(f'{path.name}: exact against {comparator}', flush=True)
        return ours

    def against_ffmpeg(path, channels, *options):
        native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'), *options)
        return exact(path, stereo_view(native, channels, 0), 'FFmpeg')

    layouts = {1: 'mono', 2: 'stereo', 6: '5.1', 8: '7.1'}
    seed = 0

    # FFmpeg's muxer: audio alone and interleaved with video.
    for codec in ('pcm_u8', 'pcm_s16le', 'pcm_s24le', 'pcm_s32le', 'pcm_f32le', 'pcm_f64le', 'pcm_alaw',
                  'pcm_mulaw', 'adpcm_ima_wav', 'adpcm_ms'):
        for channels in (1, 2):
            seed += 1
            path = work / f'{codec}-{channels}.avi'
            ffmpeg(*source(44100 if channels == 2 else 22050, channels, 1, seed), '-c:a', codec, path)
            against_ffmpeg(path, channels)
        seed += 1
        path = work / f'{codec}-video.avi'
        ffmpeg(*video(2), *source(32000, 2, 2, seed), '-c:v', 'mjpeg', '-c:a', codec, path)
        against_ffmpeg(path, 2)
    seed += 1
    path = work / 'pcm_u8-odd.avi'
    ffmpeg(*video(1), *source(11025, 1, 1, seed), '-af', 'asetnsamples=n=1001:p=0', '-c:v', 'mjpeg',
           '-c:a', 'pcm_u8', path)
    against_ffmpeg(path, 1)
    for channels in (6, 8):
        seed += 1
        avi, wav = work / f'pcm-{layouts[channels]}.avi', work / f'pcm-{layouts[channels]}.wav'
        for target in (avi, wav):
            ffmpeg(*source(48000, channels, 1, seed), '-af', f'aformat=channel_layouts={layouts[channels]}',
                   '-c:a', 'pcm_s24le', target)
        reference, _ = lamp(wav)
        exact(avi, reference, f'the same audio in WAVE ({layouts[channels]})', 'extensible format')
    for name, coding, raw_format in (('mp2', ['-c:a', 'mp2', '-b:a', '192k'], 'mp2'),
                                     ('mp3', ['-c:a', 'libmp3lame', '-b:a', '160k'], 'mp3'),
                                     ('mp3-vbr', ['-c:a', 'libmp3lame', '-q:a', '2'], 'mp3'),
                                     ('ac3', ['-c:a', 'ac3', '-b:a', '192k'], 'ac3'),
                                     ('aac', ['-c:a', 'aac', '-b:a', '128k', '-aac_pns', '0'], 'adts')):
        seed += 1
        path = work / f'{name}.avi'
        ffmpeg(*video(2), *source(44100, 2, 2, seed), '-c:v', 'mjpeg', *coding, path)
        raw = work / f'{name}.{raw_format}'
        tags = ['-write_xing', '0', '-id3v2_version', '0'] if raw_format == 'mp3' else []
        ffmpeg('-i', path, '-c:a', 'copy', '-vn', *tags, '-f', raw_format, raw)
        reference, _ = lamp(raw)
        exact(path, reference, f'the raw {raw_format} stream')
        reference = Path(str(path) + '.ffmpeg.f32')
        decoder = {'mp2': ['-c:a', 'mp2float'], 'mp3': ['-c:a', 'mp3float']}.get(raw_format, [])
        ffmpeg('-cpuflags', '0', *decoder, '-i', path, '-f', 'f32le', reference)
        level = snr(Path(str(path) + '.f32').read_bytes(), reference.read_bytes())
        checks.append({'test': f'{path.name} against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})
        print(f'{path.name}: {level:.1f} dB against FFmpeg', flush=True)
        if level < 110:
            raise Failure(f'{path.name}: {level:.1f} dB against FFmpeg')

    # Stream selection.
    seed += 1
    path = work / 'second-stream.avi'
    ffmpeg(*video(1), *source(22050, 1, 1, seed), *source(44100, 2, 1, seed + 1), '-map', '0', '-map', '1',
           '-map', '2', '-c:v', 'mjpeg', '-c:a:0', 'adpcm_yamaha', '-c:a:1', 'pcm_s16le', path)
    against_ffmpeg(path, 2, '-map', '0:a:1')
    seed += 2
    path = work / 'first-stream.avi'
    ffmpeg(*source(44100, 2, 1, seed), *source(48000, 2, 1, seed + 1), '-map', '0', '-map', '1',
           '-c:a', 'pcm_s16le', path)
    against_ffmpeg(path, 2, '-map', '0:a:0')

    # Rewritten files.
    base = work / 'pcm_s16le-video.avi'
    hdrl, movi = avi_parts(base.read_bytes())
    reference, _ = lamp(base)
    third = len(movi) // 3
    for name, data, note in (
            ('opendml.avi', avi_file(hdrl, [movi[:third], movi[third:2 * third], movi[2 * third:]]),
             'RIFF AVI and two RIFF AVIX lists'),
            ('rec.avi', avi_file(hdrl, [movi], rec=3), 'LIST rec groups of three chunks'),
            ('junk.avi', avi_file(hdrl, [movi[:third], movi[third:]], rec=2, junk=True),
             'JUNK and unknown chunks, rec groups, an AVIX list'),
            ('pcm-recut.avi', avi_file(hdrl, [recut(movi, b'01wb', [777, 1, 3001, 64])]), 'odd chunk sizes')):
        path = work / name
        path.write_bytes(data)
        exact(path, reference, base.name, note)
        if name == 'opendml.avi':
            native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
            if native != reference:
                raise Failure('opendml.avi: differs from FFmpeg')
            checks.append({'test': 'opendml.avi against FFmpeg', 'result': 'exact'})
    for name, sizes in (('adpcm_ima_wav-video', [777, 5, 2048]), ('adpcm_ms-video', [1000, 3]),
                        ('mp3', [417, 1, 2000]), ('ac3', [500, 999])):
        base = work / f'{name}.avi'
        hdrl, movi = avi_parts(base.read_bytes())
        path = work / f'{name}-recut.avi'
        path.write_bytes(avi_file(hdrl, [recut(movi, b'01wb', sizes)]))
        exact(path, lamp(base)[0], base.name, f'chunks re-cut to {sizes} bytes')
    base = work / 'aac.avi'
    hdrl, movi = avi_parts(base.read_bytes())
    strf = stream_format(hdrl, 1)
    frames = adts_frames((work / 'aac.adts').read_bytes())
    audio = iter(frames)
    movi = [(i, next(audio) if i == b'01wb' else b) for i, b in movi]
    path = work / 'aac-adts.avi'
    path.write_bytes(avi_file(replace_strf(hdrl, 1, strf[:16] + b'\0\0'), [movi]))
    exact(path, lamp(work / 'aac.adts')[0], 'aac.adts', 'ADTS frames, no AudioSpecificConfig')

    full = work / 'pcm_s16le-2.avi'
    data = full.read_bytes()
    position, last, audio_bytes = movi_audio(data, b'00wb')
    path = work / 'truncated.avi'
    path.write_bytes(data[:position + 8 + 1001])
    kept = (audio_bytes - last + 1001) // 4
    exact(path, lamp(full)[0][:kept * 8], f'the first {kept} frames of {full.name}', 'cut inside the last audio chunk')

    # Seeks (FFmpeg's AC-3 is dithered, so a dither-free written stream
    # stands in for it).
    data, _ = ac3_vectors.stream(43, 60, 7, 1, dither=0.0)
    (work / 'written.ac3').write_bytes(data)
    ffmpeg(*video(2), '-i', work / 'written.ac3', '-c:v', 'mjpeg', '-c:a', 'copy', work / 'written-ac3.avi')
    exact(work / 'written-ac3.avi', lamp(work / 'written.ac3')[0], 'written.ac3', 'dither-free')
    for name in ('pcm_s16le-video.avi', 'pcm_alaw-2.avi', 'pcm_f64le-1.avi', 'adpcm_ima_wav-video.avi',
                 'adpcm_ms-2.avi', 'mp3.avi', 'mp3-vbr.avi', 'written-ac3.avi', 'aac.avi', 'aac-adts.avi', 'opendml.avi',
                 'pcm-5.1.avi', 'mp3-recut.avi'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0', '0', '0']).strip().splitlines()[-1]
        result = json.loads(line)
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {result["checks"]} checks', flush=True)

    # Rejections.
    data = (work / 'pcm_s16le-video.avi').read_bytes()
    hdrl, movi = avi_parts(data)
    strf = bytearray(stream_format(hdrl, 1))
    struct.pack_into('<H', strf, 12, 3)                   # block alignment
    seed += 1
    unsupported, silent = work / 'yamaha.avi', work / 'video-only.avi'
    ffmpeg(*source(22050, 2, 1, seed), '-c:a', 'adpcm_yamaha', unsupported)
    ffmpeg(*video(1), '-c:v', 'mjpeg', silent)
    bad = {
        'avi-movi-first.avi': (chunk(b'RIFF', b'AVI ' + lst(b'movi', b''.join(chunk(i, b) for i, b in movi)) +
                                     lst(b'hdrl', hdrl)), 100),
        'avi-no-movi.avi': (chunk(b'RIFF', b'AVI ' + lst(b'hdrl', hdrl)), 100),
        'avi-two-hdrl.avi': (chunk(b'RIFF', b'AVI ' + lst(b'hdrl', hdrl) + lst(b'hdrl', hdrl) +
                                   lst(b'movi', b'')), 100),
        'avi-hdrl-in-avix.avi': (chunk(b'RIFF', b'AVI ' + chunk(b'JUNK', b'')) +
                                 chunk(b'RIFF', b'AVIX' + lst(b'hdrl', hdrl) + lst(b'movi', b'')), 100),
        'avi-unsupported.avi': (unsupported.read_bytes(), 101),
        'avi-video-only.avi': (silent.read_bytes(), 101),
        'avi-rifx.avi': (b'RIFX' + data[4:], None),
        'avi-bad-align.avi': (avi_file(replace_strf(hdrl, 1, bytes(strf)), [movi]), None),
        'avi-truncated-header.avi': (data[:data.index(b'strf', data.index(b'auds'))], 101),
    }
    rejected = 0
    for name, (contents, code) in bad.items():
        (work / name).write_bytes(contents)
        line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
        result = json.loads(line)
        if result.get('result') != 'rejected' or (code is not None and result.get('decode_error') != code):
            raise Failure(f'{name}: expected a rejection ({code}), got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
        rejected += 1
    print(f'Rejected {rejected} malformed or unsupported files', flush=True)

    line = run([chain, 'cancel-open', work / 'opendml.avi']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open opendml.avi', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'AVI playback', 'result': 'played', 'stats': play(work / 'mp3.avi')})
    write_report('avi', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': 'AVI audio (PCM, float, G.711, IMA/Microsoft ADPCM, MPEG audio, AC-3, AAC) from '
                                  "FFmpeg's muxer and rewritten (OpenDML, rec groups, re-cut chunks, ADTS, "
                                  'truncation) against FFmpeg or equivalent files; stream selection; seeks; '
                                  'malformed and unsupported files; cancellation.'})
    print(f'Passed {len(checks)} AVI checks.')


if __name__ == '__main__':
    main_guard(main)
