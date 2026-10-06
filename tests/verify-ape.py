#!/usr/bin/env python3
"""Monkey's Audio decoding against its sources, FFmpeg and written streams.

usage: python3 tests/verify-ape.py [--skip-playback]
- JMAC (libjmac-java, a Java port of Monkey's Audio 3.99, which writes
  version 3990) encodes fixtures at every compression level, 1000 (fast) to
  5000 (insane): stereo, loud stereo, mono, 8-, 16- and 24-bit, 8-192 kHz,
  files of several frames at every level, silence (silence frames) and two
  identical channels (pseudo-stereo frames). LAMP's decode equals the source
  exactly and FFmpeg's decode (checking CRCs), except that FFmpeg fails its
  own CRC check on 24-bit stereo at level 5000: it rounds a filter's sum in
  64 bits where Monkey's Audio and LAMP wrap in 32.
- tests/ape_vectors.py writes what JMAC never does: versions 3930-3989 (the
  32-byte header with its peak level, seek element count and missing WAV
  header; the 3900 residual model, the 3930 predictor, adaption before 3980),
  24-bit stereo from the 64-bit predictor, frame flags (stereo and mono
  silence, pseudo-stereo, an ignored single-channel silence flag), escapes
  and wide pivots, frames starting at each byte of a word, WAV tails. LAMP,
  FFmpeg (checking CRCs) and the written PCM agree exactly; a coverage set
  confirms every feature was written.
- Seeks equal continuous decoding (tests/seek-oracle.c), in frames of
  73728 to 1179648 blocks and in written streams.
- ID3v2 and APEv2 tags (--tags, an APEv2 cover with --cover); a flipped bit
  fails the frame's CRC, and a cut file or missing frames stop decoding with
  decode_error 100 after a prefix of FFmpeg's decode; malformed headers
  reject with 100; versions 3920 and 3991, three channels, 32 bits and 7 kHz
  with 101; a cancelled open stops cleanly.
Writes <out>/ape-verification.json.
"""
import array
import json
import math
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ape_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, lamp_cli, main_guard,
                       out_dir, play, playback_requested, run, scratch, write_report)

JMAC = Path('/usr/share/java/jmac.jar')
REQUIRED = {'version 3930', 'version 3940', 'version 3950', 'version 3960', 'version 3970', 'version 3980',
            'version 3990', 'level 1000', 'level 2000', 'level 3000', 'level 4000', 'level 5000', '8-bit', '16-bit',
            '24-bit', 'mono', 'stereo', 'descriptor', '32-byte header', 'peak level', 'seek element count',
            'no stored WAV header', 'WAV tail', 'predictor 3930', 'predictor 3950', 'adaption before 3980',
            'adaption 3980', '64-bit predictor', '64-bit prediction beyond 32 bits', '3990 escape', 'wide pivot',
            '3900 escape', '3900 wide bits', 'frame flags', 'stereo silence', 'mono silence', 'pseudo-stereo',
            'one silent channel flag (ignored)', 'frame at byte 1 of a word', 'frame at byte 2 of a word',
            'frame at byte 3 of a word'}
STEREO = "0.4*sin(2*PI*220*t)+0.3*(random(1)-0.5)|0.3*sin(2*PI*330*t+1)+0.2*(random(1)-0.5)+0.1*(random(2)-0.5)"
LOUD = "0.98*sin(2*PI*50*t)*(0.5+0.5*random(0))|-0.98*sin(2*PI*70*t)"
MONO = "0.5*sin(2*PI*440*t)+0.2*(random(3)-0.5)"


def plain_wav(path, raw, rate, channels, bits):
    """A WAVE file with a plain PCM fmt chunk (JMAC reads no others)."""
    fmt = struct.pack('<HHIIHH', 1, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
    path.write_bytes(b'RIFF' + struct.pack('<I', 36 + len(raw)) + b'WAVEfmt ' + struct.pack('<I', 16) + fmt +
                     b'data' + struct.pack('<I', len(raw)) + raw)


def floats(values, bits, channels):
    """Integer samples (8-bit unsigned as in WAVE files) as LAMP's floats."""
    scale = 1 << (bits - 1)
    out = array.array('f', [v / scale for v in values])
    if channels == 1:
        stereo = array.array('f', [0.0]) * (2 * len(out))
        stereo[0::2] = out
        stereo[1::2] = out
        out = stereo
    return out.tobytes()


def pcm_values(raw, bits):
    if bits == 8:
        return [b - 128 for b in raw]
    step = bits // 8
    return [int.from_bytes(raw[i:i + step], 'little', signed=True) for i in range(0, len(raw), step)]


def ffmpeg_decode(path, crc=True):
    """FFmpeg's float32 decode (mono doubled) and its error text."""
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                             *(['-err_detect', 'crccheck'] if crc else []), '-i', str(path), '-f', 'f32le', '-'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    data = result.stdout
    channels = int(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'stream=channels', '-of', 'csv=p=0',
                                   str(path)], stdout=subprocess.PIPE).stdout.strip() or 2)
    if channels == 1:
        mono = array.array('f', data)
        stereo = array.array('f', [0.0]) * (2 * len(mono))
        stereo[0::2] = mono
        stereo[1::2] = mono
        data = stereo.tobytes()
    return data, result.stderr.decode('utf-8', 'replace').strip()


