#!/usr/bin/env python3
"""Core Audio Format, Wave64, RIFX and AIFF-C IMA4 files.

usage: python3 tests/verify-caf-wave64.py [--skip-playback]
- CAF from FFmpeg's muxer: linear PCM (8-32-bit integers and float32/64 in
  both byte orders), G.711 and IMA4 exact against FFmpeg; 3.0 to 7.1 linear
  PCM with FFmpeg's chan layouts mixed exactly as the same audio in WAVE;
  ALAC exact against its MP4 copy; MPEG Layer II/III and AC-3 exact against
  the raw streams; Opus exact against the Ogg copy (after its pre-skip).
- CAF written here: AAC with an ES descriptor cookie and a packet table with
  priming and remainder frames (exact against the ADTS stream, trimmed),
  new-style ALAC cookies, a data chunk sized -1, unknown chunks, multi-byte
  packet sizes and channel bitmaps.
- Wave64 from FFmpeg's muxer: PCM, float, G.711 and ADPCM, mono to 5.1, exact
  against FFmpeg (ADPCM up to the fact count); unknown chunks and an
  unpadded last chunk.
- RIFX (big-endian WAVE) converted from FFmpeg's WAVE files decodes exactly as
  the original (FFmpeg 6.1 reads RIFX samples as little-endian; LAMP follows
  the RIFF specification and libsndfile).
- AIFF-C ima4 exact against FFmpeg.
- Seeks equal continuous decoding (IMA4 within its predictor's low bits);
  malformed and unsupported files reject; a cancelled open stops cleanly.
Writes <out>/caf-wave64-verification.json.
"""
import array
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, stereo_view, write_report)


def ffmpeg_native(path, output):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(path), '-f', 'f32le',
                             str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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


# ---------------------------------------------------------------- CAF writing
def caf_chunk(kind, payload, size=None):
    return kind + struct.pack('>q', len(payload) if size is None else size) + payload


def varint(n):
    out = [n & 0x7f]
    n >>= 7
    while n:
        out.append(0x80 | (n & 0x7f))
        n >>= 7
    return bytes(reversed(out))


def desc(rate, fourcc, flags, bpp, fpp, channels, bits):
    return struct.pack('>d4sIIIII', rate, fourcc, flags, bpp, fpp, channels, bits)


def pakt(sizes, valid, priming, remainder):
    return struct.pack('>qqii', len(sizes), valid, priming, remainder) + b''.join(varint(s) for s in sizes)


def es_descriptor(config):
    """ES_Descriptor (tag 3) with a DecoderConfigDescriptor for MPEG-4 audio
    and the AudioSpecificConfig, using four-byte descriptor lengths."""
    def descriptor(tag, body):
        n = len(body)
        return bytes([tag, 0x80 | (n >> 21) & 0x7f, 0x80 | (n >> 14) & 0x7f, 0x80 | (n >> 7) & 0x7f, n & 0x7f]) + body
    dsi = descriptor(5, config)
    dcd = descriptor(4, bytes([0x40, 0x15]) + bytes(3) + struct.pack('>II', 128000, 128000) + dsi)
    return descriptor(3, struct.pack('>HB', 1, 0) + dcd + descriptor(6, b'\x02'))


def adts_frames(data):
    """ADTS stream -> (AudioSpecificConfig, raw frames)."""
    frames, pos, config = [], 0, None
    while pos + 7 <= len(data):
        h = data[pos:pos + 7]
        if h[0] != 0xff or h[1] & 0xf0 != 0xf0:
            raise Failure('ADTS sync')
        size = (h[3] & 3) << 11 | h[4] << 3 | h[5] >> 5
        header = 7 if h[1] & 1 else 9
        if config is None:
            profile, rate, channels = (h[2] >> 6) + 1, (h[2] >> 2) & 15, (h[2] & 1) << 2 | h[3] >> 6
            config = bytes([profile << 3 | rate >> 1, (rate & 1) << 7 | channels << 3])
        frames.append(data[pos + header:pos + size])
        pos += size
    return config, frames


