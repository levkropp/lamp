#!/usr/bin/env python3
"""FLV audio.

usage: python3 tests/verify-flv.py [--skip-playback]
- From FFmpeg's muxer, alone and with Sorenson video: PCM (8-bit unsigned,
  16-bit little-endian, 11.025-44.1 kHz, mono and stereo), G.711 and Flash
  ADPCM exact against FFmpeg; MP3 (constant and variable bit rate) exact
  against the raw stream and close to FFmpeg's float decoder; AAC exact
  against its ADTS copy and close to FFmpeg.
- Written here: Flash ADPCM with 2-, 3-, 4- and 5-bit codes, random codes,
  step indexes and samples, several blocks per tag and partial last blocks,
  exact against FFmpeg; MP3 at 8 kHz (sound format 14); a larger header;
  tags of another sound format, encrypted tags and script data skipped; AAC
  with a repeated sequence header; files truncated inside a tag.
- Seeks equal continuous decoding; malformed and unsupported files reject; a
  cancelled open stops cleanly.
Writes <out>/flv-verification.json.
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


# ---------------------------------------------------------------- FLV
def flv_tag(kind, data, timestamp=0):
    return (bytes([kind]) + len(data).to_bytes(3, 'big') + (timestamp & 0xffffff).to_bytes(3, 'big') +
            bytes([timestamp >> 24 & 0xff]) + bytes(3) + data + (11 + len(data)).to_bytes(4, 'big'))


def flv_file(tags, extra=0):
    """FLV header (audio flag), extra header bytes, then tags (type, data)."""
    return (b'FLV\x01\x04' + (9 + extra).to_bytes(4, 'big') + bytes(extra) + bytes(4) +
            b''.join(flv_tag(kind, data, 23 * k) for k, (kind, data) in enumerate(tags)))


def flv_tags(data):
    """An FLV file -> [(type, data)]."""
    pos, out = int.from_bytes(data[5:9], 'big') + 4, []
    while pos + 11 <= len(data):
        size = int.from_bytes(data[pos + 1:pos + 4], 'big')
        out.append((data[pos], data[pos + 11:pos + 11 + size]))
        pos += 15 + size
    return out


def flv_offsets(data):
    """An FLV file -> [(tag offset, type, data size)]."""
    pos, out = int.from_bytes(data[5:9], 'big') + 4, []
    while pos + 11 <= len(data):
        size = int.from_bytes(data[pos + 1:pos + 4], 'big')
        out.append((pos, data[pos], size))
        pos += 15 + size
    return out


class Bits:
    def __init__(self):
        self.value, self.count = 0, 0

    def put(self, value, bits):
        self.value = self.value << bits | (value & ((1 << bits) - 1))
        self.count += bits

    def bytes(self):
        pad = -self.count % 8
        return (self.value << pad).to_bytes((self.count + pad) // 8, 'big')


def swf_packet(rng, channels, bits, blocks):
    """Flash ADPCM data: the code size, then blocks of the given samples per
    channel (a header, then random codes)."""
    out = Bits()
    out.put(bits - 2, 2)
    for samples in blocks:
        for _ in range(channels):
            out.put(rng.randrange(-32768, 32768), 16)
            out.put(rng.choice([0, 1, 63, rng.randrange(64), rng.randrange(20)]), 6)
        for _ in range(samples - 1):
            for _ in range(channels):
                out.put(rng.randrange(1 << bits), bits)
    return out.bytes()


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
    work = scratch('flv')
    checks = []
    rng = random.Random(20261006)

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

    def against_ffmpeg(path, channels, note=''):
        native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
        return exact(path, stereo_view(native, channels, 0), 'FFmpeg', note)

    seed = 0

    # FFmpeg's muxer.
    for codec, rates in (('pcm_s16le', (11025, 22050, 44100)), ('pcm_u8', (11025, 22050, 44100)),
                         ('pcm_alaw', (8000,)), ('pcm_mulaw', (8000,)), ('adpcm_swf', (11025, 22050, 44100))):
        for rate in rates:
            for channels in (1, 2):
                seed += 1
                path = work / f'{codec}-{rate}-{channels}.flv'
                ffmpeg(*source(rate, channels, 1, seed), '-c:a', codec, path)
                note = ''
                if channels == 2 and codec in ('pcm_alaw', 'pcm_mulaw'):
                    # FFmpeg's muxer flags stereo G.711 as mono; set the flag.
                    path.write_bytes(flv_file([(kind, bytes([d[0] | 1]) + d[1:] if kind == 8 else d)
                                               for kind, d in flv_tags(path.read_bytes())]))
                    note = 'stereo flag set by the test'
                against_ffmpeg(path, channels, note)
    for codec in ('pcm_s16le', 'adpcm_swf'):
        seed += 1
        path = work / f'{codec}-video.flv'
        ffmpeg(*video(2), *source(22050, 2, 2, seed), '-c:v', 'flv', '-c:a', codec, path)
        against_ffmpeg(path, 2, 'with video')
    for name, coding, raw_format in (('mp3', ['-c:a', 'libmp3lame', '-b:a', '160k'], 'mp3'),
                                     ('mp3-vbr', ['-c:a', 'libmp3lame', '-q:a', '2'], 'mp3'),
                                     ('mp3-22050', ['-c:a', 'libmp3lame', '-ar', '22050'], 'mp3'),
                                     ('aac', ['-c:a', 'aac', '-b:a', '128k', '-aac_pns', '0'], 'adts'),
                                     ('aac-mono', ['-c:a', 'aac', '-ac', '1', '-ar', '32000', '-aac_pns', '0'],
                                      'adts')):
        seed += 1
        path = work / f'{name}.flv'
        ffmpeg(*video(2), *source(44100, 2, 2, seed), '-c:v', 'flv', *coding, path)
        raw = work / f'{name}.{raw_format}'
        tags = ['-write_xing', '0', '-id3v2_version', '0'] if raw_format == 'mp3' else []
        ffmpeg('-i', path, '-c:a', 'copy', '-vn', *tags, '-f', raw_format, raw)
        reference, _ = lamp(raw)
        exact(path, reference, f'the raw {raw_format} stream')
        reference = Path(str(path) + '.ffmpeg.f32')
        decoder = ['-c:a', 'mp3float'] if raw_format == 'mp3' else []
        ffmpeg('-cpuflags', '0', *decoder, '-i', path, '-f', 'f32le', reference)
        channels = 1 if name == 'aac-mono' else 2
        level = snr(Path(str(path) + '.f32').read_bytes(), stereo_view(reference.read_bytes(), channels, 0))
        checks.append({'test': f'{path.name} against FFmpeg', 'result': 'matched', 'snr_db': round(level, 1)})
        print(f'{path.name}: {level:.1f} dB against FFmpeg', flush=True)
        if level < 110:
            raise Failure(f'{path.name}: {level:.1f} dB against FFmpeg')

    # Flash ADPCM written here: every code size, random codes and states.
    rates = {11025: 1, 22050: 2, 44100: 3}
    for bits in (2, 3, 4, 5):
        for channels in (1, 2):
            rate = (11025, 22050, 44100)[(bits + channels) % 3]
            flags = 0x10 | rates[rate] << 2 | 2 | (channels - 1)
            tags = [(18, b'\x02\x00\x0aonMetaData\x08\x00\x00\x00\x00\x00\x00\x09')]
            for k in range(12):
                blocks = rng.choice([[4096], [4096, 4096], [rng.randrange(1, 4096)], [4096, rng.randrange(1, 4097)],
                                     [rng.randrange(1, 300)]])
                tags.append((8, bytes([flags]) + swf_packet(rng, channels, bits, blocks)))
            path = work / f'swf-{bits}bit-{channels}.flv'
            path.write_bytes(flv_file(tags))
            against_ffmpeg(path, channels, f'{bits}-bit codes')

    # Other files written here.
    seed += 1
    mp3_8k = work / 'mp3-8000.mp3'
    ffmpeg(*source(8000, 1, 2, seed), '-c:a', 'libmp3lame', '-b:a', '24k', '-write_xing', '0', '-id3v2_version', '0',
           mp3_8k)
    data = mp3_8k.read_bytes()
    pieces = [data[i:i + 157] for i in range(0, len(data), 157)]
    path = work / 'mp3-8000.flv'
    path.write_bytes(flv_file([(8, b'\xe2' + piece) for piece in pieces]))
    exact(path, lamp(mp3_8k)[0], mp3_8k.name, 'sound format 14, tags cutting frames')

    base = work / 'pcm_s16le-video.flv'
    reference = lamp(base)[0]
    tags = flv_tags(base.read_bytes())
    audio = [k for k, (kind, _) in enumerate(tags) if kind == 8]
    mixed = list(tags)
    mixed.insert(audio[3], (8, b'\x6a' + bytes(64)))                  # Nellymoser
    mixed.insert(audio[5], (0x28, b'\x3e' + bytes(100)))              # encrypted audio
    mixed.insert(audio[7], (8, b'\x3a' + bytes(100)))                 # mono: another PCM layout
    mixed.insert(audio[8], (18, b'\x02\x00\x04test\x05'))
    for name, data, note in (('skipped-tags.flv', flv_file(mixed), 'other sound formats, encryption, script data'),
                             ('long-header.flv', flv_file(tags, 23), '32-byte header')):
        path = work / name
        path.write_bytes(data)
        exact(path, reference, base.name, note)

    base = work / 'aac.flv'
    tags = flv_tags(base.read_bytes())
    header = next(k for k, (kind, data) in enumerate(tags) if kind == 8 and data[1] == 0)
    repeated = tags[:header + 4] + [tags[header]] + tags[header + 4:]
    path = work / 'aac-repeated-header.flv'
    path.write_bytes(flv_file(repeated))
    exact(path, lamp(work / 'aac.adts')[0], 'aac.adts', 'a second sequence header')

    full = work / 'pcm_s16le-44100-2.flv'
    data = full.read_bytes()
    positions = [p for p, kind, _ in flv_offsets(data) if kind == 8]
    audio_bytes = sum(len(d) - 1 for kind, d in flv_tags(data[:positions[-1]]) if kind == 8) + 1001
    path = work / 'pcm-truncated.flv'
    path.write_bytes(data[:positions[-1] + 11 + 1 + 1001])
    kept = audio_bytes // 4
    exact(path, lamp(full)[0][:kept * 8], f'the first {kept} frames of {full.name}', 'cut inside the last tag')
    data = (work / 'aac.flv').read_bytes()
    position, size = [(p, n) for p, kind, n in flv_offsets(data) if kind == 8][-1]
    frames = adts_frames((work / 'aac.adts').read_bytes())
    path = work / 'aac-truncated.flv'
    path.write_bytes(data[:position + 11 + size // 2])
    shorter = work / 'aac-shorter.adts'
    shorter.write_bytes(b''.join(frames[:-1]))
    exact(path, lamp(shorter)[0], shorter.name, 'the last frame cut')

    # Seeks.
    for name in ('pcm_s16le-video.flv', 'pcm_u8-11025-1.flv', 'pcm_alaw-8000-2.flv', 'adpcm_swf-44100-2.flv',
                 'swf-5bit-2.flv', 'swf-2bit-1.flv', 'mp3.flv', 'mp3-vbr.flv', 'aac.flv', 'mp3-8000.flv'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0', '0', '0']).strip().splitlines()[-1]
        result = json.loads(line)
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {result["checks"]} checks', flush=True)

    # Rejections.
    seed += 1
    unsupported = {}
    for codec in ('nellymoser', 'libspeex'):
        path = work / f'{codec}.flv'
        ffmpeg(*source(16000 if codec == 'libspeex' else 22050, 1, 1, seed), '-c:a', codec, path)
        unsupported[f'flv-{codec}.flv'] = (path.read_bytes(), 101)
    silent = work / 'video-only.flv'
    ffmpeg(*video(1), '-c:v', 'flv', silent)
    pcm = flv_tags((work / 'pcm_s16le-11025-1.flv').read_bytes())
    aac = flv_tags((work / 'aac.flv').read_bytes())
    bad = {
        **unsupported,
        'flv-video-only.flv': (silent.read_bytes(), 101),
        'flv-5512.flv': (flv_file([(8, b'\x32' + d[1:]) for kind, d in pcm if kind == 8]), 101),
        'flv-encrypted.flv': (flv_file([(0x28, d) for kind, d in pcm if kind == 8]), 101),
        'flv-aac-no-header.flv': (flv_file([(kind, d) for kind, d in aac if not (kind == 8 and d[1] == 0)]), 100),
        'flv-short.flv': (b'FLV\x01\x04\x00\x00\x00\x09\x00\x00\x00', 100),
        'flv-small-offset.flv': (b'FLV\x01\x04\x00\x00\x00\x05' + bytes(20), 100),
        'flv-adpcm-oversized.flv': (flv_file([(8, b'\x1a' + swf_packet(rng, 1, 4, [4096] * 33))]), 101),
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

    line = run([chain, 'cancel-open', work / 'swf-4bit-2.flv']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open swf-4bit-2.flv', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'FLV playback', 'result': 'played', 'stats': play(work / 'aac.flv')})
    write_report('flv', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': "FLV audio (PCM, G.711, Flash ADPCM, MP3, AAC) from FFmpeg's muxer and written "
                                  '(Flash ADPCM at every code size, MP3 at 8 kHz, skipped tags, truncation) against '
                                  'FFmpeg or equivalent files; seeks; malformed and unsupported files; '
                                  'cancellation.'})
    print(f'Passed {len(checks)} FLV checks.')


if __name__ == '__main__':
    main_guard(main)
