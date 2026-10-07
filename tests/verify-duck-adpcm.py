#!/usr/bin/env python3
"""Duck DK3/DK4 WAVE/AVI PCM, guarded blocks and exact seeks.

--prepare-only writes model/FFmpeg checked fixtures without building LAMP.
--wine-only repeats a completed native run with shipping Windows objects.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
import urllib.request
sys.path.insert(0, str(Path(__file__).resolve().parent))
import duck_adpcm_model as model
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg,
                       ffmpeg_version, lamp_cli, main_guard, out_dir, play,
                       playback_requested, run, scratch, stereo_view, write_report)

HISTORICAL = [
    ('historical-dk3.avi', 'https://samples.ffmpeg.org/A-codecs/DK3/sonic3dblast_intro.avi',
     'b32a3fa8400131502f9276a3a7683f9bd019f790b69f6806eb2db8712a6989c7', model.DK3, 2),
    ('historical-dk4.avi', 'https://samples.ffmpeg.org/A-codecs/DK4/virtuafighter2-opening1.avi',
     '3db0950816272d4c94077b7f38f67b85440a4dade38b07e3a1a4e230d2248e3d', model.DK4, 1),
]


def chunk(name, data):
    return name + struct.pack('<I', len(data)) + data + bytes(len(data) % 2)


def pcm_bytes(values, channels):
    return stereo_view(struct.pack('<' + 'f' * len(values), *[v / 32768 for v in values]), channels, 0)


def fixture(work, name, tag, channels, align, data, kind=None):
    values = model.decode(tag, data, channels, align)
    frames = len(values) // channels
    fact = frames - 13 if kind == 'fact' else None
    basic = model.wave(tag, channels, 48000, align, data, fact)
    fmt = basic[20:38]
    parts = [(b'fmt ', fmt)]
    if fact is not None: parts.append((b'fact', struct.pack('<I', fact)))
    parts.append((b'data', data))
    wave = basic
    if kind == 'extensible':
        fmt = struct.pack('<HHIIHHHHI', 0xfffe, channels, 48000,
                          48000 * align // model.samples(tag, align, channels), align, 4, 22, 4,
                          3 if channels == 2 else 4)
        fmt += struct.pack('<I', tag) + bytes.fromhex('00001000800000aa00389b71')
        parts[0] = (b'fmt ', fmt)
        body = b''.join(chunk(k, p) for k, p in parts)
        wave = b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WAVE' + body
    elif kind == 'rf64':
        body = b''.join(chunk(k, p) for k, p in parts)
        ds64 = struct.pack('<QQQI', 12 + 36 + len(body) - 8, len(data), frames, 0)
        body = body.replace(b'data' + struct.pack('<I', len(data)), b'data' + b'\xff' * 4, 1)
        wave = b'RF64' + b'\xff' * 4 + b'WAVE' + chunk(b'ds64', ds64) + body
    elif kind == 'w64':
        tail = bytes.fromhex('f3acd3118cd100c04f8edb8a')
        body = b''
        for key, payload in parts:
            part = key + tail + struct.pack('<Q', 24 + len(payload)) + payload
            body += part + bytes(-len(part) % 8)
        wave = bytes.fromhex('726966662e91cf11a5d628db04c10000') + struct.pack('<Q', 40 + len(body)) + b'wave' + tail + body
    path = work / name
    path.write_bytes(wave)
    # Old FFmpeg WAVE timestamps can repeat for one-sample DK4 blocks. The
    # decoded PCM comparison uses consecutive sample timestamps instead.
    native = subprocess.run([os.environ.get('FFMPEG', 'ffmpeg'), '-hide_banner', '-loglevel', 'repeat+error',
                             '-i', str(path), '-af', 'asetpts=N', '-f', 's16le', '-'], capture_output=True)
    text = native.stderr.decode('utf-8', 'replace')
    allowed = ('invalid number of samples in packet', 'Invalid data found',
               'Error submitting packet', 'Error while decoding stream') if kind == 'short-header' else ()
    errors = [line for line in text.splitlines() if not any(t in line for t in allowed)]
    if native.returncode or errors:
        raise Failure(f'{name}: FFmpeg failed: {errors}')
    expected = struct.pack('<' + 'h' * len(values), *values)
    if native.stdout != expected:
        raise Failure(f'{name}: model differs from FFmpeg ({len(expected)} vs {len(native.stdout)} bytes)')
    reference = pcm_bytes(values, channels)
    if fact is not None: reference = reference[:fact * 8]
    (work / (name + '.reference.f32')).write_bytes(reference)
    first = data[:align]
    planes = model.block_pcm(tag, first, channels)
    first_values = [planes[c][i] for i in range(len(planes[0])) for c in range(channels)]
    (work / (name + '.fmt')).write_bytes(fmt)
    (work / (name + '.block')).write_bytes(first)
    (work / (name + '.block.f32')).write_bytes(pcm_bytes(first_values, channels))
    return dict(name=name, tag=tag, channels=channels, align=align, frames=len(reference) // 8,
                ffmpeg_exact=True, fact_trimmed=fact is not None)


def prepare(work):
    rng = random.Random(20261017)
    files = []
    for tag, channels in ((model.DK4, 1), (model.DK4, 2), (model.DK3, 2)):
        stem = f'dk{4 if tag == model.DK4 else 3}-{channels}ch'
        sizes = [4 * channels + n for n in (0, 1, 2, 3, 7, 60, 511)] if tag == model.DK4 else [18, 20, 22, 24, 26, 32, 64, 256, 4096]
        for align in [*sizes, 65535]:
            data = model.random_blocks(rng, tag, channels, align, 1 if align == 65535 else 89)
            files.append(fixture(work, f'{stem}-block{align}.wav', tag, channels, align, data))
        align = 256
        for kind in ('fact', 'partial', 'short-header', 'extensible', 'rf64', 'w64', 'unicode'):
            tail = (19 if tag == model.DK3 else 4 * channels + 3) if kind == 'partial' else (17 if tag == model.DK3 else 4 * channels - 1) if kind == 'short-header' else 0
            data = model.random_blocks(rng, tag, channels, align, 8, tail)
            name = f'{stem}-{kind}.' + ('w64' if kind == 'w64' else 'wav')
            if kind == 'unicode': name = f'{stem}-音声-Ünïcode.wav'
            files.append(fixture(work, name, tag, channels, align, data, kind))
        # FFmpeg's AVI muxer writes the same independently checked blocks.
        source = work / f'{stem}-rf64.wav'
        avi = work / f'{stem}.avi'
        ffmpeg('-i', source, '-c', 'copy', avi)
        (work / (avi.name + '.reference.f32')).write_bytes((work / (source.name + '.reference.f32')).read_bytes())
        files.append(dict(name=avi.name, tag=tag, channels=channels, align=align,
                          frames=len((work / (avi.name + '.reference.f32')).read_bytes()) // 8, avi=True))
    # Existing encoder output, cached outside Git and pinned before use.
    # The supplied hashes were checked against the archive's MD5 listings.
    for name, url, digest, tag, channels in HISTORICAL:
        path = work / name
        if not path.exists():
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read(32 * 1024 * 1024 + 1)
            if len(data) > 32 * 1024 * 1024: raise Failure('Historical sample exceeds download cap')
            path.write_bytes(data)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest: raise Failure('Historical sample hash differs')
        wave = path.with_suffix('.wav')
        ffmpeg('-i', path, '-map', '0:a:0', '-c:a', 'copy', wave)
        for source in (path, wave):
            decoded = subprocess.run([os.environ.get('FFMPEG', 'ffmpeg'), '-hide_banner', '-loglevel', 'error',
                                       '-i', str(source), '-map', '0:a:0', '-f', 's16le', '-'], capture_output=True)
            if decoded.returncode or decoded.stderr: raise Failure(source.name + ': historical decode failed')
            values = struct.unpack('<' + 'h' * (len(decoded.stdout) // 2), decoded.stdout)
            reference = pcm_bytes(values, channels)
            (work / (source.name + '.reference.f32')).write_bytes(reference)
            files.append(dict(name=source.name, tag=tag, channels=channels, frames=len(reference) // 8,
                              avi=True, historical=True, source_url=url, source_sha256=digest))
    rejections = []
    for tag, channels in ((model.DK4, 3), (model.DK3, 1), (model.DK3, 3)):
        name = f'unsupported-tag{tag}-channels{channels}.wav'
        (work / name).write_bytes(model.wave(tag, channels, 48000, 256, bytes(256)))
        rejections.append(dict(name=name, error=101))
    for tag in (model.DK4, model.DK3):
        # Use ordinary RIFF for mutations of fmt fields and block indices.
        ordinary = model.wave(tag, 2, 48000, 256, model.random_blocks(rng, tag, 2, 256, 2))
        for mode in ('bits', 'align', 'index0', 'index1'):
            data = bytearray(ordinary)
            fmt_at, data_at = data.index(b'fmt ') + 8, data.index(b'data') + 8
            if mode == 'bits': struct.pack_into('<H', data, fmt_at + 14, 2 if tag == model.DK3 else 3)
            elif mode == 'align': struct.pack_into('<H', data, fmt_at + 12, 7 if tag == model.DK4 else 17)
            else:
                at = data_at + (14 if tag == model.DK3 else 2) + (1 if tag == model.DK3 else 4) * (mode == 'index1')
                data[at] = 89
            name = f'reject-tag{tag}-{mode}.wav'
            (work / name).write_bytes(data)
            # An alignment below the packet minimum leaves no track packets:
            # the shared container/track layer rejects that framing with 60.
            rejections.append(dict(name=name, error=101 if mode == 'bits' else 60 if mode == 'align' else 100))
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(work.iterdir())
              if p.is_file() and p.name != 'manifest.json' and not p.name.endswith('.ours.f32')}
    manifest = dict(files=files, rejections=rejections, hashes=hashes, ffmpeg=ffmpeg_version(),
                    model_sources={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
                                   ('tests/duck_adpcm_model.py', 'tests/adpcm_model.py')},
                    environment=dict(platform=platform.platform(), python=sys.version))
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Prepared {len(files)} streams and {len(rejections)} rejections.', flush=True)


def oracle(command, args, env=None):
    result = run([*command, *args], env=env, timeout=180)
    return json.loads(result.strip().splitlines()[-1])


def main():
    work = scratch('duck-adpcm')
    if '--prepare-only' in sys.argv: prepare(work); return
    if not (work / 'manifest.json').exists(): prepare(work)
    manifest = json.loads((work / 'manifest.json').read_text())
    for name, digest in manifest['model_sources'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest: raise Failure('Reference model changed')
    for name, digest in manifest['hashes'].items():
        if hashlib.sha256((work / name).read_bytes()).hexdigest() != digest: raise Failure('Fixture changed: ' + name)
    wine = '--wine-only' in sys.argv
    names = {'duck-adpcm-oracle': 'duck-adpcm-oracle.c', 'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}
    env = dict(os.environ, WINEDEBUG='err+all') if wine else None
    if wine:
        prior = json.loads((out_dir() / 'duck-adpcm-verification.json').read_text())
        if prior['result'] != 'passed' or prior['fixture_hashes'] != manifest['hashes']: raise Failure('Matching native run must pass first')
        run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
        objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj')) if p.stem not in
                   {'player', 'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}]
        libs = sorted((ROOT / 'bin/obj').glob('*.lib'))
        for name, source in names.items():
            run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
                 '-I', ROOT / 'tests', ROOT / 'tests' / source, *objects, *libs, '-lm', '-o', ROOT / 'bin' / (name + '.exe')])
        cli = ['wine', ROOT / 'bin/lamp-cli.exe']
        command = lambda name: ['wine', ROOT / 'bin' / (name + '.exe')]
    else:
        library = build_lamp(); build_oracles(out_dir(), names, library)
        cli = [lamp_cli()]
        command = lambda name: [exe(name)]
    checks = []
    for entry in manifest['files']:
        name = entry['name']; path = work / name; reference = work / (name + '.reference.f32')
        output = work / (name + '.ours.f32'); output.unlink(missing_ok=True)
        run([*cli, '--decode', path, output], env=env, timeout=180)
        if output.read_bytes() != reference.read_bytes(): raise Failure(name + ': PCM differs')
        proof = None if entry.get('avi') else oracle(command('duck-adpcm-oracle'),
                [work / (name + '.fmt'), work / (name + '.block'), work / (name + '.block.f32')], env)
        seeks = oracle(command('seek-oracle'), [path, reference, 0], env)
        checks.append(dict(test=name, result='exact', frames=entry['frames'], guard=proof, seeks=seeks,
                           comparator='FFmpeg on hash-pinned historical encoder output' if entry.get('historical') else 'integer model checked against FFmpeg' if not entry.get('avi') else 'FFmpeg stream copy of checked RF64 blocks'))
        print(f'{name}: exact PCM and {seeks["checks"]} seeks', flush=True)
    for entry in manifest['rejections']:
        proof = oracle(command('chain-oracle'), ['reject', work / entry['name']], env)
        if proof['decode_error'] != entry['error']: raise Failure(entry['name'] + ': wrong error code')
        checks.append(dict(test=entry['name'], result=proof))
    for stem in ('dk4-1ch', 'dk4-2ch', 'dk3-2ch'):
        for mode in ('cancel-open', 'cancel-read'):
            proof = oracle(command('chain-oracle'), [mode, work / (stem + '-block' + ({'dk4-1ch':'64','dk4-2ch':'68','dk3-2ch':'256'}[stem]) + '.wav')], env)
            checks.append(dict(test=stem + ' ' + mode, result=proof))
    if playback_requested(sys.argv[1:]) and not wine:
        for stem in ('dk4-1ch', 'dk4-2ch', 'dk3-2ch'):
            checks.append(dict(test=stem + ' playback', result='passed', stats=play(work / (stem + '-rf64.wav'))))
    sources = ['src/adpcm.s', 'src/adpcm_duck.inc', 'src/adpcm_tables.inc', 'src/decoder.s', 'src/avi.s',
               'src/track.s', 'tests/duck-adpcm-oracle.c', 'tests/verify-duck-adpcm.py', 'tests/seek-oracle.c']
    write_report('duck-adpcm-wine' if wine else 'duck-adpcm', dict(result='passed', checks=checks,
        fixture_hashes=manifest['hashes'], reference_ffmpeg=manifest['ffmpeg'], reference_environment=manifest['environment'],
        sources={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
        historical_sources=[dict(file=n, url=u, sha256=h) for n,u,h,_,_ in HISTORICAL],
        scope='Duck DK4 mono/stereo and DK3 stereo, every initial step index, predictor edges, int16 sum/difference wrap, tiny/partial/maximum blocks, fact trimming, extensible/RF64/Wave64, Unicode and AVI copies; guarded packet/output, exact seeks, invalid fields/indices and cancellation; synthetic streams plus two hash-pinned historical AVI encoder samples and their audio-only WAVE copies, compared with independent FFmpeg decoding.'))
    print(f'Passed {len(checks)} Duck ADPCM checks.', flush=True)


if __name__ == '__main__': main_guard(main)