def lamp_decode(path):
    """-> (float32 bytes, exit code, stats) without requiring success."""
    output = Path(str(path) + '.f32')
    if output.exists():
        output.unlink()
    result = subprocess.run([str(lamp_cli()), '--decode', str(path), str(output)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    data = output.read_bytes() if output.exists() else b''
    return data, result.returncode, result.stdout.decode('utf-8', 'replace').strip().splitlines()[-1:]


def main():
    if not shutil.which('java') or not JMAC.exists():
        raise Failure(f'JMAC is required: {JMAC} and java (Debian/Ubuntu: apt install libjmac-java '
                      'default-jre-headless).')
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('ape')
    checks = []

    def source(name, rate, channels, bits, duration, expression):
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                              f"aevalsrc='{expression}':s={rate}:d={duration}", '-ac', str(channels), '-f',
                              {8: 'u8', 16: 's16le', 24: 's24le'}[bits], '-'], stdout=subprocess.PIPE,
                             check=True).stdout
        wav = work / f'{name}.wav'
        plain_wav(wav, raw, rate, channels, bits)
        return wav, floats(pcm_values(raw, bits), bits, channels)

    def jmac(wav, level, ape):
        if not ape.exists():
            run(['java', '-jar', JMAC, f'c{level}', wav, ape])

    # JMAC fixtures: lossless, and FFmpeg's decode.
    sources = [('stereo', 44100, 2, 16, 5, STEREO), ('loud', 44100, 2, 16, 3, LOUD),
               ('stereo8', 22050, 2, 8, 4, STEREO), ('stereo24', 48000, 2, 24, 4, STEREO),
               ('loud24', 96000, 2, 24, 3, LOUD), ('mono', 22050, 1, 16, 4, MONO), ('mono8', 8000, 1, 8, 4, MONO),
               ('mono24', 32000, 1, 24, 3, MONO), ('hires', 192000, 2, 24, 1, STEREO),
               ('silence', 44100, 2, 16, 3, '0|0'), ('dual', 44100, 2, 16, 3, MONO + '|' + MONO)]
    fixtures = {}
    ffmpeg_crc_failures = []
    for name, rate, channels, bits, duration, expression in sources:
        wav, want = source(name, rate, channels, bits, duration, expression)
        for level in range(1, 6):
            if name in ('silence', 'dual', 'hires') and level not in (2, 5):
                continue
            ape = work / f'{name}-{level}.ape'
            jmac(wav, level, ape)
            ours, code, stats = lamp_decode(ape)
            if code or ours != want:
                raise Failure(f'{ape.name}: exit {code}, {len(ours) // 8} frames, not the source\'s '
                              f'{len(want) // 8} exactly: {stats}')
            native, error = ffmpeg_decode(ape)
            if native != ours:
                if not (bits == 24 and channels == 2 and level == 5 and 'CRC mismatch' in error):
                    raise Failure(f'{ape.name}: differs from FFmpeg ({error[:120]})')
                ffmpeg_crc_failures.append(ape.name)
                comparator = 'the source (FFmpeg fails its CRC check)'
            else:
                comparator = 'the source and FFmpeg'
            fixtures[ape.name] = ape
            checks.append({'test': ape.name, 'result': 'exact', 'comparator': comparator, 'stats': stats})
        print(f'{name}: {rate} Hz, {channels} channels, {bits} bits: exact against the source'
              f'{"" if name + "-5.ape" not in ffmpeg_crc_failures else " (FFmpeg fails its CRC at level 5000)"}',
              flush=True)
    # Several frames at levels 4000 (294912 blocks) and 5000 (1179648).
    wav, want = source('long', 44100, 2, 16, 30, STEREO)
    for level in (1, 4, 5):
        ape = work / f'long-{level}.ape'
        jmac(wav, level, ape)
        ours, code, stats = lamp_decode(ape)
        native, error = ffmpeg_decode(ape)
        if code or ours != want or native != ours:
            raise Failure(f'{ape.name}: exit {code}, not exact against the source and FFmpeg ({error[:100]})')
        fixtures[ape.name] = ape
        checks.append({'test': ape.name, 'result': 'exact', 'comparator': 'the source and FFmpeg', 'stats': stats})
    print(f'30-second files at levels 1000, 4000 and 5000: exact; FFmpeg fails its CRC on '
          f'{", ".join(ffmpeg_crc_failures)}', flush=True)

    # Written streams.
    used = set()

    def signal(count, channels, bits, seed, loud=False, impulses=False):
        rng = random.Random(seed)
        peak = (1 << (bits - 1)) - 1
        out = []
        for i in range(count):
            a = 0.4 * math.sin(i * 0.031) + 0.3 * (rng.random() - 0.5)
            b = 0.3 * math.sin(i * 0.047 + 1) + 0.2 * (rng.random() - 0.5)
            if loud:
                a = 0.97 * math.copysign(1, math.sin(i * 0.01)) * (0.6 + 0.4 * rng.random())
                b = -0.95 * math.sin(i * 0.02)
            if impulses and i % 997 == 500:
                a = 0.99
            frame = (max(-peak - 1, min(peak, round(a * peak))), max(-peak - 1, min(peak, round(b * peak))))
            out.append(frame[:channels])
        return out

    def written(name, pcm, channels, bits, rate, version, level, **options):
        data, features = vectors.write(pcm, channels, bits, rate, version, level, **options)
        path = work / f'{name}.ape'
        path.write_bytes(data)
        want = floats([x for frame in pcm for x in frame], bits, channels)
        native, error = ffmpeg_decode(path)
        if native != want:
            raise Failure(f'written {name}: FFmpeg does not decode what was written ({error[:120]})')
        ours, code, stats = lamp_decode(path)
        if code or ours != want:
            raise Failure(f'written {name}: exit {code}, differs from the written PCM: {stats}')
        used.update(features)
        checks.append({'test': f'written {name}', 'result': 'exact', 'comparator': 'written PCM and FFmpeg',
                       'features': sorted(features)})
        return path

    for version in (3930, 3940, 3950, 3960, 3970, 3980, 3985, 3990):
        for level in (1, 2, 3):
            written(f'v{version}-{level}', signal(12000, 2, 16, version + level), 2, 16, 44100, version, level,
                    frame_blocks=5000)
        written(f'v{version}-mono', signal(9000, 1, 16, version), 1, 16, 22050, version, 2, frame_blocks=7001)
    written('v3990-4', signal(3000, 2, 16, 41), 2, 16, 44100, 3990, 4, frame_blocks=1700)
    written('v3990-5', signal(3000, 2, 16, 13), 2, 16, 44100, 3990, 5, frame_blocks=1000)
    written('v3970-5', signal(3000, 2, 16, 13), 2, 16, 44100, 3970, 5)
    written('v3940-4', signal(3000, 2, 16, 14), 2, 16, 44100, 3940, 4)
    loud = signal(9000, 2, 24, 5, loud=True)
    written('wide24', loud, 2, 24, 48000, 3990, 2, frame_blocks=20000, wide=True)
    written('narrow24', loud, 2, 24, 48000, 3990, 2, frame_blocks=20000)
    written('wide24-3950', loud, 2, 24, 48000, 3950, 1, wide=True)
    written('impulses24', signal(6000, 2, 24, 6, impulses=True), 2, 24, 44100, 3990, 1, frame_blocks=6000)
    written('impulses24-3940', signal(6000, 2, 24, 6, impulses=True), 2, 24, 44100, 3940, 1)
    written('stereo8', signal(6000, 2, 8, 7), 2, 8, 8000, 3990, 3, frame_blocks=2500)
    written('mono8-3960', signal(6000, 1, 8, 8), 1, 8, 8000, 3960, 2)
    zero = [(0, 0)] * 3000
    mix = zero + [(x, x) for x, _ in signal(3000, 2, 16, 9)] + signal(3000, 2, 16, 10)
    written('flags', mix, 2, 16, 44100, 3990, 2, frame_blocks=3000, flags=lambda i: [3, 4, 0][i])
    written('flags-3950', mix[:3000], 2, 16, 44100, 3950, 2, flags=lambda i: 7)
    written('one-silent-flag', signal(3000, 2, 16, 11), 2, 16, 44100, 3990, 2, frame_blocks=3000, flags=lambda i: 1)
    written('mono-silence', [(0,)] * 2000 + signal(2000, 1, 16, 12), 1, 16, 44100, 3990, 2, frame_blocks=2000,
            flags=lambda i: [1, None][i])
    written('header-options', signal(4000, 2, 16, 15), 2, 16, 44100, 3950, 2, peak=True, seek_count=True,
            tail=b'LIST\x04\0\0\0INFO')
    written('no-wav-header', signal(4000, 2, 16, 16), 2, 16, 44100, 3940, 1, wav_header=False, tail=b'junk' * 3)
    written('no-wav-header-3990', signal(4000, 2, 16, 17), 2, 16, 44100, 3990, 1, wav_header=False, frame_blocks=999)
    # Frames of the earlier fixed sizes: 73728 blocks before 3950, 294912 from it.
    multi_3940 = written('frames-3940', signal(160000, 1, 8, 18), 1, 8, 8000, 3940, 1)
    multi_3970 = written('frames-3970', signal(300000, 1, 8, 19), 1, 8, 8000, 3970, 1)
    missing = REQUIRED - used
    if missing:
        raise Failure(f'features not written: {sorted(missing)}')
    checks.append({'test': 'coverage', 'result': 'passed', 'features': sorted(used)})
    print(f'{sum(1 for c in checks if c["test"].startswith("written"))} written streams: exact against the PCM '
          f'written and FFmpeg; {len(used)} features covered', flush=True)

    # Seeks.
    for path in (fixtures['stereo-1.ape'], fixtures['long-4.ape'], fixtures['long-5.ape'],
                 fixtures['loud24-3.ape'], fixtures['mono8-2.ape'], multi_3940, multi_3970, work / 'flags.ape'):
        reference = Path(str(path) + '.f32')
        decode_f32(path, reference)
        line = run([seek, path, reference, '0']).strip().splitlines()[-1]
        checks.append({'test': f'{path.name} seeks', 'result': line})
    print('seeks equal continuous decoding in 8 files', flush=True)

    # Tags.
    base = fixtures['stereo-2.ape']
    reference = lamp_decode(base)[0]
    image = work / 'cover.png'
    if not image.exists():
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=16x16', '-frames:v', '1',
                        str(image)], check=True)
    image_bytes = image.read_bytes()

    def ape_tag(items):
        body = b''.join(struct.pack('<II', len(value), flags) + key.encode() + b'\0' + value
                        for key, value, flags in items)
        size = len(body) + 32
        return b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0xa0000000) + bytes(8) + body + \
            b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0x80000000) + bytes(8)
    tagged = work / 'tagged.ape'
    id3 = b'TIT2' + struct.pack('>I', 6) + b'\0\0\0ID3v2'
    tagged.write_bytes(b'ID3\x04\0\0' + bytes([0, 0, 0, len(id3)]) + id3 + base.read_bytes() +
                       ape_tag([('Title', b'APE title', 0), ('Artist', b'APE artist', 0),
                                ('Cover Art (Front)', b'cover.png\0' + image_bytes, 2)]))
    ours, code, _ = lamp_decode(tagged)
    if code or ours != reference:
        raise Failure('tagged.ape: differs from the untagged decode')
    tags = subprocess.run([str(lamp_cli()), '--tags', str(tagged)], stdout=subprocess.PIPE).stdout.decode()
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=title,artist', '-of',
                            'default=nw=1', str(tagged)], stdout=subprocess.PIPE).stdout.decode()
    if 'title=APE title' not in tags or 'artist=APE artist' not in tags or 'tag:title=ape title' not in probe.lower():
        raise Failure(f'tagged.ape tags: {tags!r}, ffprobe {probe!r}')
    cover = work / 'cover.out'
    if cover.exists():
        cover.unlink()
    run([lamp_cli(), '--cover', tagged, cover])
    if cover.read_bytes() != image_bytes:
        raise Failure('tagged.ape: --cover did not write the APEv2 picture')
    checks.append({'test': 'ID3v2 and APEv2 tags', 'result': 'decode unchanged; the APEv2 title, artist and cover '
                   'read, the ID3v2 title ignored as FFmpeg ignores it',
                   'tags': tags.strip().splitlines()})
    print('ID3v2 before and APEv2 after: decode unchanged, APEv2 title, artist and cover read', flush=True)

    # Damage.
    def stopped(name, data, note):
        path = work / name
        path.write_bytes(data)
        ours, code, stats = lamp_decode(path)
        native, _ = ffmpeg_decode(path, crc=False)
        if code != 2 or 'decode_error=100' not in ' '.join(stats) or not native.startswith(ours):
            raise Failure(f'{name}: exit {code}, {len(ours) // 8} frames, not a prefix of FFmpeg\'s: {stats}')
        checks.append({'test': name, 'result': f'{note}; stopped with decode_error 100 after {len(ours) // 8} '
                       f'frames, a prefix of FFmpeg\'s {len(native) // 8}'})
        print(f'{name}: {note}, stopped after {len(ours) // 8} of FFmpeg\'s {len(native) // 8} frames', flush=True)
        return len(ours) // 8
    long = fixtures['long-1.ape'].read_bytes()
    flipped = bytearray(long)
    flipped[len(long) // 2] ^= 0x10
    if stopped('flipped.ape', bytes(flipped), 'a flipped bit fails its frame\'s CRC') < 73728:
        raise Failure('flipped.ape stopped before the damaged frame')
    stopped('cut.ape', long[:len(long) - 5000], 'cut inside the last frame')
    descriptor = struct.unpack_from('<I', long, 8)[0]
    frames = struct.unpack_from('<I', long, descriptor + 12)[0]
    table = descriptor + 24
    last = struct.unpack_from('<I', long, table + 4 * (frames - 1))[0]
    stopped('missing.ape', long[:last], 'cut where the last frame starts')

    def rejected(name, data, error):
        path = work / name
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != error:
            raise Failure(f'{name}: expected decode_error {error}, got {line}')
        checks.append({'test': name, 'result': f'rejected with decode_error {error}', 'oracle': line})

    def patched(data, offset, value, fmt='<I'):
        data = bytearray(data)
        struct.pack_into(fmt, data, offset, value)
        return bytes(data)
    header = descriptor
    rejected('decreasing.ape', patched(long, table + 8, struct.unpack_from('<I', long, table + 4)[0] - 4), 100)
    rejected('level-6000.ape', patched(long, header, 6000, '<H'), 100)
    rejected('level-1500.ape', patched(long, header, 1500, '<H'), 100)
    rejected('no-frames.ape', patched(long, header + 12, 0), 100)
    rejected('final-too-long.ape', patched(long, header + 8, struct.unpack_from('<I', long, header + 4)[0] + 1), 100)
    rejected('short-descriptor.ape', patched(long, 8, 40), 100)
    rejected('version-3920.ape', patched(long, 4, 3920, '<H'), 101)
    rejected('version-3991.ape', patched(long, 4, 3991, '<H'), 101)
    rejected('three-channels.ape', patched(long, header + 18, 3, '<H'), 101)
    rejected('32-bit.ape', patched(long, header + 16, 32, '<H'), 101)
    rejected('7-khz.ape', patched(long, header + 20, 7000), 101)
    print('malformed headers reject with decode_error 100; unsupported versions and formats with 101', flush=True)
    line = run([chain, 'cancel-open', fixtures['long-5.ape']]).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open long-5.ape', 'result': line})

    # Speed: a minute of 44.1 kHz stereo at each level.
    minute, _ = source('minute', 44100, 2, 16, 60, STEREO)
    speed = {}
    for level in (1, 2, 3, 4, 5):
        ape = work / f'minute-{level}.ape'
        jmac(minute, level, ape)
        timings = []
        for command in ([str(lamp_cli()), '--check', str(ape)],
                        ['ffmpeg', '-v', 'quiet', '-threads', '1', '-i', str(ape), '-f', 'null', '-']):
            best = None
            for _ in range(3):
                start = time.perf_counter()
                subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                elapsed = time.perf_counter() - start
                best = elapsed if best is None else min(best, elapsed)
            timings.append(round(best, 3))
        speed[f'level {level}000'] = {'lamp_s': timings[0], 'ffmpeg_s': timings[1]}
    checks.append({'test': 'speed', 'result': 'a 60-second 44.1 kHz stereo file, best of three', 'seconds': speed})
    print(f'60 s of 44.1 kHz stereo (LAMP, FFmpeg command line): {speed}', flush=True)

    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'APE playback', 'result': 'played', 'stats': play(fixtures['stereo24-5.ape'])})
    write_report('ape', {'result': 'passed', 'checks': checks,
                         'ffmpeg_crc_failures': ffmpeg_crc_failures,
                         'scope': 'JMAC fixtures at every level, exact against their sources and FFmpeg; written '
                                  'streams of versions 3930-3990; seeks; tags and covers; damage, malformed and '
                                  'unsupported files; cancellation; speed.'})
    print(f'Passed {len(checks)} Monkey\'s Audio checks.')


if __name__ == '__main__':
    main_guard(main)