def caf_file(chunks):
    return b'caff' + struct.pack('>HH', 1, 0) + b''.join(chunks)


def wav_to_rifx(data):
    """A WAVE file as RIFX: big-endian sizes, fmt fields and samples."""
    out = bytearray(b'RIFX\0\0\0\0WAVE')
    pos, width, tag = 12, 0, 0
    while pos + 8 <= len(data):
        ident, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if ident == b'fmt ':
            tag, channels, rate, byte_rate, align, bits = struct.unpack_from('<HHIIHH', body)
            width = bits // 8
            fields = struct.pack('>HHIIHH', tag, channels, rate, byte_rate, align, bits)
            if size >= 40:
                cb, valid, mask, d1, d2, d3 = struct.unpack_from('<HHIIHH', body, 16)
                fields += struct.pack('>HHIIHH', cb, valid, mask, d1, d2, d3) + body[32:40]
                tag = struct.unpack_from('<H', body, 24)[0]
            body = fields
        elif ident == b'data':
            if tag in (1, 3) and width > 1:
                body = b''.join(body[i:i + width][::-1] for i in range(0, len(body), width))
        elif ident == b'fact':
            body = struct.pack('>I', struct.unpack_from('<I', body)[0])
        else:
            pos += 8 + size + (size & 1)
            continue
        out += ident + struct.pack('>I', len(body)) + body + (b'\0' if len(body) & 1 else b'')
        pos += 8 + size + (size & 1)
    struct.pack_into('>I', out, 4, len(out) - 8)
    return bytes(out)


W64_TAIL = bytes.fromhex('f3acd3118cd100c04f8edb8a')


def w64_chunks(data):
    pos, out = 40, []
    while pos + 24 <= len(data):
        size = struct.unpack_from('<Q', data, pos + 16)[0]
        out.append((data[pos:pos + 16], data[pos + 24:pos + size]))
        pos += (size + 7) & ~7
    return out


