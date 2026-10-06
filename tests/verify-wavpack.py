#!/usr/bin/env python3
"""WavPack decoding against FFmpeg and the decoder model.

usage: python3 tests/verify-wavpack.py [--skip-playback]
- FFmpeg's encoder writes .wv fixtures: 8-, 16-, 24- and 32-bit integer and
  float samples (float blocks carry extra bits), compression levels 0-8,
  joint stereo on and off, mono, false stereo, 3 to 8 channels, standard and
  custom sample rates, blocks beyond 65536 samples. LAMP's decode must equal
  FFmpeg's exactly; layouts beyond stereo are compared with FFmpeg's channels
  mixed with LAMP's speaker weights, as pcm_build_mix normalizes them.
- Matroska copies (A_WAVPACK4) decode exactly as the .wv files.
- Streams written by tests/wavpack_vectors.py cover what FFmpeg's encoder
  never writes: hybrid (lossy) blocks with and without the bit-rate mode,
  integer extra bits, the zero, one and duplicate shifts, lossy 32-bit audio,
  every decorrelation term and delta, blocks without terms, float details
  sent as extra bits, header shifts, extended channel information, ignored
  surplus blocks, long and odd sub-block sizes, unknown sub-blocks and every
  wp_exp2 input. The model, FFmpeg (checking CRCs) and LAMP agree exactly,
  except for mono blocks without terms, where FFmpeg outputs silence (and
  fails its own CRC check): there LAMP is compared with the model, which
  passes the residuals through as libwavpack does.
- The model reproduces FFmpeg's decode of a subset of the encoder fixtures.
- Seeks equal continuous decoding; ID3v2 and APE tags and truncated files;
  DSD, unknown versions, low rates and more than eight channels reject as
  unsupported; damaged blocks and missing channels stop decoding with
  decode_error 100; a cancelled open stops cleanly.
Writes <out>/wavpack-verification.json.
"""
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wavpack_model as model
import wavpack_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, check_file, decode_f32, exe, ffmpeg, main_guard, out_dir,
                       play, playback_requested, run, scratch, stereo_view, write_report)

REQUIRED = {'term 1', 'term 2', 'term 3', 'term 4', 'term 5', 'term 6', 'term 7', 'term 8', 'term 17', 'term 18',
            'term -1', 'term -2', 'term -3', 'zero run', 'escaped ones', 'error limit', 'hybrid', 'hybrid bitrate',
            'joint stereo', 'false stereo', 'extra bits', 'integer extra bits', 'shift with zeros',
            'shift with ones', 'shift duplicating the low bit', 'lossy 32-bit clipped as 24-bit', 'header shift',
            'float beyond 24 bits', 'float shift with ones', 'float shift with the same bits',
            'float shift with sent bits', 'float zeros sent', 'channel info', 'custom sample rate'}


def layout(data):
    """(channels, mask) of a .wv file as FFmpeg's decoder sets them from the
    first block."""
    for h, body in model.blocks(data):
        if not h['samples']:
            continue
        flags = h['flags']
        if flags & model.INITIAL and flags & model.FINAL:
            return (1, 4) if flags & model.MONO else (2, 3)
        for ident, payload, _ in model.subblocks(body):
            if ident == 0xd:
                chan, extra = payload[0], len(payload) - 2
                if extra in (4, 5):
                    return (payload[0] | (payload[2] & 0xf) << 8) + 1, int.from_bytes(payload[3:], 'little')
                mask = int.from_bytes(payload[1:], 'little')
                return (bin(mask).count('1') if mask else chan), mask
    raise Failure('no channel information')


def ffmpeg_native(path, output, tolerated=None):
    """FFmpeg's decode with CRC checks -> float32 bytes; fails on a CRC error
    or any other message except the tolerated one."""
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-err_detect', 'crccheck', '-i',
                             str(path), '-f', 'f32le', str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = result.stdout.decode('utf-8', 'replace')
    lines = [line for line in text.splitlines() if not (tolerated and line.endswith(tolerated.split(': ')[-1]))]
    if result.returncode or 'error' in '\n'.join(lines).lower():
        raise Failure(f'FFmpeg on {Path(path).name}: {text.strip()[:300]}')
    return Path(output).read_bytes()


