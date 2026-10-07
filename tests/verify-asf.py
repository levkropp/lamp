#!/usr/bin/env python3
"""ASF audio PCM, packet framing, audio ordinals, seeks and cancellation.

--prepare-only creates FFmpeg and independent packet-writer fixtures.
--wine-only checks the same fixtures using shipping COFF objects after a
native run. Media and reports stay in ignored generated/build directories.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import struct
import sys
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg, ffmpeg_version,
                       lamp_cli, main_guard, out_dir, play, playback_requested, run,
                       scratch, stereo_view, write_report)


def guid(value): return uuid.UUID(value).bytes_le
HEADER = guid('75b22630-668e-11cf-a6d9-00aa0062ce6c')
FILE = guid('8cabdca1-a947-11cf-8ee4-00c00c205365')
STREAM = guid('b7dc0791-a9b7-11cf-8ee6-00c00c205365')
AUDIO = guid('f8699e40-5b4d-11cf-a8fd-00805f5c442b')
DATA = guid('75b22636-668e-11cf-a6d9-00aa0062ce6c')
EXT = guid('5fbf03b5-a92e-11cf-8ee3-00c00c205365')
NONE = guid('20fb5700-5b55-11cf-a8fd-00805f5c442b')
ENCRYPT = guid('2211b3fb-bd23-11d2-b4b7-00a0c955fc6e')
IDENT = bytes(range(16))


def obj(key, body): return key + struct.pack('<Q', len(body) + 24) + body
def field(value, width): return value.to_bytes((0, 1, 2, 4)[width], 'little') if width else b''


def payload(data, number=0, offset=0, size=None, stream=1, replic=8):
    return dict(data=data, number=number, offset=offset, size=len(data) if size is None else size,
                stream=stream, replic=replic)


def packet(items, length=2, sequence=1, padding=2, number=1, offset=3, replic=1,
           payload_length=2, physical=512, ecc=True, multi=True, logical=None):
    """Independent serializer. Uses every ASF length code; padding is explicit.
    The media-object bytes are known before ASF framing is added.
    """
    logical = physical if logical is None else logical
    flags = length << 5 | sequence << 1 | padding << 3 | int(multi)
    properties = 0x40 | number << 4 | offset << 2 | replic
    prefix = (b'\x82\0\0' if ecc else b'') + bytes([flags, properties])
    prefix += field(logical, length) + field(0, sequence)
    head_bytes = len(prefix) + (0, 1, 2, 4)[padding] + 6 + int(multi)
    body = b''
    for item in items:
        rep = item['replic']
        body += bytes([item['stream'] | 0x80]) + field(item['number'], number)
        body += field(item['offset'], offset) + field(rep, replic)
        if rep >= 8: body += struct.pack('<II', item['size'], 0) + bytes(rep - 8)
        elif rep == 1: body += b'\x01'
        if multi: body += field(len(item['data']), payload_length)
        body += item['data']
    pad = logical - head_bytes - len(body)
    if pad < 0 or (pad and not padding): raise ValueError('Packet does not fit')
    prefix += field(pad, padding) + bytes(6)
    if multi: prefix += bytes([len(items) | payload_length << 6])
    return prefix + body + bytes(pad) + bytes(physical - logical)


def stream(fmt, ident=1, encrypted=False, span=1):
    # Eight spreading bytes are carried despite a zero error-data length,
    # as FFmpeg's muxer writes them. Span 1 is already in byte order.
    body = AUDIO + NONE + bytes(8) + struct.pack('<IIHI', len(fmt), 0, ident | (0x8000 if encrypted else 0), 0)
    return obj(STREAM, body + fmt + struct.pack('<BHHHB', span, 1, 1, 1, 0))


def asf(streams, packets, minimum=512, maximum=None, extra=(), broadcast=False):
    maximum = minimum if maximum is None else maximum
    props = IDENT + bytes(16) + struct.pack('<QQQQIIII', len(packets), 10000000, 10000000, 0,
                                          1 if broadcast else 2, minimum, maximum, 768000)
    children = [obj(FILE, props), obj(EXT, NONE + struct.pack('<HI', 6, 0)), *streams, *extra]
    children_bytes = b''.join(children)
    header = HEADER + struct.pack('<QI', len(children_bytes) + 30, len(children)) + b'\x01\x02' + children_bytes
    data = obj(DATA, IDENT + struct.pack('<Q', 0 if broadcast else len(packets)) + b'\x01\x01' + b''.join(packets))
    result = bytearray(header + data)
    struct.pack_into('<Q', result, 30 + 40, len(result))
    if broadcast: struct.pack_into('<Q', result, len(header) + 16, 0)
    return bytes(result)


def wave_parts(data):
    pos, parts = 12, {}
    while pos + 8 <= len(data):
        size = struct.unpack_from('<I', data, pos + 4)[0]
        parts[data[pos:pos + 4]] = data[pos + 8:pos + 8 + size]
        pos += 8 + size + size % 2
    return parts[b'fmt '], parts[b'data']


def untrimmed_wave(path):
    # ASF has no WAVE fact count. FFmpeg's stream copy estimates that field
    # from millisecond timestamps (for example 44091 for 44100 float frames).
    # Preserve the exact fmt/data bytes while removing this invented trim.
    fmt, data = wave_parts(path.read_bytes())
    body = b'fmt ' + struct.pack('<I', len(fmt)) + fmt + bytes(len(fmt) % 2)
    body += b'data' + struct.pack('<I', len(data)) + data + bytes(len(data) % 2)
    path.write_bytes(b'RIFF' + struct.pack('<I', len(body) + 4) + b'WAVE' + body)


def source(path, channels=2, rate=44100, frames=44100, seed=73):
    rng = random.Random(seed)
    values = [int(12000 * math.sin((i // channels) * (0.017 + i % channels * 0.011))) + rng.randrange(-700, 701)
              for i in range(frames * channels)]
    data = struct.pack('<' + 'h' * len(values), *values)
    fmt = struct.pack('<HHIIHH', 1, channels, rate, rate * channels * 2, channels * 2, 16)
    path.write_bytes(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<I', 16) + fmt +
                     b'data' + struct.pack('<I', len(data)) + data)
    return fmt, data


def writer_hash():
    return hashlib.sha256(Path(__file__).read_bytes().split(b'def main():')[0]).hexdigest()


def prepare(work):
    files, rejects = [], []

    def add(name, data, note, channels=2, choice=0, count=1, selected=1, wave=None, comparator=True):
        path = work / name
        if data is not None: path.write_bytes(data)
        if comparator:
            ref = work / (name + '.ffmpeg.f32')
            decoder = ['-c:a', 'mp2float'] if name.startswith('mp2-') else []
            ffmpeg(*decoder, '-i', path, '-map', f'0:a:{selected - 1}', '-af', 'asetpts=N', '-f', 'f32le', ref)
            ref.write_bytes(stereo_view(ref.read_bytes(), channels, 0))
        files.append(dict(name=name, note=note, channels=channels, choice=choice, count=count,
                          selected=selected, wave=wave, ffmpeg=comparator))

    codecs = [('pcm_u8', 1), ('pcm_s16le', 1), ('pcm_s16le', 2), ('pcm_s24le', 2), ('pcm_s32le', 2),
              ('pcm_f32le', 2), ('pcm_f64le', 1), ('pcm_alaw', 1), ('pcm_alaw', 2), ('pcm_mulaw', 2),
              ('adpcm_ima_wav', 1), ('adpcm_ima_wav', 2), ('adpcm_ms', 1), ('adpcm_ms', 2),
              ('mp2', 2), ('libmp3lame', 2), ('ac3', 2), ('aac', 2)]
    for i, (codec, channels) in enumerate(codecs):
        rate = 8000 if codec in ('pcm_alaw', 'pcm_mulaw') else 44100
        original = work / f'source-{i}.wav'
        source(original, channels, rate, rate, 73 + i)
        name = f'{codec}-{channels}.asf'
        options = ['-b:a', '128k'] if codec in ('mp2', 'libmp3lame', 'ac3', 'aac') else []
        if codec == 'aac': options += ['-aac_pns', '0']
        ffmpeg('-i', original, '-c:a', codec, *options, work / name)
        copy = work / (name + ('.aac' if codec == 'aac' else '.wav'))
        ffmpeg('-i', work / name, '-map', '0:a:0', '-c:a', 'copy', copy)
        if codec != 'aac': untrimmed_wave(copy)
        add(name, None, 'FFmpeg ASF muxer, stream-copy WAVE comparison', channels, wave=copy.name)
    for channels in (6, 8):
        original = work / f'source-{channels}ch.wav'
        source(original, channels, 48000, 48000)
        name = f'pcm-{channels}ch.asf'
        ffmpeg('-i', original, '-c:a', 'pcm_s24le', work / name)
        add(name, None, 'extensible WAVEFORMATEX and existing stereo mixing', channels, wave=original.name)
    for codec in ('pcm_s16le', 'libmp3lame'):
        if codec == 'pcm_s16le':
            import ac3_vectors
            coded, _ = ac3_vectors.stream(8251, 40, 2, 0, dither=0.0)
            raw = work / 'dither-free.ac3'; raw.write_bytes(coded)
            name = 'ac3-dither-free.asf'
            ffmpeg('-i', raw, '-c:a', 'copy', work / name)
            copy = work / (name + '.wav')
            ffmpeg('-i', work / name, '-c:a', 'copy', copy); untrimmed_wave(copy)
            add(name, None, 'dither-free AC-3, exact continuous-output seeks', wave=copy.name)
        name = codec + '-video.asf'
        ffmpeg('-i', work / 'source-2.wav', '-f', 'lavfi', '-i', 'color=s=64x48:r=25:d=1',
               '-c:a', codec, '-c:v', 'wmv2', '-shortest', work / name)
        copy = work / (name + '.wav')
        ffmpeg('-i', work / name, '-map', '0:a:0', '-c:a', 'copy', copy)
        untrimmed_wave(copy)
        add(name, None, 'WMV2 video skipped; interleaved packet payloads', wave=copy.name)

    fmt, pcm = source(work / 'packet-source.wav', frames=4410)
    parts = [pcm[i:i + 1200] for i in range(0, len(pcm), 1200)]
    # The same known PCM appears in fragmented and compressed packet layouts.
    variants = []
    for width in (1, 2, 3):
        small = [pcm[i:i + 100] for i in range(0, len(pcm), 100)]
        packets = [packet([payload(d, k)], length=width, sequence=width, padding=width, number=width,
                          offset=width, replic=width, payload_length=width, physical=240)
                   for k, d in enumerate(small)]
        variants.append((f'fields-{width}.asf', packets, 240, 240))
    for number, opts in enumerate((dict(ecc=False), dict(multi=False), dict(length=0, sequence=0, offset=0),
                                   dict(logical=240, physical=512))):
        small = [pcm[i:i + 128] for i in range(0, len(pcm), 128)]
        packets = [packet([payload(d, k, replic=0 if opts.get('replic') == 0 else 8)], **opts)
                   for k, d in enumerate(small)]
        physical = opts.get('physical', 512)
        variants.append((f'layout-{number}.asf', packets, physical, physical))
    # Object number wraps without breaking continuity; unaligned fragments
    # split PCM samples. Replicated-data-free continuations retain the size.
    packets = []
    for k, d in enumerate(parts):
        splits = [d[:3], d[3:401], d[401:]]
        off = 0
        for n, piece in enumerate(splits):
            packets.append(packet([payload(piece, (254 + k) & 255, off, len(d), replic=8 if n == 0 else 0)],
                                  physical=1024, replic=1 if n == 0 else 0))
            off += len(piece)
    variants.append(('fragments.asf', packets, 1024, 1024))
    packets = []
    small = [pcm[i:i + 100] for i in range(0, len(pcm), 100)]
    for i in range(0, len(small), 3):
        body = b''.join(bytes([len(d)]) + d for d in small[i:i + 3])
        packets.append(packet([payload(body, i & 255, replic=1)]))
    variants.append(('compressed-objects.asf', packets, 512, 512))
    packets = [packet([payload(d, k)], physical=1280 if len(d) > 430 else 512)
               for k, d in enumerate(parts)]
    variants.append(('variable-packets.asf', packets, 512, 1280))
    for name, packets, minimum, maximum in variants:
        add(name, asf([stream(fmt)], packets, minimum, maximum), 'independent ASF writer, known PCM',
            wave='packet-source.wav')
    base_packets = [packet([payload(d, k)]) for k, d in enumerate([pcm[i:i + 128] for i in range(0, len(pcm), 128)])]
    base = asf([stream(fmt)], base_packets)
    add('broadcast.asf', asf([stream(fmt)], base_packets, broadcast=True), 'unknown object length/count in broadcast header', wave='packet-source.wav')
    nested = obj(EXT, NONE + struct.pack('<HI', 6, len(stream(fmt))) + stream(fmt))
    add('nested-stream.asf', asf([], base_packets, extra=[nested]), 'Stream Properties in bounded Header Extension', wave='packet-source.wav')
    add('Unicode-音楽-Ω.asf', base, 'Unicode path', wave='packet-source.wav')
    unsupported = bytearray(fmt); struct.pack_into('<H', unsupported, 0, 0x161)
    catalog_streams = [stream(bytes(unsupported), k) for k in range(1, 127)] + [stream(fmt, 127)]
    high_packets = [packet([payload(pcm[i:i + 128], k, stream=127)]) for k, i in enumerate(range(0, len(pcm), 128))]
    high = asf(catalog_streams, high_packets)
    for choice in (0, 127):
        add(f'catalog127-choice{choice}.asf', high, '127 legal stream IDs; unsupported format placeholders count',
            choice=choice, count=127, selected=127, wave='packet-source.wav', comparator=False)
    add('skip-encrypted-stream.asf', asf([stream(fmt, 2, encrypted=True), stream(fmt)], base_packets),
        'automatic choice skips encrypted audio but counts it', count=2, selected=2,
        wave='packet-source.wav', comparator=False)

    # Real unsupported WMA followed by PCM and MP3, rather than fake codec data.
    name = 'multitrack.asf'
    ffmpeg('-i', work / 'source-2.wav', '-map', '0:a:0', '-map', '0:a:0', '-map', '0:a:0',
           '-c:a:0', 'wmav2', '-c:a:1', 'pcm_s16le', '-c:a:2', 'libmp3lame', work / name)
    for choice, selected in ((0, 2), (2, 2), (3, 3)):
        alias = f'multitrack-choice{choice}.asf'
        copy = work / (alias + '.wav')
        ffmpeg('-i', work / name, '-map', f'0:a:{selected - 1}', '-c:a', 'copy', copy)
        untrimmed_wave(copy)
        add(alias, (work / name).read_bytes(), 'audio ordinal includes unsupported WMA', choice=choice,
            count=3, selected=selected, wave=copy.name)

    def reject(name, data, error=100, choice=0):
        (work / name).write_bytes(data)
        rejects.append(dict(name=name, error=error, choice=choice))

    header_end = struct.unpack_from('<Q', base, 16)[0]
    for cut in (12, 16, 23, 29, 30, header_end - 1, header_end + 49, len(base) - 1):
        reject(f'truncated-{cut}.asf', base[:cut])
    for off, value in ((16, 29), (16, 2**64 - 1), (46, 23), (46, 2**64 - 1),
                       (header_end + 16, 49), (header_end + 16, 2**64 - 1), (header_end + 40, 1)):
        data = bytearray(base); struct.pack_into('<Q', data, off, value)
        reject(f'bad-size-{off}-{value}.asf', data)
    data = bytearray(base); struct.pack_into('<I', data, 24, 1)
    reject('header-object-count.asf', data)
    data = bytearray(base); data[29] = 0
    reject('header-reserved.asf', data)
    reject('header-object-limit.asf', asf([stream(fmt)], base_packets, extra=[obj(bytes(16), b'')] * 4094), 101)
    nested = stream(fmt)
    for _ in range(5): nested = obj(EXT, NONE + struct.pack('<HI', 6, len(nested)) + nested)
    reject('header-depth-limit.asf', asf([], base_packets, extra=[nested]))
    good_packet = bytearray(packet([payload(b'abcd')]))
    for name, at, value in (('zero-packet-length', 5, b'\0\0'), ('oversize-packet', 5, b'\xff\xff'),
                             ('padding-overrun', 8, b'\xff\xff'), ('zero-payload-count', 16, b'\x80'),
                             ('stream-field-type', 4, b'\x15')):
        changed = bytearray(good_packet); changed[at:at + len(value)] = value
        reject(name + '.asf', asf([stream(fmt)], [bytes(changed)]))
    for name, items in (
        ('orphan-fragment', [payload(b'abcd', offset=4, size=8)]),
        ('unknown-object-size', [payload(b'abcd', replic=0)]),
        ('incomplete-object', [payload(b'abcd', size=8)]),
        ('object-overrun', [payload(b'abcdefgh', size=4)]),
        ('zero-object', [payload(b'abcd', size=0)]),
        ('huge-object', [payload(b'abcd', size=2**32 - 1)]),
        ('bad-compressed', [payload(b'\x05ab', replic=1)]),
        ('zero-compressed', [payload(b'\0', replic=1)]),
        ('replicated-size2', [payload(b'abcd', replic=2)])):
        reject(name + '.asf', asf([stream(fmt)], [packet(items)]))
    for name, second in (('gap', payload(b'efgh', offset=5, size=8)),
                         ('number', payload(b'efgh', number=1, offset=4, size=8)),
                         ('changed-size', payload(b'efgh', offset=4, size=9))):
        reject(name + '.asf', asf([stream(fmt)], [packet([payload(b'abcd', size=8)]), packet([second])]))
    reject('duplicate-id.asf', asf([stream(fmt), stream(fmt)], base_packets))
    reject('zero-stream.asf', asf([stream(fmt, ident=0)], base_packets))
    reject('encrypted.asf', asf([stream(fmt)], base_packets, extra=[obj(ENCRYPT, bytes(16))]), 101)
    reject('encrypted-stream.asf', asf([stream(fmt, encrypted=True)], base_packets), 101)
    reject('scrambled.asf', asf([stream(fmt, span=2)], base_packets), 101)
    reject('format-private-limit.asf', asf([stream(fmt + bytes(65554 - len(fmt)))], base_packets), 101)
    reject('wma-choice.asf', (work / 'multitrack.asf').read_bytes(), 101, 1)
    reject('missing-track.asf', base, 101, 2)
    manifest = dict(files=files, rejections=rejects, ffmpeg=ffmpeg_version(),
                    writer_sha256=writer_hash())
    manifest['hashes'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in work.iterdir()
                          if p.is_file() and p.suffix in ('.asf', '.wav', '.f32') and '.ours.' not in p.name and '.reference.' not in p.name}
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Prepared {len(files)} streams and {len(rejects)} rejected inputs.', flush=True)


def main():
    work = scratch('asf')
    if '--prepare-only' in sys.argv: prepare(work); return
    if not (work / 'manifest.json').exists(): prepare(work)
    manifest = json.loads((work / 'manifest.json').read_text())
    if manifest['writer_sha256'] != writer_hash():
        raise Failure('Fixture writer changed; prepare fixtures again')
    for name, digest in manifest['hashes'].items():
        if hashlib.sha256((work / name).read_bytes()).hexdigest() != digest: raise Failure('Fixture changed: ' + name)
    wine = '--wine-only' in sys.argv
    names = {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c',
             'track-catalog-oracle': 'track-catalog-oracle.c', 'asf-boundary-oracle': 'asf-boundary-oracle.c',
             'asf-seek-oracle': 'asf-seek-oracle.c'}
    env = dict(os.environ, WINEDEBUG='err+all') if wine else None
    if wine:
        prior = json.loads((out_dir() / 'asf-verification.json').read_text())
        if prior['result'] != 'passed' or prior['fixture_hashes'] != manifest['hashes']: raise Failure('Matching native run must pass first')
        run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
        objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj')) if p.stem not in
                   {'player', 'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}]
        libs = sorted((ROOT / 'bin/obj').glob('*.lib'))
        for name, source_name in names.items():
            run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
                 '-I', ROOT / 'tests', ROOT / 'tests' / source_name, *objects, *libs, '-lm', '-o', ROOT / 'bin' / (name + '.exe')])
        cli = ['wine', ROOT / 'bin/lamp-cli.exe']
        command = lambda name: ['wine', ROOT / 'bin' / (name + '.exe')]
    else:
        library = build_lamp(); build_oracles(out_dir(), names, library)
        cli = [lamp_cli()]
        command = lambda name: [exe(name)]
    checks = []
    for entry in manifest['files']:
        path = work / entry['name']; reference = work / (entry['name'] + '.reference.f32')
        output = work / (entry['name'] + '.ours.f32')
        output.unlink(missing_ok=True)
        options = ['--track', entry['choice']] if entry['choice'] else []
        stats = run([*cli, *options, '--decode', path, output], env=env, timeout=180)
        ours = output.read_bytes()
        if not wine:
            if entry['wave']:
                wave_output = work / (entry['name'] + '.wave.ours.f32')
                wave_output.unlink(missing_ok=True)
                run([*cli, '--decode', work / entry['wave'], wave_output], env=env, timeout=180)
                if ours != wave_output.read_bytes(): raise Failure(entry['name'] + ': differs from same audio in WAVE')
            other = (work / (entry['name'] + '.ffmpeg.f32')).read_bytes() if entry['ffmpeg'] else wave_output.read_bytes()
            if len(ours) != len(other): raise Failure(entry['name'] + ': FFmpeg length differs')
            import array
            a, b = array.array('f', ours), array.array('f', other)
            error = sum((x - y)**2 for x, y in zip(a, b)); signal = sum(y*y for y in b) or 1
            snr = 999 if not error else 10 * math.log10(signal / error)
            peak = max(abs(x-y) for x, y in zip(a, b))
            if entry['name'].startswith('adpcm_ima_wav'):
                # FFmpeg 9 uses separate IMA shifts in WAVE; the existing
                # four-bit LAMP decoder and FFmpeg 5 use one combined product.
                # Keep demux/seek comparisons exact, bound only this reference
                # arithmetic difference, and check the old decoder separately.
                if peak > 127 / 32768: raise Failure(entry['name'] + f': IMA reference peak {peak}')
                if 'version 5.' in ffmpeg_version():
                    older = work / (entry['name'] + '.legacy.ours.f32')
                    ffmpeg('-i', path, '-map', '0:a:0', '-af', 'asetpts=N', '-f', 'f32le', older)
                    if stereo_view(older.read_bytes(), entry['channels'], 0) != ours:
                        raise Failure(entry['name'] + ': FFmpeg 5 IMA differs')
            elif snr < (75 if 'aac' in entry['name'] else 95): raise Failure(entry['name'] + f': FFmpeg SNR {snr}')
            reference.write_bytes(ours)
        if ours != reference.read_bytes(): raise Failure(entry['name'] + ': PCM differs from native verified reference')
        catalog = json.loads(run([*command('track-catalog-oracle'), path, entry['choice'], entry['count'], entry['selected']], env=env, timeout=180).splitlines()[-1])
        # seek-oracle has no track parameter; exact selection is checked above,
        # while automatic selection uses its continuous reference for seeking.
        seeks = None if entry['choice'] or entry['name'] == 'ac3-2.asf' else json.loads(run([*command('seek-oracle'), path, reference, 0], env=env, timeout=180).splitlines()[-1])
        cold_seeks = json.loads(run([*command('asf-seek-oracle'), path, work / entry['wave'], entry['choice']], env=env, timeout=180).splitlines()[-1]) if entry['wave'] else None
        checks.append(dict(test=entry['name'], result='exact', note=entry['note'], stats=stats,
                           catalog=catalog, seeks=seeks, raw_stream_cold_seeks=cold_seeks,
                           continuous_seek_limit='AC-3 dither restarts after seek' if entry['name'] == 'ac3-2.asf' else None,
                           ffmpeg_snr_db=None if wine else snr,
                           ffmpeg_peak_error=None if wine else peak))
        print(entry['name'] + ': PCM, catalog and seeks passed', flush=True)
    for entry in manifest['rejections']:
        proof = json.loads(run([*command('chain-oracle'), 'reject', work / entry['name'], entry['choice']], env=env, timeout=180).splitlines()[-1])
        if proof['decode_error'] != entry['error']: raise Failure(entry['name'] + ': wrong error: ' + str(proof))
        checks.append(dict(test=entry['name'], result=proof))
    for name in ('fields-1.asf', 'aac-2.asf'):
        proof = json.loads(run([*command('asf-boundary-oracle'), work / name], env=env, timeout=180).splitlines()[-1])
        checks.append(dict(test=name + ' protected input boundaries', result=proof))
    sparse = work / 'large-header-sparse.asf'
    proof = json.loads(run([*command('asf-boundary-oracle'), work / 'fields-1.asf', sparse,
                           work / 'fields-1.asf.reference.f32'], env=env, timeout=180).splitlines()[-1])
    sparse.unlink()
    checks.append(dict(test='64-bit object skip past 4 GiB', result=proof))
    for name in ('pcm_s16le-2.asf', 'aac-2.asf'):
        for mode in ('cancel-open', 'cancel-read'):
            proof = json.loads(run([*command('chain-oracle'), mode, work / name], env=env, timeout=180).splitlines()[-1])
            checks.append(dict(test=name + ' ' + mode, result=proof))
    if playback_requested(sys.argv[1:]) and not wine:
        for name in ('pcm_s16le-2.asf', 'libmp3lame-2.asf', 'aac-2.asf'):
            checks.append(dict(test=name + ' playback', result='passed', stats=play(work / name)))
    sources = ['src/asf.s', 'src/avi.s', 'src/decoder.s', 'src/mpegts.s', 'src/track.s',
               'tests/verify-asf.py', 'tests/seek-oracle.c', 'tests/track-catalog-oracle.c', 'tests/asf-boundary-oracle.c', 'tests/asf-seek-oracle.c']
    write_report('asf-wine' if wine else 'asf', dict(result='passed', checks=checks,
                 fixture_hashes=manifest['hashes'], fixture_ffmpeg=manifest['ffmpeg'],
                 runtime_platform=platform.platform(),
                 runtime_sources={n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sources},
                 cli_sha256=hashlib.sha256(Path(cli[-1]).read_bytes()).hexdigest(),
                 reference_hashes={e['name']: hashlib.sha256((work / (e['name'] + '.reference.f32')).read_bytes()).hexdigest() for e in manifest['files']}))
    print(f'Passed {len(checks)} checks.', flush=True)


if __name__ == '__main__': main_guard(main)
