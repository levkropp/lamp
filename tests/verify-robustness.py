#!/usr/bin/env python3
"""Malformed input across every container and codec: no crash, hang or runaway memory.

usage: python3 tests/verify-robustness.py [--count N] [--seed S] [--wine] [--only NAME,...]
One small file per supported container/codec pairing, written by FFmpeg (or,
for Monkey's Audio, tests/ape_vectors.py), is mutated N times (500 by
default) each:
- **Bytes:** byte flips in the first 4 KiB or anywhere, runs of zero or 0xff
  bytes.
- **Structure:** a cut at any point, a span removed, a span duplicated.
Each mutated file is decoded with lamp-cli --check, and every fourth also
from a random --start (so seek indexes and their searches run on damage).
A run must end by itself within 30 s with exit code 0 (decoded) or 2
(rejected or damaged). On Linux it runs under a 2 GiB address-space limit,
so a runaway allocation fails it too. --wine runs every tenth mutation with
bin/lamp-cli.exe under Wine, where a crash is an exception exit code.
Writes <out>/robustness-verification.json (robustness-wine-verification.json
with --wine).
--only selects source filenames and writes robustness-selected[-wine]-verification.json.
"""
import argparse
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import ROOT, Failure, build_lamp, ffmpeg, lamp_cli, main_guard, scratch, write_report

try:
    import resource                  # Linux: the address-space limit
except ImportError:
    resource = None