class Suite:
    def __init__(self, work):
        self.work = work
        self.checks = []
        self.used = set()

    def lamp(self, path):
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        return ours.read_bytes(), stats.splitlines()[-1]

    def against_ffmpeg(self, path, note, tolerated=None):
        data = Path(path).read_bytes()
        channels, mask = layout(data)
        native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'), tolerated)
        ours, stats = self.lamp(path)
        if ours != stereo_view(native, channels, mask):
            raise Failure(f'{Path(path).name}: differs from FFmpeg')
        self.checks.append({'test': Path(path).name, 'result': 'exact', 'comparator': 'FFmpeg' if channels <= 2 else
                            'FFmpeg channels mixed with LAMP weights', 'channels': channels, 'layout': note,
                            'stats': stats})
        return native

    def model_check(self, path):
        data = Path(path).read_bytes()
        pcm, channels, rate, used = model.decode(data)
        native = ffmpeg_native(path, Path(str(path) + '.model.f32'))
        if pcm != native:
            raise Failure(f'model on {Path(path).name}: differs from FFmpeg')
        self.used |= used
        self.checks.append({'test': f'model on {Path(path).name}', 'result': 'exact', 'comparator': 'FFmpeg',
                            'features': sorted(used)})

    def written(self, name, frames, against_ffmpeg=True, seed=None, **options):
        data, pcm, channels, used = vectors.stream(seed if seed is not None else len(self.checks) + 1, frames,
                                                   **options)
        path = self.work / f'{name}.wv'
        path.write_bytes(data)
        self.used |= used
        _, mask = layout(data)
        ours, stats = self.lamp(path)
        if against_ffmpeg:
            native = ffmpeg_native(path, Path(str(path) + '.ffmpeg.f32'))
            if native != pcm:
                raise Failure(f'{name}: FFmpeg differs from the model')
        if ours != stereo_view(pcm, channels, mask):
            raise Failure(f'{name}: LAMP differs from the model')
        self.checks.append({'test': f'{name}.wv', 'result': 'exact',
                            'comparator': 'model and FFmpeg' if against_ffmpeg else 'model',
                            'channels': channels, 'features': sorted(used), 'stats': stats})
        print(f'{name}: exact ({len(used)} features)', flush=True)
        return path


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    run([sys.executable, Path(__file__).resolve().parent / 'generate-wavpack-tables.py', '--check'])
    work = scratch('wavpack')
    suite = Suite(work)
    checks = suite.checks

    # FFmpeg's encoder.
    def source(rate, channels, duration, seed=0):
        tones = '|'.join(f'0.3*sin(2*PI*{110 * (k + 2) + seed}*t+{k})+0.2*sin(2*PI*{37 * (k + 1)}*t)'
                         f'+0.1*random({k})-0.05' for k in range(channels))
        return ['-f', 'lavfi', '-i', f'aevalsrc={tones}:s={rate}:d={duration}']

    layouts = {1: 'mono', 2: 'stereo', 3: '3.0', 4: 'quad', 6: '5.1', 8: '7.1'}
    fixtures = [(f'c{level}', 44100, 2, 2, ['-sample_fmt', 's16p', '-compression_level', str(level)])
                for level in range(9)]
    fixtures += [
        ('joint-off', 44100, 2, 2, ['-sample_fmt', 's16p', '-joint_stereo', '0']),
        ('joint-on', 44100, 2, 2, ['-sample_fmt', 's16p', '-joint_stereo', '1']),
        ('u8', 44100, 2, 2, ['-sample_fmt', 'u8p']),
        ('s32', 48000, 2, 2, ['-sample_fmt', 's32p']),
        ('float', 48000, 2, 2, ['-sample_fmt', 'fltp']),
        ('mono-s16', 44100, 1, 2, ['-sample_fmt', 's16p']),
        ('mono-float', 44100, 1, 2, ['-sample_fmt', 'fltp']),
        ('3.0', 48000, 3, 1, ['-sample_fmt', 's16p']),
        ('quad', 48000, 4, 1, ['-sample_fmt', 's16p']),
        ('5.1', 48000, 6, 1, ['-sample_fmt', 's16p']),
        ('5.1-float', 48000, 6, 1, ['-sample_fmt', 'fltp']),
        ('7.1', 48000, 8, 1, ['-sample_fmt', 's32p']),
        ('mono-8k', 8000, 1, 3, ['-sample_fmt', 's16p']),
        ('r22050', 22050, 2, 2, ['-sample_fmt', 's16p']),
        ('r96k', 96000, 2, 1, ['-sample_fmt', 's32p']),
        ('mono-192k', 192000, 1, 1, ['-sample_fmt', 's16p']),        # 96000-sample blocks
        ('r37800', 37800, 2, 2, ['-sample_fmt', 's16p']),           # custom rate
        ('r11025', 11025, 2, 2, ['-sample_fmt', 'fltp']),
        ('long', 48000, 2, 20, ['-sample_fmt', 's16p']),
    ]
    for k, (name, rate, channels, duration, coding) in enumerate(fixtures):
        path = work / f'{name}.wv'
        ffmpeg(*source(rate, channels, duration, k), '-af', f'aformat=channel_layouts={layouts[channels]}',
               '-c:a', 'wavpack', *coding, path)
        suite.against_ffmpeg(path, f'{rate} Hz, {layouts[channels]}, {" ".join(coding)}')
        print(f'{name}.wv: exact', flush=True)
    # 24-bit audio is 32-bit blocks with a shift; false stereo needs equal channels.
    wav = work / 's24.wav'
    ffmpeg(*source(44100, 2, 2, 50), '-c:a', 'pcm_s24le', wav)
    ffmpeg('-i', wav, '-c:a', 'wavpack', work / 's24.wv')
    suite.against_ffmpeg(work / 's24.wv', '24-bit source, 32-bit blocks with INT32INFO')
    ffmpeg('-f', 'lavfi', '-i', 'aevalsrc=0.4*sin(2*PI*440*t)+0.1*random(0):s=44100:d=2', '-af', 'pan=stereo|c0=c0|c1=c0',
           '-c:a', 'wavpack', '-sample_fmt', 's16p', '-optimize_mono', '1', work / 'false-stereo.wv')
    suite.against_ffmpeg(work / 'false-stereo.wv', 'equal channels as false stereo')
    for name in ('c8', 'float', 's24', 'false-stereo', 'r37800', '5.1-float', 'u8'):
        suite.model_check(work / f'{name}.wv')
        print(f'model on {name}.wv: exact', flush=True)
    fixture_count = len(fixtures) + 2

    # Matroska copies decode as the .wv files.
    for name in ('c8', 'mono-s16', 'float', '5.1', '7.1', 'false-stereo', 'r37800', 'mono-192k', 'long'):
        mka = work / f'{name}.mka'
        ffmpeg('-i', work / f'{name}.wv', '-c', 'copy', mka)
        ours, stats = suite.lamp(mka)
        if ours != Path(str(work / f'{name}.wv') + '.f32').read_bytes():
            raise Failure(f'{mka.name}: differs from the .wv decode')
        checks.append({'test': mka.name, 'result': 'exact', 'comparator': f'{name}.wv', 'stats': stats})
    print('Matroska copies exact', flush=True)

    # Written streams.
    r = random.Random(7)
    spec = vectors.random_spec

    def frames(count, samples, make):
        return [(samples, make(i)) for i in range(count)]

    suite.written('hybrid-stereo', frames(4, 3000, lambda i: [spec(r, hybrid=True)]))
    suite.written('hybrid-mono', frames(3, 3000, lambda i: [spec(r, stereo=False, hybrid=True)]))
    suite.written('hybrid-bitrate', frames(4, 3000, lambda i: [spec(r, hybrid=True, bitrate=True)]))
    suite.written('hybrid-bitrate-mono', frames(3, 3000, lambda i: [spec(r, stereo=False, hybrid=True, bitrate=True)]))
    suite.written('hybrid-24', frames(3, 2000, lambda i: [spec(r, bytes_=3, hybrid=True, bitrate=i & 1)]))
    suite.written('hybrid-32-shift', frames(4, 2000, lambda i: [spec(r, bytes_=4, hybrid=True, bitrate=i & 1,
                                                                    int32=(0, 9 + i, 0, 0))]))
    suite.written('hybrid-float', frames(2, 2000, lambda i: [spec(r, bytes_=4, float_=True, hybrid=True,
                                                                 float_info=(0, 0, 150, ), extra=bool(i))]))
    shifts = [(0, 3, 0, 0), (0, 0, 2, 0), (0, 0, 0, 4), (0, 8, 0, 0), (0, 0, 7, 0), (0, 0, 0, 1)]
    # Streams keep one sample format and channel count (LAMP stops at a change)
    # and one bit depth (FFmpeg's demuxer rejects a change).
    suite.written('int32-shifts', [(1500, [spec(r, bytes_=4, int32=s)]) for s in shifts])
    suite.written('int32-shifts-16', [(1500, [spec(r, bytes_=2, int32=(0, 0, 3, 0))]),
                                      (1500, [spec(r, bytes_=2, int32=(0, 0, 0, 2))])])
    suite.written('extra-bits', [(1500, [spec(r, bytes_=4, int32=(e, 0, 0, 0), extra=True)]) for e in (8, 3, 12, 1)])
    suite.written('extra-bits-24', [(1500, [spec(r, bytes_=3, int32=(e, 0, 0, 0), extra=True)]) for e in (1, 5)])
    suite.written('extra-bits-16', [(1500, [spec(r, bytes_=2, int32=(4, 0, 0, 0), extra=True)])])
    suite.written('extra-bits-mono', [(1500, [spec(r, stereo=False, bytes_=4, int32=(6, 0, 0, 0), extra=True)])])
    floats = [(1, 0, 150), (2, 0, 150), (4, 0, 150), (8, 0, 150), (0x18, 2, 150), (0x1f, 3, 140), (0, 0, 20),
              (4, 0, 24), (8, 1, 30), (2, 6, 127), (0x10, 0, 0)]
    suite.written('float-extras', [(1200, [spec(r, bytes_=4, float_=True, float_info=f, extra=True)])
                                   for f in floats], policy={'flt': {'amplitude': 1 << 22, 'silence': 0.01}})
    suite.written('float-plain', [(1200, [spec(r, bytes_=4, float_=True, float_info=f)]) for f in floats[:6]])
    suite.written('float-plain-mono', [(1200, [spec(r, stereo=False, bytes_=4, float_=True, float_info=f)])
                                       for f in floats[6:]])
    # Every term with every delta: block k gives term j the delta (j + k) & 7.
    suite.written('terms-stereo', [(800, [spec(r, terms=[(t, (j + k) & 7) for j, t in enumerate(vectors.STEREO_TERMS)])])
                                   for k in range(8)])
    suite.written('terms-mono', [(800, [spec(r, stereo=False, terms=[(t, (j + k) & 7)
                                                                    for j, t in enumerate(vectors.MONO_TERMS)])])
                                 for k in range(8)])
    suite.written('no-terms-stereo', frames(2, 1500, lambda i: [spec(r, terms=[], joint=bool(i))]))
    suite.written('no-terms-mono', frames(2, 1500, lambda i: [spec(r, stereo=False, terms=[])]), against_ffmpeg=False)
    suite.written('false-stereo-written', frames(2, 2000, lambda i: [spec(r, false_stereo=True, hybrid=bool(i))]))
    suite.written('header-shift-8', [(1500, [spec(r, bytes_=1)]), (1500, [spec(r, bytes_=1, shift=4)])])
    suite.written('header-shift-16', frames(2, 1500, lambda i: [spec(r, bytes_=2, shift=3 - 2 * i)]))
    suite.written('header-shift-24', frames(2, 1500, lambda i: [spec(r, bytes_=3, shift=5 - i)]))
    suite.written('quiet', frames(3, 4000, lambda i: [spec(r)]), policy={'silence': 0.02, 'runs': 0.8})
    suite.written('quiet-mono', frames(2, 4000, lambda i: [spec(r, stereo=False)]),
                  policy={'silence': 0.02, 'runs': 0.8})

    # Multichannel frames and channel information.
    def channel_frame(groups, info, count=None, **options):
        blocks = []
        for k, stereo in enumerate(groups):
            b = spec(r, stereo=stereo, **options)
            if k == 0:
                b['channel_info'] = info
                b['channels'] = count or sum(2 if s else 1 for s in groups)
            blocks.append(b)
        return blocks

    suite.written('5.1-written', frames(2, 1500, lambda i: channel_frame([True, False, False, True],
                                                                         [6, 0x3f, 0, 0, 0])))
    suite.written('quad-1-byte-mask', frames(2, 1500, lambda i: channel_frame([True, True], [4, 0x33])))
    suite.written('3.0-2-byte-mask', frames(2, 1500, lambda i: channel_frame([True, False], [3, 0x07, 0x00])))
    suite.written('7.1-3-byte-mask', frames(2, 1200, lambda i: channel_frame([True, False, False, True, True],
                                                                             [8, 0x3f, 0x06, 0x00], hybrid=True)))
    suite.written('6-default-layout', frames(2, 1200, lambda i: channel_frame([True, True, True], [6, 0])))
    suite.written('5.1-extended-info', frames(2, 1200, lambda i: channel_frame([True, False, False, True],
                                                                               [5, 3, 0, 0x3f, 0, 0])))
    suite.written('surplus-block', frames(2, 1200, lambda i: channel_frame([True, False, True], [3, 0x07], count=3)))
    suite.written('side-pair', frames(2, 1200, lambda i: channel_frame([False, False], [2, 0x00, 0x06])))
    custom = [(1500, [dict(spec(r), rate=37800)])]
    suite.written('custom-rate', custom, rate_code=15)
    long_sizes = []
    for i in range(3):
        b = spec(r, extra=bool(i), bytes_=4, int32=(2, 0, 0, 0) if i else None)
        b['long'] = True
        b['unknown'] = [(0x21, bytes(range(7))), (0x26, bytes(16)), (0x3f, b'\x01')]
        long_sizes.append((1000, [b]))
    suite.written('long-sizes', long_sizes)
    # Every wp_exp2 input as decorrelation history (17/18 terms, 64 words a block).
    sweep, word = [], 0
    while word < 0x10000:
        terms = [(17 + (k & 1), k & 7) for k in range(16)]
        b = spec(r, bytes_=3, terms=terms)
        b['weights'] = [(r.randint(-128, 127), r.randint(-128, 127)) for _ in terms]
        b['history'] = [w - 0x10000 if w & 0x8000 else w for w in range(word, word + 64)]
        sweep.append((16, [b]))
        word += 64
    suite.written('exp2-sweep', sweep, policy={'amplitude': 1 << 18})
    written_count = sum(1 for c in checks if c.get('comparator') in ('model and FFmpeg', 'model'))

    missing = REQUIRED - suite.used
    if missing:
        raise Failure(f'features not covered: {sorted(missing)}')
    checks.append({'test': 'coverage', 'result': 'passed', 'features': sorted(suite.used)})

    # Seeks.
    for name in ('long.wv', 'long.mka', 'hybrid-stereo.wv', '5.1.wv', 'mono-192k.wv'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Tags and truncation.
    long = (work / 'long.wv').read_bytes()
    reference = Path(str(work / 'long.wv') + '.f32').read_bytes()
    ffmpeg('-i', work / 'long.wv', '-c', 'copy', '-metadata', 'title=LAMP', '-metadata', 'artist=WavPack test',
           work / 'tagged.wv')
    if b'APETAGEX' not in (work / 'tagged.wv').read_bytes():
        raise Failure('FFmpeg wrote no APE tag')
    tag = b'TIT2' + struct.pack('>I', 5) + b'\0\0\0LAMP'
    (work / 'id3.wv').write_bytes(b'ID3\x04\0\0' + bytes([0, 0, 0, len(tag)]) + tag + long)
    for name in ('tagged.wv', 'id3.wv'):
        ours, stats = suite.lamp(work / name)
        if ours != reference:
            raise Failure(f'{name}: differs from the untagged decode')
        checks.append({'test': name, 'result': 'exact', 'comparator': 'long.wv', 'stats': stats})
    truncated = work / 'truncated.wv'
    truncated.write_bytes(long[:len(long) * 2 // 3])
    suite.against_ffmpeg(truncated, 'cut inside a frame: the complete frames play',
                         tolerated='Input/output error')

    # Rejections.
    def blocks_of(data):
        pos, out = 0, []
        while pos + 32 <= len(data) and data[pos:pos + 4] == b'wvpk':
            size = struct.unpack_from('<I', data, pos + 4)[0]
            out.append(pos)
            pos += size + 8
        return out

    def patched(data, field, value, fmt='<I', first_only=False):
        data = bytearray(data)
        for pos in blocks_of(bytes(data))[:1 if first_only else None]:
            if field == 'flags':
                struct.pack_into('<I', data, pos + 24, struct.unpack_from('<I', data, pos + 24)[0] | value)
            else:
                struct.pack_into(fmt, data, pos + field, value)
        return bytes(data)

    c8 = (work / 'c8.wv').read_bytes()
    nine = []
    for i in range(1):
        nine.append((800, channel_frame([True, True, True, True, False], [9, 0xff, 0x01])))
    nine_data, _, _, _ = vectors.stream(99, nine)
    unsupported = {'dsd.wv': patched(c8, 'flags', model.DSD), 'version-401.wv': patched(c8, 8, 0x401, '<H'),
                   'version-411.wv': patched(c8, 8, 0x411, '<H'), 'nine-channels.wv': nine_data}
    ffmpeg(*source(6000, 1, 1), '-c:a', 'wavpack', '-sample_fmt', 's16p', work / 'rate-6000.wv')
    unsupported['rate-6000.wv'] = (work / 'rate-6000.wv').read_bytes()
    rejected = 0
    for name, data in unsupported.items():
        (work / name).write_bytes(data)
        line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 101:
            raise Failure(f'{name}: expected decode_error 101, got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
        rejected += 1
    empty = bytearray(c8[:blocks_of(c8)[1]])
    struct.pack_into('<I', empty, 20, 0)
    malformed = {'garbage.wv': b'wvpk' + struct.pack('<IH', 1000, 0x410) + bytes(range(256)) * 4,
                 'no-audio.wv': bytes(empty), 'short-header.wv': c8[:40]}
    for name, data in malformed.items():
        (work / name).write_bytes(data)
        line = run([chain, 'reject', work / name]).strip().splitlines()[-1]
        if json.loads(line).get('decode_error') != 100:
            raise Failure(f'{name}: expected decode_error 100, got {line}')
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
        rejected += 1
    # Damaged blocks and missing channels stop decoding.
    damaged = bytearray(long)
    third = blocks_of(long)[3]
    damaged[third + 200] ^= 0x5a
    five = (work / '5.1-written.wv').read_bytes()
    starts = blocks_of(five)
    missing = five[:starts[3]] + five[starts[4]:]               # first frame without its last block
    missing = bytearray(missing)
    flags = struct.unpack_from('<I', missing, starts[2] + 24)[0]
    struct.pack_into('<I', missing, starts[2] + 24, flags | model.FINAL)
    for name, data in (('damaged.wv', bytes(damaged)), ('missing-channels.wv', bytes(missing))):
        (work / name).write_bytes(data)
        code, stats = check_file(work / name)
        if not code or 'decode_error=100' not in stats:
            raise Failure(f'{name}: expected decode_error 100, got {code} {stats}')
        checks.append({'test': name, 'result': 'stopped', 'stats': stats.splitlines()[-1]})
        rejected += 1
    try:
        ffmpeg_native(work / 'damaged.wv', work / 'damaged.ffmpeg.f32')
        found = None
    except Failure as error:
        found = str(error).splitlines()[0]
    if not found:
        raise Failure('FFmpeg decoded damaged.wv without an error')
    checks.append({'test': 'damaged.wv in FFmpeg', 'result': 'error reported', 'message': found})
    print(f'Rejected {rejected} unsupported, malformed or damaged files', flush=True)

    line = run([chain, 'cancel-open', work / 'long.wv']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open long.wv', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'WavPack playback', 'result': 'played', 'stats': play(work / 'long.wv')})
    write_report('wavpack', {'result': 'passed', 'checks': checks, 'fixtures': fixture_count,
                             'written_streams': written_count, 'rejections': rejected,
                             'features': sorted(suite.used),
                             'scope': 'WavPack 4/5 lossless and hybrid integer and float audio in .wv files and '
                                      'Matroska, exact against FFmpeg (and the model for written streams); seeks; '
                                      'tags, truncation, unsupported and damaged streams; cancellation.'})
    print(f'Passed {len(checks)} WavPack checks.')


if __name__ == '__main__':
    main_guard(main)
