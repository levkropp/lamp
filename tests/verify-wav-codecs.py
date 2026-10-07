#!/usr/bin/env python3
"""Compressed audio in WAVE and AIFF-C files against FFmpeg.

usage: python3 tests/verify-wav-codecs.py [--skip-playback]
- G.711 A-law and mu-law (WAVE tags 6 and 7, basic and extensible, and AIFF-C
  alaw/ulaw) from FFmpeg's encoders: exact against FFmpeg.
- IMA ADPCM (tag 0x11) and Microsoft ADPCM (tag 2) from FFmpeg's encoders at
  several rates and block sizes: exact against FFmpeg up to the fact chunk's
  sample count, which LAMP honors (FFmpeg plays the last block's padding).
- Random valid ADPCM streams from tests/adpcm_model.py, which FFmpeg's
  encoders cannot write: every Microsoft predictor, negative and large
  deltas, edge predictors and step indexes, small and odd block sizes, short final
  blocks and blocks too short for their headers. The model, FFmpeg and LAMP
  agree exactly. IMA with three to eight channels (beyond FFmpeg's decoder)
  is compared with the model through LAMP's speaker weights.
- MPEG Layer II and III (tags 0x50 and 0x55) and AC-3 (0x2000) copied into
  WAVE files decode exactly as LAMP decodes the raw streams, and close to
  FFmpeg's float decoders.
- Seeks equal continuous decoding; unsupported variants (1/6-bit IMA, more than
  two Microsoft ADPCM channels) and malformed files reject; invalid step
  indexes and predictors stop decoding; a cancelled open stops cleanly.
Writes <out>/wav-codecs-verification.json.
"""
import array
import json
import math
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ac3_vectors
import adpcm_model as model
from lamp_test import (Failure, build_lamp, build_oracles, check_file, decode_f32, exe, ffmpeg, main_guard, out_dir,
                       play, playback_requested, run, scratch, stereo_view, write_report)


def ffmpeg_native(path, output, tolerated=()):
    """FFmpeg's decode -> float32 bytes; fails on any message but the
    tolerated ones."""
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(path), '-f', 'f32le',
                             str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = '\n'.join(line for line in result.stdout.decode('utf-8', 'replace').strip().splitlines()
                     if not any(t in line for t in tolerated))
    if result.returncode or text:
        raise Failure(f'FFmpeg on {Path(path).name}: {text[:300]}')
    return Path(output).read_bytes()


def int16_floats(samples):
    return struct.pack(f'<{len(samples)}f', *[v / 32768.0 for v in samples])


def snr(ours, reference):
    a, b = array.array('f', ours), array.array('f', reference)
    if len(a) != len(b):
        raise Failure(f'{len(a) // 2} frames, reference {len(b) // 2}')
    error = sum((x - y) ** 2 for x, y in zip(a, b))
    signal = sum(y * y for y in b) or 1.0
    return math.inf if error == 0 else 10 * math.log10(signal / error)


def fmt_of(data):
    pos = 12
    while pos + 8 <= len(data):
        ident, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        if ident == b'fmt ':
            return data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    raise Failure('no fmt chunk')