NOISE = ['-f', 'lavfi', '-i', 'anoisesrc=r=44100:d=1.2:seed=9:a=0.3', '-ac', '2']
MONO = ['-f', 'lavfi', '-i', 'anoisesrc=r=22050:d=1.2:seed=10:a=0.3', '-ac', '1']
SURROUND = ['-f', 'lavfi', '-i', 'anoisesrc=r=48000:d=1.2:seed=11:a=0.3', '-ac', '6']
PHONE = ['-f', 'lavfi', '-i', 'anoisesrc=r=8000:d=1.2:seed=12:a=0.3', '-ac', '1']
WIDE = ['-f', 'lavfi', '-i', 'anoisesrc=r=16000:d=1.2:seed=13:a=0.3', '-ac', '1']
# (file name, FFmpeg input and output options)
SOURCES = [
    ('pcm16.wav', NOISE + ['-c:a', 'pcm_s16le']),
    ('float.wav', NOISE + ['-c:a', 'pcm_f32le']),
    ('surround.wav', SURROUND + ['-c:a', 'pcm_s24le']),
    ('rf64.wav', NOISE + ['-c:a', 'pcm_s16le', '-rf64', 'always']),
    ('alaw.wav', MONO + ['-c:a', 'pcm_alaw']),
    ('ima.wav', NOISE + ['-c:a', 'adpcm_ima_wav']),
    ('ima-2bit.wav', None),
    ('ima-3bit.wav', None),
    ('ima-5bit.wav', None),
    ('ms.wav', NOISE + ['-c:a', 'adpcm_ms']),
    ('mp3.wav', NOISE + ['-c:a', 'libmp3lame']),
    ('pcm.w64', NOISE + ['-c:a', 'pcm_s16le']),
    ('pcm.aiff', NOISE + ['-c:a', 'pcm_s16be']),
    ('float.aifc', NOISE + ['-c:a', 'pcm_f32be', '-f', 'aiff']),
    ('pcm.caf', NOISE + ['-c:a', 'pcm_s24le']),
    ('alac.caf', NOISE + ['-c:a', 'alac']),
    ('ima4.caf', MONO + ['-c:a', 'adpcm_ima_qt']),
    ('pcm.au', NOISE + ['-c:a', 'pcm_s16be']),
    ('g726.wav', PHONE + ['-c:a', 'g726']),
    ('g722.au', WIDE + ['-c:a', 'g722']),
    ('tone.flac', NOISE + ['-c:a', 'flac']),
    ('surround.flac', SURROUND + ['-c:a', 'flac']),
    ('flac.oga', NOISE + ['-c:a', 'flac', '-f', 'ogg']),
    ('tone.ogg', NOISE + ['-c:a', 'libvorbis']),
    ('surround.ogg', SURROUND + ['-c:a', 'libvorbis']),
    ('tone.opus', NOISE + ['-c:a', 'libopus']),
    ('surround.opus', SURROUND + ['-c:a', 'libopus']),
    ('tone.mp3', NOISE + ['-c:a', 'libmp3lame']),
    ('tone.mp2', NOISE + ['-c:a', 'mp2']),
    ('tone.aac', NOISE + ['-c:a', 'aac']),
    ('tone.loas', NOISE + ['-c:a', 'aac', '-smc-interval', '4', '-f', 'latm']),
    ('low.m4a', NOISE + ['-c:a', 'aac', '-b:a', '48k']),
    ('aac.m4a', NOISE + ['-c:a', 'aac']),
    ('fragmented.m4a', NOISE + ['-c:a', 'aac', '-movflags', 'frag_keyframe+empty_moov']),
    ('alac.m4a', NOISE + ['-c:a', 'alac']),
    ('opus.mp4', NOISE + ['-c:a', 'libopus']),
    ('flac.mp4', NOISE + ['-c:a', 'flac', '-strict', '-2']),
    ('pcm.mov', NOISE + ['-c:a', 'pcm_s16le']),
    ('alaw.mov', NOISE + ['-c:a', 'pcm_alaw']),
    ('ulaw.mov', NOISE + ['-c:a', 'pcm_mulaw']),
    ('ima4.mov', NOISE + ['-c:a', 'adpcm_ima_qt']),
    ('gsm.mov', PHONE + ['-c:a', 'libgsm']),
    ('tone.ac3', SURROUND + ['-c:a', 'ac3']),
    ('ac3.mka', SURROUND + ['-c:a', 'ac3']),
    ('tone.ec3', SURROUND + ['-c:a', 'eac3', '-f', 'eac3']),
    ('written.ec3', []),
    ('ecpl.ec3', []),
    ('ecpl.mka', []),
    ('ecpl.mp4', []),
    ('ecpl.ts', []),
    ('spx.ec3', []),
    ('spx.mka', []),
    ('spx.mp4', []),
    ('spx.ts', []),
    ('aht.ec3', []),
    ('aht.mka', []),
    ('aht.mp4', []),
    ('aht.ts', []),
    ('eac3.mka', SURROUND + ['-c:a', 'eac3']),
    ('eac3.mp4', SURROUND + ['-c:a', 'eac3']),
    ('eac3.ts', SURROUND + ['-c:a', 'eac3']),
    ('vorbis.mka', NOISE + ['-c:a', 'libvorbis']),
    ('flac.mka', NOISE + ['-c:a', 'flac']),
    ('aac.mka', NOISE + ['-c:a', 'aac']),
    ('opus.webm', NOISE + ['-c:a', 'libopus']),
    ('mp3.mka', NOISE + ['-c:a', 'libmp3lame']),
    ('pcm.mka', NOISE + ['-c:a', 'pcm_s16le']),
    ('tone.wv', NOISE + ['-c:a', 'wavpack']),
    ('wv.mka', NOISE + ['-c:a', 'wavpack']),
    ('pcm.avi', NOISE + ['-c:a', 'pcm_s16le']),
    ('mp3.avi', NOISE + ['-c:a', 'libmp3lame']),
    ('aac.avi', NOISE + ['-c:a', 'aac']),
    ('pcm.flv', MONO + ['-c:a', 'pcm_s16le', '-ar', '22050']),
    ('mp3.flv', NOISE + ['-c:a', 'libmp3lame']),
    ('aac.flv', NOISE + ['-c:a', 'aac']),
    ('adpcm.flv', MONO + ['-c:a', 'adpcm_swf', '-ar', '22050']),
    ('mp2.ts', NOISE + ['-c:a', 'mp2']),
    ('aac.ts', NOISE + ['-c:a', 'aac']),
    ('latm.ts', NOISE + ['-c:a', 'aac', '-f', 'mpegts', '-mpegts_flags', 'latm']),
    ('gsm.wav', PHONE + ['-c:a', 'libgsm_ms']),
    ('tone.gsm', PHONE + ['-c:a', 'libgsm', '-f', 'gsm']),
    ('lpcm.vob', NOISE + ['-ar', '48000', '-c:a', 'pcm_dvd', '-sample_fmt', 's32', '-f', 'vob']),
    ('lpcm.m2ts', SURROUND + ['-c:a', 'pcm_bluray', '-sample_fmt', 's16', '-f', 'mpegts', '-mpegts_m2ts_mode', '1']),
    ('ac3.ts', SURROUND + ['-c:a', 'ac3']),
    ('mp2.mpg', NOISE + ['-c:a', 'mp2', '-f', 'mpeg']),
    ('ac3.vob', SURROUND + ['-c:a', 'ac3', '-f', 'vob']),
    ('tone.ape', None),                # Monkey's Audio, written by tests/ape_vectors.py
    ('old.ape', None),
]
LIMIT = 2 << 30                      # address space, Linux