def w64_file(chunks, pad_last=True):
    body = b''
    for k, (guid, payload) in enumerate(chunks):
        chunk = guid + struct.pack('<Q', 24 + len(payload)) + payload
        if pad_last or k < len(chunks) - 1:
            chunk += bytes(-len(chunk) % 8)
        body += chunk
    head = bytes.fromhex('72696666' '2e91cf11a5d628db04c10000')
    return head + struct.pack('<Q', 40 + len(body)) + b'wave' + W64_TAIL + body


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('caf-wave64')
    checks = []

    def lamp(path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def source(rate, channels, duration, seed):
        tones = '|'.join(f'0.4*sin(2*PI*{89 * (k + 3) + seed}*t)*sin(2*PI*0.9*t+{k})+0.1*random({k})-0.05'
                         for k in range(channels))
        return ['-f', 'lavfi', '-i', f'aevalsrc={tones}:s={rate}:d={duration}']

    def exact(path, reference, comparator, note=''):
        ours, stats = lamp(path)
        if ours != reference:
            raise Failure(f'{path.name}: differs from {comparator}')
        checks.append({'test': path.name, 'result': 'exact', 'comparator': comparator, 'note': note, 'stats': stats})
        print(f'{path.name}: exact against {comparator}', flush=True)
        return ours

    layouts = {1: 'mono', 2: 'stereo', 3: '3.0', 4: 'quad', 6: '5.1', 8: '7.1'}
    seed = 0

    # CAF from FFmpeg.
    for codec in ('pcm_s8', 'pcm_s16be', 'pcm_s16le', 'pcm_s24be', 'pcm_s24le', 'pcm_s32be', 'pcm_s32le', 'pcm_f32be',
                  'pcm_f32le', 'pcm_f64be', 'pcm_f64le', 'pcm_alaw', 'pcm_mulaw', 'adpcm_ima_qt'):
        for channels in (1, 2):
            seed += 1
            path = work / f'{codec}-{channels}.caf'
            ffmpeg(*source(44100 if channels == 2 else 22050, channels, 1, seed), '-c:a', codec, path)
            native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
            exact(path, stereo_view(native, channels, 0), 'FFmpeg')
    for channels in (3, 4, 6, 8):
        seed += 1
        caf, wav = work / f'lpcm-{layouts[channels]}.caf', work / f'lpcm-{layouts[channels]}.wav'
        for path in (caf, wav):
            ffmpeg(*source(48000, channels, 1, seed), '-af', f'aformat=channel_layouts={layouts[channels]}',
                   '-c:a', 'pcm_s24le', path)
        reference, _ = lamp(wav)
        exact(caf, reference, f'the same audio in WAVE ({layouts[channels]})', 'chan layout tag')
    alac_streams = {}
    for name, channels, fmt in (('alac-16', 2, 's16p'), ('alac-24-mono', 1, 's32p'), ('alac-5.1', 6, 's16p')):
        seed += 1
        caf, mka = work / f'{name}.caf', work / f'{name}.mka'
        ffmpeg(*source(44100, channels, 1.5, seed), '-af', f'aformat=channel_layouts={layouts[channels]}',
               '-c:a', 'alac', '-sample_fmt', fmt, caf)
        ffmpeg('-i', caf, '-c', 'copy', mka)
        reference, _ = lamp(mka)
        exact(caf, reference, 'its Matroska copy', 'frma/alac cookie, packet table')
        if channels <= 2:
            native = ffmpeg_native(caf, Path(str(caf) + '.ffmpeg.f32'))
            if Path(str(caf) + '.f32').read_bytes() != stereo_view(native, channels, 0):
                raise Failure(f'{caf.name}: differs from FFmpeg')
            checks.append({'test': f'{caf.name} against FFmpeg', 'result': 'exact'})
        alac_streams[name] = caf
    for name, coding in (('mp2', ['-c:a', 'mp2', '-b:a', '192k']), ('mp3', ['-c:a', 'libmp3lame', '-b:a', '160k']),
                         ('ac3', ['-c:a', 'ac3', '-b:a', '192k'])):
        seed += 1
        caf = work / f'{name}.caf'
        ffmpeg(*source(44100, 2, 2, seed), *coding, caf)
        raw = work / f'{name}.raw'
        tags = ['-write_xing', '0', '-id3v2_version', '0'] if name == 'mp3' else []
        ffmpeg('-i', caf, '-c', 'copy', *tags, '-f', name, raw)
        reference, _ = lamp(raw)
        exact(caf, reference, f'the raw .{name} stream')
        reference = Path(str(caf) + '.ffmpeg.f32')
        decoder = {'mp2': ['-c:a', 'mp2float'], 'mp3': ['-c:a', 'mp3float']}.get(name, [])
        ffmpeg('-cpuflags', '0', *decoder, '-i', caf, '-f', 'f32le', reference)
        level = snr(Path(str(caf) + '.f32').read_bytes(), reference.read_bytes())
        checks.append({'test': f'{caf.name} against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})
        if level < 110:
            raise Failure(f'{caf.name}: {level:.1f} dB against FFmpeg')
    seed += 1
    opus_caf, opus_ogg = work / 'opus.caf', work / 'opus.opus'
    ffmpeg(*source(48000, 2, 2, seed), '-c:a', 'libopus', '-b:a', '96k', opus_ogg)
    ffmpeg('-i', opus_ogg, '-c', 'copy', opus_caf)
    ogg, _ = lamp(opus_ogg)
    preskip = struct.unpack_from('<H', opus_ogg.read_bytes(), opus_ogg.read_bytes().index(b'OpusHead') + 10)[0]
    ours, stats = lamp(opus_caf)
    if ours[preskip * 8:preskip * 8 + len(ogg)] != ogg:
        raise Failure('opus.caf: differs from its Ogg copy')
    checks.append({'test': 'opus.caf', 'result': 'exact', 'comparator': f'its Ogg copy after {preskip} pre-skip frames',
                   'stats': stats})
    print('opus.caf: exact against its Ogg copy', flush=True)

    # CAF written here.
    seed += 1
    adts = work / 'aac.adts'
    ffmpeg(*source(44100, 2, 2, seed), '-c:a', 'aac', '-b:a', '128k', '-aac_pns', '0', '-f', 'adts', adts)
    config, frames = adts_frames(adts.read_bytes())
    plain, _ = lamp(adts)
    total = len(plain) // 8
    priming, remainder = 2112, 700
    data = b''.join(frames)
    aac_caf = work / 'aac-pakt.caf'
    aac_caf.write_bytes(caf_file([caf_chunk(b'desc', desc(44100.0, b'aac ', 0, 0, 1024, 2, 0)),
                                  caf_chunk(b'kuki', es_descriptor(config)),
                                  caf_chunk(b'pakt', pakt([len(f) for f in frames], total - priming - remainder,
                                                          priming, remainder)),
                                  caf_chunk(b'free', bytes(37)),
                                  caf_chunk(b'data', bytes(4) + data)]))
    exact(aac_caf, plain[priming * 8:(total - remainder) * 8], 'the ADTS stream, priming and remainder trimmed',
          'ES descriptor cookie')
    # New-style ALAC cookie, data sized -1, unknown chunks.
    old = alac_streams['alac-16'].read_bytes()
    chunks = {}
    pos = 8
    while pos + 12 <= len(old):
        kind, size = old[pos:pos + 4], struct.unpack_from('>q', old, pos + 4)[0]
        chunks[kind] = old[pos + 12:pos + 12 + size]
        pos += 12 + size
    kuki = chunks[b'kuki'][24:48]
    reference, _ = lamp(alac_streams['alac-16'])
    variant = work / 'alac-new-cookie.caf'
    variant.write_bytes(caf_file([caf_chunk(b'desc', chunks[b'desc']), caf_chunk(b'uuid', bytes(range(20))),
                                  caf_chunk(b'kuki', kuki), caf_chunk(b'pakt', chunks[b'pakt']),
                                  caf_chunk(b'data', chunks[b'data'], -1)]))
    exact(variant, reference, 'the FFmpeg file', 'new-style cookie, data sized -1, uuid chunk')
    # Linear PCM with a channel bitmap (5.1 back) and without chan.
    pcm = (work / 'lpcm-5.1.caf').read_bytes()
    pchunks, pos = {}, 8
    while pos + 12 <= len(pcm):
        kind, size = pcm[pos:pos + 4], struct.unpack_from('>q', pcm, pos + 4)[0]
        pchunks[kind] = pcm[pos + 12:pos + 12 + size]
        pos += 12 + size
    reference, _ = lamp(work / 'lpcm-5.1.wav')                  # FFmpeg's 5.1: mask 0x3f
    bitmap = work / 'lpcm-bitmap.caf'
    bitmap.write_bytes(caf_file([caf_chunk(b'desc', pchunks[b'desc']),
                                 caf_chunk(b'chan', struct.pack('>III', 0x10000, 0x3f, 0)),
                                 caf_chunk(b'data', pchunks[b'data'])]))
    exact(bitmap, reference, 'WAVE with the same mask', 'chan bitmap 0x3f')
    default = work / 'lpcm-no-chan.caf'
    default.write_bytes(caf_file([caf_chunk(b'desc', pchunks[b'desc']), caf_chunk(b'data', pchunks[b'data'])]))
    exact(default, reference, 'WAVE with the default 5.1 mask', 'no chan chunk')

    # Wave64 from FFmpeg.
    w64_files = []
    for codec, channels in (('pcm_u8', 2), ('pcm_s16le', 1), ('pcm_s16le', 2), ('pcm_s24le', 6), ('pcm_s32le', 2),
                            ('pcm_f32le', 2), ('pcm_f64le', 1), ('pcm_alaw', 2), ('pcm_mulaw', 1),
                            ('adpcm_ima_wav', 2), ('adpcm_ms', 1)):
        seed += 1
        path = work / f'{codec}-{channels}.w64'
        ffmpeg(*source(44100, channels, 1, seed), '-af', f'aformat=channel_layouts={layouts[channels]}', '-c:a', codec,
               path)
        native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
        fmt = next(p for g, p in w64_chunks(path.read_bytes()) if g[:4] == b'fmt ')
        mask = struct.unpack_from('<I', fmt, 20)[0] if struct.unpack_from('<H', fmt)[0] == 0xfffe else 0
        reference = stereo_view(native, channels, mask)
        fact = [p for g, p in w64_chunks(path.read_bytes()) if g[:4] == b'fact']
        if fact:                                               # FFmpeg plays padding and ADPCM tails
            reference = reference[:struct.unpack_from('<Q', fact[0])[0] * 8]
        exact(path, reference, 'FFmpeg' + (' up to the fact count' if fact else ''))
        w64_files.append(path)
    base = (work / 'pcm_s16le-2.w64').read_bytes()
    parts = w64_chunks(base)
    reference, _ = lamp(work / 'pcm_s16le-2.w64')
    odd = [(g, p) for g, p in parts if g[:4] != b'data'] + [(b'LAMP' + bytes(12), b'odd'), ]
    odd += [(g, p[:len(p) - 4]) for g, p in parts if g[:4] == b'data']      # one frame less, unpadded
    variant = work / 'w64-unpadded.w64'
    variant.write_bytes(w64_file(odd, pad_last=False))
    exact(variant, reference[:len(reference) - 8], 'the FFmpeg file less its last frame',
          'unknown chunk, unpadded last chunk')

    # RIFX from FFmpeg's WAVE files.
    rifx_files = []
    for codec, channels in (('pcm_u8', 1), ('pcm_s16le', 2), ('pcm_s24le', 2), ('pcm_s32le', 6), ('pcm_f32le', 2),
                            ('pcm_f64le', 1), ('pcm_alaw', 2), ('pcm_mulaw', 2)):
        seed += 1
        wav = work / f'{codec}-{channels}.wav'
        ffmpeg(*source(48000, channels, 1, seed), '-af', f'aformat=channel_layouts={layouts[channels]}', '-c:a', codec,
               wav)
        rifx = work / f'{codec}-{channels}.rifx.wav'
        rifx.write_bytes(wav_to_rifx(wav.read_bytes()))
        reference, _ = lamp(wav)
        exact(rifx, reference, 'the original WAVE file')
        rifx_files.append(rifx)

    # AIFF-C ima4.
    for channels in (1, 2):
        seed += 1
        path = work / f'ima4-{channels}.aiff'
        ffmpeg(*source(32000, channels, 1, seed), '-c:a', 'adpcm_ima_qt', path)
        exact(path, stereo_view(ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32')), channels, 0), 'FFmpeg')

    # Seeks.
    for name, tolerance in (('pcm_s24be-2.caf', 0), ('pcm_alaw-1.caf', 0), ('alac-16.caf', 0), ('mp3.caf', 0),
                            ('aac-pakt.caf', 0), ('lpcm-5.1.caf', 0), ('pcm_s24le-6.w64', 0),
                            ('adpcm_ima_wav-2.w64', 0), ('pcm_s24le-2.rifx.wav', 0), ('adpcm_ima_qt-2.caf', 128),
                            ('ima4-2.aiff', 128)):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0', '0', str(tolerance)]).strip().splitlines()[-1]
        result = json.loads(line)
        checks.append({'test': f'{name} seeks', 'result': line,
                       'tolerance': f'{tolerance}/32768' if tolerance else 'exact'})
        print(f'{name} seeks: {result["checks"]} checks, deviation {result["maximum_deviation"]}', flush=True)

    # Rejections.
    desc16 = desc(44100.0, b'lpcm', 0, 4, 1, 2, 16)
    data16 = caf_chunk(b'data', bytes(4) + bytes(400))
    bad = {
        'caf-data-first.caf': (caf_file([data16, caf_chunk(b'desc', desc16)]), 100),
        'caf-version-2.caf': (b'caff' + struct.pack('>HH', 2, 0) + caf_chunk(b'desc', desc16) + data16, 100),
        'caf-no-data.caf': (caf_file([caf_chunk(b'desc', desc16)]), 100),
        'caf-chunk-overrun.caf': (caf_file([caf_chunk(b'desc', desc16), caf_chunk(b'data', bytes(40), 4000)]), 100),
        'caf-free-unsized.caf': (caf_file([caf_chunk(b'desc', desc16), caf_chunk(b'free', b'', -1), data16]), 100),
        'caf-mace.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'MAC3', 0, 2, 6, 1, 0)), data16]), 101),
        'caf-20-bit.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'lpcm', 0, 6, 1, 2, 20)), data16]), 101),
        'caf-9-channels.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'lpcm', 0, 18, 1, 9, 16)), data16]), 101),
        'caf-4-khz.caf': (caf_file([caf_chunk(b'desc', desc(4000.0, b'lpcm', 0, 4, 1, 2, 16)), data16]), 101),
        'caf-variable-frames.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'.mp3', 0, 0, 0, 2, 0)),
                                              caf_chunk(b'pakt', pakt([], 0, 0, 0)), data16]), 101),
        'caf-pakt-overrun.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'.mp3', 0, 0, 1152, 2, 0)),
                                           caf_chunk(b'pakt', pakt([200, 300], 2304, 0, 0)), data16]), 100),
        'caf-pakt-truncated.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'.mp3', 0, 0, 1152, 2, 0)),
                                             caf_chunk(b'pakt', pakt([100], 1152, 0, 0)[:-1] + b'\x81'), data16]),
                                   100),
        'caf-alac-no-cookie.caf': (caf_file([caf_chunk(b'desc', desc(44100.0, b'alac', 0, 0, 4096, 2, 0)),
                                             caf_chunk(b'pakt', pakt([100], 4096, 0, 0)), data16]), 100),
    }
    w64 = (work / 'pcm_s16le-2.w64').read_bytes()
    broken = bytearray(w64)
    broken[30] ^= 1
    bad['w64-wave-guid.w64'] = (bytes(broken), None)
    small = bytearray(w64)
    struct.pack_into('<Q', small, 56, 16)                      # first chunk size below its header
    bad['w64-chunk-small.w64'] = (bytes(small), None)
    bad['w64-truncated.w64'] = (w64[:-3], None)
    adpcm_wav = work / 'ima.wav'
    ffmpeg(*source(22050, 2, 0.5, 99), '-c:a', 'adpcm_ima_wav', adpcm_wav)
    bad['rifx-adpcm.wav'] = (wav_to_rifx(adpcm_wav.read_bytes()), None)
    rejected = 0
    for name, (data, code) in bad.items():
        (work / name).write_bytes(data)
        line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
        result = json.loads(line)
        if result.get('result') != 'rejected' or (code is not None and result.get('decode_error') != code):
            raise Failure(f'{name}: expected a rejection ({code}), got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
        rejected += 1
    print(f'Rejected {rejected} malformed or unsupported files', flush=True)

    line = run([chain, 'cancel-open', work / 'alac-5.1.caf']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open alac-5.1.caf', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'CAF playback', 'result': 'played', 'stats': play(work / 'alac-16.caf')})
    write_report('caf-wave64', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                                'scope': 'CAF (linear PCM, G.711, IMA4, ALAC, AAC, MPEG audio, AC-3, Opus), Wave64 '
                                         '(PCM, float, G.711, ADPCM), RIFX and AIFF-C ima4 against FFmpeg or '
                                         'equivalent files; seeks; malformed and unsupported files; cancellation.'})
    print(f'Passed {len(checks)} CAF, Wave64, RIFX and IMA4 checks.')


if __name__ == '__main__':
    main_guard(main)