def fact_of(data):
    pos = 12
    while pos + 8 <= len(data):
        ident, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        if ident == b'fact':
            return struct.unpack_from('<I', data, pos + 8)[0]
        pos += 8 + size + (size & 1)
    return None


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    run([sys.executable, Path(__file__).resolve().parent / 'generate-adpcm-tables.py', '--check'])
    work = scratch('wav-codecs')
    checks = []

    def lamp(path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def source(rate, channels, duration, seed):
        tones = '|'.join(f'0.45*sin(2*PI*{97 * (k + 3) + seed}*t)*sin(2*PI*0.7*t+{k})+0.1*random({k})-0.05'
                         for k in range(channels))
        return ['-f', 'lavfi', '-i', f'aevalsrc={tones}:s={rate}:d={duration}']

    # FFmpeg's encoders.
    layouts = {1: 'mono', 2: 'stereo', 6: '5.1', 8: '7.1'}
    encoded = []
    for codec in ('pcm_alaw', 'pcm_mulaw'):
        for rate, channels in ((8000, 1), (44100, 2), (48000, 6), (22050, 8)):
            encoded.append((f'{codec}-{channels}ch-{rate}.wav', rate, channels, [codec]))
        for rate, channels in ((8000, 1), (44100, 2)):
            encoded.append((f'{codec}-{channels}ch-{rate}.aiff', rate, channels, [codec]))
    for codec in ('adpcm_ima_wav', 'adpcm_ms'):
        for rate, channels, block in ((8000, 1, 256), (22050, 1, 512), (44100, 2, 1024), (48000, 2, 2048),
                                      (11025, 2, 32), (96000, 1, 8192)):
            encoded.append((f'{codec}-{channels}ch-{rate}-{block}.wav', rate, channels,
                            [codec, '-block_size', str(block)]))
    for k, (name, rate, channels, coding) in enumerate(encoded):
        path = work / name
        ffmpeg(*source(rate, channels, 2, k), '-af', f'aformat=channel_layouts={layouts[channels]}', '-c:a', *coding,
               path)
        data = path.read_bytes()
        native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
        ours, stats = lamp(path)
        if name.endswith('.wav'):
            fmt = fmt_of(data)
            tag = struct.unpack_from('<H', fmt)[0]
            mask = struct.unpack_from('<I', fmt, 20)[0] if tag == 0xfffe else 0
            if tag == 0xfffe:
                tag = struct.unpack_from('<H', fmt, 24)[0]           # the subformat
        else:
            tag, mask = 'aiff', 0
        frames = fact_of(data) if tag in (2, 0x11) else None
        reference = stereo_view(native, channels, mask)
        if frames is not None:
            reference = reference[:frames * 8]
        if ours != reference:
            raise Failure(f'{name}: differs from FFmpeg')
        checks.append({'test': name, 'result': 'exact', 'comparator': 'FFmpeg' + (' up to the fact count'
                       if frames is not None else '') + (' channels mixed with LAMP weights' if channels > 2 else ''),
                       'format_tag': tag, 'stats': stats})
        print(f'{name}: exact', flush=True)

    # Random ADPCM streams: the model, FFmpeg and LAMP.
    r = random.Random(11)
    written = [
        ('ima-3ch', 0x11, 3, 32000, 12 * 3 * 16 + 12, 6, 0),
        ('ima-4ch', 0x11, 4, 44100, 16 * 32 + 16, 5, 0),
        ('ima-5ch', 0x11, 5, 48000, 20 * 8 + 20, 7, 0),
        ('ima-6ch', 0x11, 6, 48000, 24 * 20 + 24, 4, 0),
        ('ima-7ch', 0x11, 7, 44100, 28 * 9 + 28, 4, 0),
        ('ima-8ch', 0x11, 8, 96000, 32 * 30 + 32, 3, 0),
        ('ima-mono-small-block', 0x11, 1, 8000, 4 + 4 * 3, 40, 0),
        ('ima-stereo-short-final', 0x11, 2, 22050, 8 + 8 * 60, 5, 8 + 8 * 7 + 5),
        ('ima-stereo-header-only-final', 0x11, 2, 22050, 8 + 8 * 60, 5, 6),   # dropped: shorter than the headers
        ('ima-edges', 0x11, 1, 44100, 4 + 4 * 200, 12, 0),
        ('ms-mono', 0x02, 1, 8000, 7 + 249, 14, 0),
        ('ms-stereo', 0x02, 2, 44100, 14 + 1010, 14, 0),
        ('ms-mono-short-final', 0x02, 1, 22050, 7 + 500, 7, 7 + 33),
        ('ms-stereo-short-final', 0x02, 2, 48000, 14 + 2034, 7, 14 + 7),
        ('ms-stereo-header-only-final', 0x02, 2, 48000, 14 + 200, 7, 9),
    ]
    for name, tag, channels, rate, align, blocks, partial in written:
        make = model.random_ima if tag == 0x11 else model.random_ms
        data = make(r, channels, align, blocks, partial)
        used = set()
        expected = []
        for start in range(0, len(data), align):
            block = data[start:start + align]
            if len(block) < (4 if tag == 0x11 else 7) * channels:
                break
            chans = (model.ima_block if tag == 0x11 else model.ms_block)(block, channels, used)
            for i in range(len(chans[0])):
                expected += [c[i] for c in chans]
        frames = len(expected) // channels
        for suffix, fact in (('', None), ('-fact', frames - r.randint(1, 40))):
            path = work / f'{name}{suffix}.wav'
            path.write_bytes(model.wave(tag, channels, rate, align, data, fact))
            native = int16_floats(expected)
            # A short final block's partial sample group is left over in
            # FFmpeg's packet, which it then reports as invalid.
            tolerated = ('invalid number of samples in packet', 'Invalid data found') if partial else ()
            if channels <= 2:                              # FFmpeg's IMA WAV decoder stops at two
                if ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'), tolerated) != native:
                    raise Failure(f'{path.name}: FFmpeg differs from the model')
            ours, stats = lamp(path)
            reference = stereo_view(native, channels, 0)
            if fact is not None:
                reference = reference[:fact * 8]
            if ours != reference:
                raise Failure(f'{path.name}: LAMP differs from the model')
            checks.append({'test': path.name, 'result': 'exact', 'channels': channels,
                           'comparator': 'model and FFmpeg' if channels <= 2 else 'model (channels mixed with LAMP weights)',
                           'block_align': align, 'stats': stats,
                           ('step_indexes' if tag == 0x11 else 'predictors'): len(used)})
        print(f'{name}: exact ({len(used)} {"step indexes" if tag == 0x11 else "predictors"})', flush=True)
    steps = set()
    for name in ('ima-edges', 'ima-8ch', 'ima-6ch'):
        data = (work / f'{name}.wav').read_bytes()
        fmt = fmt_of(data)
        channels, align = struct.unpack_from('<H', fmt, 2)[0], struct.unpack_from('<H', fmt, 12)[0]
        body = data[data.index(b'data') + 8:]
        for start in range(0, len(body) - align + 1, align):
            model.ima_block(body[start:start + align], channels, steps)
    if len(steps) != 89:
        raise Failure(f'only {len(steps)} IMA step indexes used')
    checks.append({'test': 'IMA step coverage', 'result': 'passed', 'step_indexes': len(steps)})

    # MPEG audio and AC-3 in WAVE files.
    raw = {'mp2': ['-c:a', 'mp2', '-b:a', '192k', '-f', 'mp2'],
           'mp3': ['-c:a', 'libmp3lame', '-b:a', '160k', '-write_xing', '0', '-id3v2_version', '0', '-f', 'mp3'],
           'ac3': ['-c:a', 'ac3', '-b:a', '192k', '-f', 'ac3']}
    float_decoder = {'mp2': 'mp2float', 'mp3': 'mp3float'}
    for k, (name, coding) in enumerate(raw.items()):
        stream = work / f'stream.{name}'
        ffmpeg(*source(44100, 2, 3, 40 + k), *coding, stream)
        wav = work / f'{name}-in-wav.wav'
        ffmpeg('-i', stream, '-c', 'copy', '-f', 'wav', wav)
        ours, stats = lamp(wav)
        plain, _ = lamp(stream)
        if ours != plain:
            raise Failure(f'{wav.name}: differs from the raw stream')
        tag = struct.unpack_from('<H', fmt_of(wav.read_bytes()))[0]
        reference = Path(str(wav) + '.ffmpeg.f32')
        decoder = ['-c:a', float_decoder[name]] if name in float_decoder else []
        ffmpeg('-cpuflags', '0', *decoder, '-i', wav, '-f', 'f32le', reference)
        level = snr(ours, reference.read_bytes())
        if level < 110:
            raise Failure(f'{wav.name}: {level:.1f} dB against FFmpeg')
        checks.append({'test': wav.name, 'result': 'exact', 'comparator': f'raw .{name} stream', 'format_tag': tag,
                       'ffmpeg_snr_db': round(level, 1), 'stats': stats})
        print(f'{wav.name}: exact against the raw stream, {level:.1f} dB against FFmpeg', flush=True)

    # Seeks (exact: FFmpeg's AC-3 is dithered, so a dither-free written stream
    # stands in for it).
    data, _ = ac3_vectors.stream(42, 60, 7, 1, dither=0.0)
    (work / 'written.ac3').write_bytes(data)
    ffmpeg('-i', work / 'written.ac3', '-c', 'copy', '-f', 'wav', work / 'written-ac3-in-wav.wav')
    lamp(work / 'written-ac3-in-wav.wav')
    for name in ('adpcm_ima_wav-2ch-44100-1024.wav', 'adpcm_ms-1ch-22050-512.wav', 'ima-6ch-fact.wav',
                 'pcm_alaw-2ch-44100.wav', 'pcm_mulaw-1ch-8000.aiff', 'mp3-in-wav.wav', 'written-ac3-in-wav.wav'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Rejections.
    base = (work / 'adpcm_ima_wav-2ch-44100-1024.wav').read_bytes()
    ms = (work / 'adpcm_ms-1ch-22050-512.wav').read_bytes()
    alaw = (work / 'pcm_alaw-2ch-44100.wav').read_bytes()

    def patch(data, offset, fmt, value):
        data = bytearray(data)
        struct.pack_into(fmt, data, offset, value)
        return bytes(data)

    fmt_at = base.index(b'fmt ') + 8
    ms_fmt = ms.index(b'fmt ') + 8
    alaw_fmt = alaw.index(b'fmt ') + 8
    data_at = base.index(b'data') + 8
    ms_data = ms.index(b'data') + 8
    stereo_ms = model.wave(2, 2, 44100, 1024, model.random_ms(r, 2, 1024, 2))
    three_ms = bytearray(model.wave(2, 2, 44100, 1024, model.random_ms(r, 2, 1024, 2)))
    struct.pack_into('<H', three_ms, three_ms.index(b'fmt ') + 10, 3)
    extensible = bytearray(base)
    struct.pack_into('<H', extensible, fmt_at, 0xfffe)
    unsupported = {'ima-1-bit.wav': patch(base, fmt_at + 14, '<H', 1), 'ms-3-channels.wav': bytes(three_ms),
                   'ima-6-bit.wav': patch(base, fmt_at + 14, '<H', 6)}
    malformed = {'ima-no-channels.wav': patch(base, fmt_at + 2, '<H', 0),
                 'ima-no-block.wav': patch(base, fmt_at + 12, '<H', 0),
                 'ima-extensible.wav': bytes(extensible),
                 'alaw-16-bit.wav': patch(alaw, alaw_fmt + 14, '<H', 16),
                 'ima-header-only.wav': model.wave(0x11, 2, 44100, 1024, bytes(6)),
                 'mp3-garbage.wav': patch(base, fmt_at, '<H', 0x55)}
    rejected = 0
    for group, files in (('unsupported', unsupported), ('malformed', malformed)):
        for name, data in files.items():
            (work / name).write_bytes(data)
            line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
            result = json.loads(line)
            if result.get('result') != 'rejected' or (group == 'unsupported' and result.get('decode_error') != 101):
                raise Failure(f'{name}: expected a {group} rejection, got {line}')
            checks.append({'test': name, 'result': 'rejected', 'oracle': line})
            rejected += 1
    # Invalid block headers stop decoding where they occur.
    stopped = {'ima-step-index.wav': patch(base, data_at + 1024 * 3 + 2, '<h', 89),
               'ms-predictor.wav': patch(ms, ms_data + 512 * 2, '<B', 7),
               'ms-stereo-predictor.wav': patch(stereo_ms, stereo_ms.index(b'data') + 8 + 1024 + 1, '<B', 9)}
    for name, data in stopped.items():
        (work / name).write_bytes(data)
        code, stats = check_file(work / name)
        if not code or 'decode_error=100' not in stats:
            raise Failure(f'{name}: expected decode_error 100, got {code} {stats}')
        checks.append({'test': name, 'result': 'stopped', 'stats': stats.splitlines()[-1]})
        rejected += 1
    print(f'Rejected {rejected} unsupported, malformed or damaged files', flush=True)

    line = run([chain, 'cancel-open', work / 'adpcm_ms-1ch-96000-8192.wav']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open adpcm_ms-1ch-96000-8192.wav', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'IMA ADPCM playback', 'result': 'played',
                       'stats': play(work / 'adpcm_ima_wav-2ch-44100-1024.wav')})
    write_report('wav-codecs', {'result': 'passed', 'checks': checks, 'encoder_files': len(encoded),
                                'written_streams': 2 * len(written), 'rejections': rejected,
                                'scope': 'G.711 A-law/mu-law in WAVE and AIFF-C, IMA and Microsoft ADPCM in WAVE, '
                                         'MPEG audio and AC-3 in WAVE: exact against FFmpeg (ADPCM up to the fact '
                                         'count) and the ADPCM model; seeks; unsupported and malformed files; '
                                         'cancellation.'})
    print(f'Passed {len(checks)} compressed WAVE/AIFF-C checks.')


if __name__ == '__main__':
    main_guard(main)