def wine_run(arguments, **options):
    # Wine helpers can inherit the first client's output and hold a pipe open
    # after that client exits. Wait on the process itself, keeping a bounded
    # diagnostic tail, rather than treating a helper's open pipe as a hang.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(arguments, stdout=output, stderr=subprocess.STDOUT, **options)
        output.seek(0, os.SEEK_END)
        output.seek(max(0, output.tell()-1024))
        result.stdout = output.read()
    return result


def mutate(data, rng):
    data = bytearray(data)
    kind = rng.randrange(7)
    if kind == 0:                    # flips near the start: headers
        for _ in range(rng.randrange(1, 16)):
            data[rng.randrange(min(len(data), 4096))] = rng.randrange(256)
    elif kind == 1:                  # flips anywhere
        for _ in range(rng.randrange(1, 64)):
            data[rng.randrange(len(data))] = rng.randrange(256)
    elif kind == 2:                  # a run of zero or 0xff bytes
        start = rng.randrange(len(data))
        length = rng.randrange(1, 512)
        data[start:start + length] = bytes([rng.choice((0, 255))]) * len(data[start:start + length])
    elif kind == 3:                  # cut
        del data[rng.randrange(1, len(data)):]
    elif kind == 4:                  # a span removed
        start = rng.randrange(len(data))
        del data[start:start + rng.randrange(1, 4096)]
    elif kind == 5:                  # a span duplicated
        start = rng.randrange(len(data))
        span = data[start:start + rng.randrange(1, 4096)]
        data[start:start] = span
    else:                            # length-like fields: big-endian or little-endian words set large
        for _ in range(rng.randrange(1, 4)):
            p = rng.randrange(max(1, min(len(data), 8192) - 4))
            data[p:p + 4] = rng.choice((b'\xff\xff\xff\xff', b'\x7f\xff\xff\xff', b'\x00\x00\x00\x00',
                                        b'\xff\xff\xff\x7f'))
    return bytes(data) if data else b'\0'


def monkeys_audio(name, path):
    """FFmpeg writes no Monkey's Audio: version 3990 at level 3000 in frames of
    4000 blocks, or version 3950 (the 32-byte header) at level 2000."""
    import ape_vectors
    rng = random.Random(name)
    count, rate = (13000, 22050) if name == 'tone.ape' else (8000, 16000)
    pcm = [(round(9000 * math.sin(i * 0.05) + rng.randint(-3000, 3000)), rng.randint(-8000, 8000))
           for i in range(count)]
    if name == 'tone.ape':
        data, _ = ape_vectors.write(pcm, 2, 16, rate, 3990, 3, frame_blocks=4000)
    else:
        data, _ = ape_vectors.write([(left * 256,) for left, _ in pcm], 1, 24, rate, 3950, 2)
    path.write_bytes(data)


