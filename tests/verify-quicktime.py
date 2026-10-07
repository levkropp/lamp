#!/usr/bin/env python3
"""QuickTime G.711, IMA4 and GSM: independent PCM, legacy tables, seeks,
track selection, malformed descriptions/tables and cancelled open/read.
Usage: python3 tests/verify-quicktime.py [--skip-playback] [--wine]
--wine also builds the Windows CLI and checks its PCM, --start, track
selection and malformed rejections; writes a separate quicktime-wine report.
"""
import array
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, lamp_cli,
                       main_guard, out_dir, play, playback_requested, run, scratch, write_report)

spec = importlib.util.spec_from_file_location('mp4_tests', Path(__file__).with_name('verify-mp4.py'))
mp4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mp4)
TABLE = 'moov/trak/mdia/minf/stbl/'


def windows_checks(work, files, pair):
    """The shipping Windows CLI under Wine, compared with continuous PCM.
    The assembly oracles above exercise cancellation and arbitrary samples;
    these exercise Windows file I/O and the CLI's millisecond start times.
    """
    import subprocess
    run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
    env = dict(os.environ, WINEDEBUG='-all')
    command = ['wine', str(ROOT / 'bin/lamp-cli.exe')]
    checks = []

    def decode(path, output, *options):
        output.unlink(missing_ok=True)
        run([*command, '--decode', *options, path, output], env=env, timeout=120)
        return output.read_bytes()

    for path, tolerance in files:
        reference = Path(str(path) + '.f32').read_bytes()
        output = work / 'windows.f32'
        if decode(path, output) != reference:
            raise Failure(f'Windows {path.name}: continuous PCM differs')
        checks.append({'test': path.name, 'result': 'exact PCM'})
        rate = int(path.stem.split('-')[2])
        for ms in (400, 1600, 3000):
            target = ms * rate // 1000
            expected = reference[target * 8:]
            ours = decode(path, output, '--start', f'{ms / 1000:.3f}')
            if len(ours) != len(expected):
                raise Failure(f'Windows {path.name} at {ms} ms: length differs')
            deviation = 0
            if tolerance:
                a, b = array.array('f', ours), array.array('f', expected)
                deviation = max((abs(x - y) for x, y in zip(a, b)), default=0)
                if deviation > tolerance / 32768:
                    raise Failure(f'Windows {path.name} at {ms} ms: deviation {deviation}')
            elif ours != expected:
                raise Failure(f'Windows {path.name} at {ms} ms: PCM differs')
            checks.append({'test': f'{path.name} --start {ms} ms', 'result': 'passed',
                           'maximum_deviation': deviation, 'tolerance': tolerance / 32768})
    for path in sorted(work.glob('bad-*.mov')):
        result = subprocess.run([*command, '--check', str(path)], env=env, timeout=120,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode != 2:
            raise Failure(f'Windows {path.name}: expected rejection, exit {result.returncode}')
        checks.append({'test': path.name, 'result': 'rejected'})
    gsm = next(path for path, _ in files if 'libgsm' in path.name)
    for number, original in ((1, files[0][0]), (2, gsm)):
        if decode(pair, work / 'windows.f32', '--track', str(number)) != Path(str(original) + '.f32').read_bytes():
            raise Failure(f'Windows QuickTime track {number} differs')
        checks.append({'test': f'track {number}', 'result': 'exact'})
    write_report('quicktime-wine', {'result': 'passed', 'checks': checks,
                                   'scope': 'Windows CLI under Wine: 18 MOV continuous decodes, '
                                            '54 --start decodes, track selection and malformed rejections; '
                                            'exact against Linux continuous PCM except bounded IMA4 seeks.'})
    print(f'Passed {len(checks)} Windows QuickTime checks under Wine.', flush=True)


def legacy(data, frames_per_block):
    """Version 0 QuickTime tables count decoded samples instead of blocks.
    Keep the sound description and data intact; adjust each chunk's count.
    FFmpeg accepts the version 1 description too with these old tables.
    """
    data = bytearray(data)
    stsz, _ = mp4.find(data, TABLE + 'stsz')
    count = struct.unpack_from('>I', data, stsz + 8)[0]
    struct.pack_into('>II', data, stsz + 4, 1, count * frames_per_block)
    stsc, end = mp4.find(data, TABLE + 'stsc')
    for pos in range(stsc + 8, end, 12):
        count = struct.unpack_from('>I', data, pos + 4)[0]
        struct.pack_into('>I', data, pos + 4, count * frames_per_block)
    # Existing stts entries can have a short final packet. Preserve duration
    # while turning each run into individual one-sample entries.
    stts, end = mp4.find(data, TABLE + 'stts')
    for pos in range(stts + 8, end, 8):
        count, duration = struct.unpack_from('>II', data, pos)
        struct.pack_into('>II', data, pos, count * duration, 1)
    return bytes(data)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    work = scratch('quicktime')
    checks = []
    files = []
    for codec in ('pcm_alaw', 'pcm_mulaw', 'adpcm_ima_qt', 'libgsm'):
        for channels in ((1,) if codec == 'libgsm' else (1, 2)):
            for rate in ((8000,) if codec == 'libgsm' else (8000, 44100)):
                name = f'{codec}-{channels}-{rate}'
                path = work / (name + '.mov')
                ffmpeg('-f', 'lavfi', '-i', f'anoisesrc=r={rate}:d=3.2:seed=17:a=0.3',
                       '-ac', str(channels), '-c:a', codec, path)
                variants = [path]
                if codec in ('adpcm_ima_qt', 'libgsm'):
                    old = work / (name + '-legacy.mov')
                    old.write_bytes(legacy(path.read_bytes(), 64 if codec == 'adpcm_ima_qt' else 160))
                    variants.append(old)
                for target in variants:
                    ours = Path(str(target) + '.f32')
                    stats = decode_f32(target, ours)
                    reference = Path(str(target) + '.ffmpeg.f32')
                    upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else []
                    ffmpeg('-i', target, *upmix, '-f', 'f32le', reference)
                    expected = reference.read_bytes()[:len(ours.read_bytes())]
                    # The partial final IMA4 frame is bounded by the movie's
                    # presentation duration; FFmpeg outputs its whole block.
                    if ours.read_bytes() != expected:
                        raise Failure(f'{target.name}: PCM differs from FFmpeg')
                    duration = int(run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                                        '-show_entries', 'stream=duration_ts', '-of', 'csv=p=0', target]))
                    if len(ours.read_bytes()) != duration * 8:
                        raise Failure(f'{target.name}: presentation length differs from FFmpeg duration')
                    files.append((target, 127 if codec == 'adpcm_ima_qt' else 0))
                    checks.append({'test': target.name, 'result': 'exact', 'comparator': 'FFmpeg', 'stats': stats})
                    print(f'{target.name}: exact PCM and presentation length', flush=True)
    for path, tolerance in files:
        result = json.loads(run([exe('seek-oracle'), path, Path(str(path) + '.f32'), '0', '0', str(tolerance)]))
        checks.append({'test': path.name + ' seeks', 'tolerance': f'{tolerance}/32768', **result})
        print(f'{path.name}: {result["checks"]} seeks, deviation {result["maximum_deviation"]}', flush=True)

    def reject(label, data):
        target = work / ('bad-' + label + '.mov')
        target.write_bytes(data)
        result = run([exe('chain-oracle'), 'reject', target])
        checks.append({'test': label, 'result': result})

    good = next(p for p, _ in files if p.name == 'adpcm_ima_qt-2-44100.mov').read_bytes()
    stsd, _ = mp4.find(good, TABLE + 'stsd')
    for label, offset, value, fmt in (
            ('zero-channels', stsd + 8 + 24, 0, '>H'),
            ('nine-channels', stsd + 8 + 24, 9, '>H'),
            ('zero-rate', stsd + 8 + 32, 0, '>I'),
            ('short-description', stsd + 8, 36, '>I'),
            ('partial-block', mp4.find(good, TABLE + 'stsz')[0] + 4, 67, '>I'),
            ('offset-past-end', mp4.find(good, TABLE + 'stco')[0] + 8, len(good) + 1, '>I')):
        data = bytearray(good)
        struct.pack_into(fmt, data, offset, value)
        reject(label, data)
    old = bytearray(legacy(good, 64))
    stsc, _ = mp4.find(old, TABLE + 'stsc')
    struct.pack_into('>I', old, stsc + 12, 1)
    reject('legacy-partial-block', old)
    for mode in ('cancel-open', 'cancel-read'):
        result = run([exe('chain-oracle'), mode, files[0][0]])
        checks.append({'test': mode, 'result': result})
    # Same-file codec transitions and explicit selection use the common track layer.
    pair = work / 'two-tracks.mov'
    ffmpeg('-i', files[0][0], '-i', next(p for p, _ in files if 'libgsm' in p.name),
           '-map', '0:a', '-map', '1:a', '-c', 'copy', pair)
    for number, original in ((1, files[0][0]), (2, next(p for p, _ in files if 'libgsm' in p.name))):
        output = work / f'track-{number}.f32'
        output.unlink(missing_ok=True)
        run([lamp_cli(), '--track', str(number), '--decode', pair, output])
        if output.read_bytes() != Path(str(original) + '.f32').read_bytes():
            raise Failure(f'QuickTime track {number} differs from its standalone decode')
        checks.append({'test': f'track {number}', 'result': 'exact'})
    if '--wine' in sys.argv[1:]:
        windows_checks(work, files, pair)
    if playback_requested(sys.argv[1:]):
        ima4 = next(p for p, _ in files if p.name == 'adpcm_ima_qt-2-44100.mov')
        checks.append({'test': 'IMA4 playback', 'result': play(ima4)})
    write_report('quicktime', {'result': 'passed', 'checks': checks,
                              'scope': 'QuickTime ulaw/alaw/ima4/agsm, mono/stereo, 8/44.1 kHz; '
                                       'exact FFmpeg PCM and presentation lengths; old sample-count tables; '
                                       'seeking (IMA4 predictor tolerance 127/32768), track selection, '
                                       'malformed descriptions/blocks/tables and cancellation.'})
    print(f'Passed {len(checks)} QuickTime checks.')


if __name__ == '__main__':
    main_guard(main)