def limit_memory():
    resource.setrlimit(resource.RLIMIT_AS, (LIMIT, LIMIT))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=500)
    parser.add_argument('--seed', type=int, default=20261006)
    parser.add_argument('--wine', action='store_true')
    parser.add_argument('--only', help='comma-separated source filenames')
    parser.add_argument('--repair-eac3-crc', action='store_true',
                        help='repair complete raw ECPL frame CRCs in alternating mutations to exercise block parsing')
    args = parser.parse_args()
    if args.count < 1:
        parser.error('--count must be positive')
    selected = SOURCES
    if args.only:
        names = set(args.only.split(','))
        unknown = names - {name for name, _ in SOURCES}
        if unknown:
            parser.error(f'unknown sources: {", ".join(sorted(unknown))}')
        selected = [(name, options) for name, options in SOURCES if name in names]
    build_lamp()
    work = scratch('robustness-wine' if args.wine else 'robustness')
    rng = random.Random(args.seed)
    if args.wine:
        command = ['wine', str(ROOT / 'bin' / 'lamp-cli.exe')]
        env = dict(os.environ, WINEPREFIX=os.environ.get('WINEPREFIX', str(Path.home() / '.wine')),
                   WINEDEBUG=os.environ.get('WINEDEBUG', '-all'))
        step = 10
        try:                         # Wine's first start may set up its prefix at length
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, timeout=600)
        except subprocess.TimeoutExpired:
            pass
    else:
        command = [str(lamp_cli())]
        env = os.environ
        step = 1
    checks = []
    total = decoded = 0
    for name, options in selected:
        source = work / name
        if not source.exists():
            if name.startswith('ecpl.'):
                import eac3_vectors
                raw=work/'ecpl.ec3'
                if not raw.exists():
                    data,_=eac3_vectors.stream(20261013,12,7,1,ecplinu=1,
                        coupling=1,cplstre=1,ecplbegf=0,ecplendf=15,
                        ecpl_cycle=True,ecplparam1e=1,ecplparam2e=1,
                        short=0.25)
                    raw.write_bytes(data)
                if source!=raw:ffmpeg('-i',raw,'-c','copy',source)
            elif name.startswith('aht.'):
                import eac3_vectors
                raw=work/'aht.ec3'
                if not raw.exists():
                    data,_=eac3_vectors.stream(20261009,12,7,1,ahte=1,ahtinu=1,
                        coupling=1,cplstre=0,spxinu=1,spxstre=0,spxbegf=4,spxendf=7,
                        spxstrtf=0,short=0.25)
                    raw.write_bytes(data)
                if source!=raw:ffmpeg('-i',raw,'-c','copy',source)
            elif name.startswith('spx.'):
                import eac3_vectors
                raw=work/'spx.ec3'
                if not raw.exists():
                    data, _ = eac3_vectors.stream(20261008, 12, 7, 1, blocks=[1,2,3,6],
                        spxinu=1,spxbegf=4,spxendf=7,spxstrtf=0,short=0.25)
                    raw.write_bytes(data)
                if source!=raw:ffmpeg('-i',raw,'-c','copy',source)
            elif name == 'written.ec3':
                import eac3_vectors
                data, _ = eac3_vectors.stream(20261007, 12, 7, 1, blocks=[1,2,3,6], short=0.25)
                source.write_bytes(data)
            elif name.startswith('ima-') and name.endswith('bit.wav'):
                import adpcm_model
                bits=int(name[4]);channels={2:1,3:2,5:8}[bits]
                align=channels*(4+adpcm_model.IMA_GROUP_BYTES[bits]*12)
                body=adpcm_model.random_ima(random.Random(name),channels,align,24)
                source.write_bytes(adpcm_model.wave(0x11,channels,48000,align,body,bits=bits))
            elif options is None:
                monkeys_audio(name, source)
            else:
                ffmpeg(*options, source)
        original = source.read_bytes()
        if args.wine:
            good = wine_run([*command, '--check', str(source)], env=env, timeout=120)
        else:
            good = subprocess.run([*command, '--check', str(source)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  env=env, timeout=120)
        if good.returncode:
            raise Failure(f'{name} does not decode before mutation: {good.stdout[-300:]}')
        counts = {0: 0, 2: 0}
        repaired = 0
        for n in range(0, args.count, step):
            data = mutate(original, rng)
            if args.repair_eac3_crc and name == 'ecpl.ec3' and (n // step) % 2:
                import ac3_model
                mutable = bytearray(data)
                at = 0
                while at+8 <= len(mutable) and mutable[at:at+2] == b'\x0b\x77':
                    size = 2 * (((mutable[at+2]&7)<<8 | mutable[at+3])+1)
                    if size < 8 or at+size > len(mutable): break
                    mutable[at+size-2:at+size] = ac3_model.crc16(mutable[at+2:at+size-2]).to_bytes(2,'big')
                    repaired += 1
                    at += size
                data = bytes(mutable)
            path = work / f'mutated{Path(name).suffix}'
            path.write_bytes(data)
            options = ['--check']
            if (n // step) % 4 == 3:
                options += ['--start', f'{rng.uniform(0, 1.4):.3f}']
            try:
                if args.wine:
                    result = wine_run([*command, *options, str(path)], env=env, timeout=30)
                else:
                    result = subprocess.run([*command, *options, str(path)], stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, env=env, timeout=30,
                                            preexec_fn=limit_memory if resource else None)
            except subprocess.TimeoutExpired:
                (work / f'hang-{name}-{n}.bin').write_bytes(data)
                raise Failure(f'mutation {n} of {name} ({options}) hung; kept as hang-{name}-{n}.bin')
            if result.returncode not in counts:
                (work / f'crash-{name}-{n}.bin').write_bytes(data)
                raise Failure(f'mutation {n} of {name} ({options}) exited {result.returncode}: '
                              f'{result.stdout[-200:]}; kept as crash-{name}-{n}.bin')
            counts[result.returncode] += 1
        total += counts[0] + counts[2]
        decoded += counts[0]
        checks.append({'test': name, 'result': 'no crash, hang or runaway memory', 'mutations': counts[0] + counts[2],
                       'decoded': counts[0], 'rejected_or_damaged': counts[2],
                       **({'repaired_frame_crcs': repaired} if args.repair_eac3_crc else {})})
        print(f'{name}: {counts[0] + counts[2]} mutations, {counts[0]} decoded, {counts[2]} rejected', flush=True)
    report = 'robustness-selected' if args.only else 'robustness'
    if args.wine:
        report += '-wine'
    write_report(report, {
        'result': 'passed', 'checks': checks, 'mutations': total, 'decoded': decoded,
        **({'wine_debug': env['WINEDEBUG']} if args.wine else {}),
        **({'crc_policy': 'Alternating raw ECPL mutations repair CRCs of complete frames; other mutations retain damage'} if args.repair_eac3_crc else {}),
        'scope': f'{len(selected)} container/codec sources, {args.count} mutations each '
                 f'({"every tenth under Wine" if args.wine else "Linux, 2 GiB address space"}), seed {args.seed}: '
                 'byte flips, zero/0xff runs, cuts, removed and duplicated spans, large length fields; --check, '
                 'every fourth from a random --start.'})
    print(f'Passed: {total} mutated files across {len(selected)} sources, none crashed, hung or ran away.')


if __name__ == '__main__':
    main_guard(main)
