#!/usr/bin/env python3
"""Dense queues: heard boundaries, navigation PCM, empty files and retention.

--wine-only checks the same source in COFF against a completed native run.
The timeline probe only adds aliases/thunks; it includes shipping queue.s.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, WINDOWS, Failure, build_lamp, compile_c, exe,
    main_guard, out_dir, run, scratch, write_report)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def prepare(work):
    chapters = module('timeline_chapters', 'verify-chapters.py')
    def wave(name, rate, frames, tagged=False):
        rng = random.Random(20261007 + rate)
        samples = [rng.randrange(-8192, 8192) for _ in range(frames)]
        fmt = struct.pack('<HHIIHH', 1, 1, rate, rate * 2, 2, 16)
        chunks = [(b'fmt ', fmt), (b'data', struct.pack('<' + 'h' * frames, *samples))]
        if tagged:
            tags = [chapters.frame(4, b'CHAP', chapters.chap(f'c{i}'.encode(), ms, 100,
                    chapters.frame(4, b'TIT2', b'\x03Boundary')))
                    for i, ms in enumerate([0, 10, 25, 60])]
            chunks.append((b'id3 ', chapters.id3(4, tags)))
        (work / name).write_bytes(chapters.riff_file(b'WAVE', chunks))
        (work / (name + '.f32')).write_bytes(b''.join(struct.pack('<ff', s / 32768, s / 32768) for s in samples))
    for rate in (44100, 48000, 96000): wave(f'forty-{rate}.wav', rate, rate // 25, True)
    wave('one-frame.wav', 48000, 1)
    wave('empty.wav', 48000, 0)
    wave('submillisecond.wav', 48000, 1, True)
    wave('submillisecond-resampled.wav', 192000, 1, True)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in work.iterdir()
              if p.name.endswith(('.wav', '.wav.f32'))}
    (work / 'manifest.json').write_text(json.dumps(hashes, indent=2) + '\n')


def oracle(command, arguments=()):
    result = subprocess.run([*map(str, command), *map(str, arguments)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    text = result.stdout.decode('utf-8', 'replace')
    if result.returncode: raise Failure(f'Timeline oracle exited {result.returncode}: {text[-2000:]}')
    return json.loads(text.splitlines()[-1])


def main():
    work = scratch('queue-timeline')
    if '--prepare-only' in sys.argv: prepare(work); return
    if not (work / 'manifest.json').exists(): prepare(work)
    hashes = json.loads((work / 'manifest.json').read_text())
    for name, digest in hashes.items():
        if hashlib.sha256((work / name).read_bytes()).hexdigest() != digest: raise Failure('Fixture changed: ' + name)
    wine = '--wine-only' in sys.argv
    out_dir().mkdir(parents=True, exist_ok=True)
    probe = out_dir() / ('queue-timeline-probe.obj' if wine or WINDOWS else 'queue-timeline-probe.o')
    if wine or WINDOWS:
        spec = importlib.util.spec_from_file_location('windows_build', ROOT / 'tools/build-windows.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        run([builder.tool('llvm-mc'), '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
             '-defsym=WINDOWS=1', '-I', ROOT / 'src', ROOT / 'tests/queue-timeline-probe.s', '-o', probe])
    else:
        run(['as', '--64', '-I', ROOT / 'src', ROOT / 'tests/queue-timeline-probe.s', '-o', probe])
    if wine:
        prior = json.loads((out_dir() / 'queue-timeline-verification.json').read_text())
        if prior['result'] != 'passed' or prior['fixture_hashes'] != hashes: raise Failure('Matching native run must pass first')
        run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
        skip = {'player', 'ui', 'queue', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}
        objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj')) if p.stem not in skip]
        libs = [p for p in sorted((ROOT / 'bin/obj').glob('*.lib')) if p.name != 'lamp-test.lib']
        target = ROOT / 'bin/queue-timeline-oracle.exe'
        run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
             '-I', ROOT / 'tests', ROOT / 'tests/queue-timeline-oracle.c', probe, *objects, *libs, '-lm', '-o', target])
        command = ['wine', target]
    else:
        library = build_lamp()
        compile_c(exe('queue-timeline-oracle'), [ROOT / 'tests/queue-timeline-oracle.c'], objects=[probe], libraries=[library])
        compile_c(exe('resample-oracle'), [ROOT / 'tests/resample-oracle.c'], libraries=[library])
        command = [exe('queue-timeline-oracle')]
    checks = [dict(test='seeded retained history and 64-bit ordinal', result=oracle(command))]
    pcm_hashes = {}
    for rate in (44100, 48000, 96000):
        path = work / f'forty-{rate}.wav'; reference = work / (path.name + '.48000.f32')
        if not wine:
            if rate == 48000: reference.write_bytes((work / (path.name + '.f32')).read_bytes())
            else: run([exe('resample-oracle'), rate, 48000, work / (path.name + '.f32'), reference])
        digest = hashlib.sha256(reference.read_bytes()).hexdigest(); pcm_hashes[reference.name] = digest
        if wine and prior['reference_pcm_hashes'].get(reference.name) != digest: raise Failure('Native reference PCM changed')
        checks.append(dict(test=f'100 short files at {rate} Hz to 48000 Hz', result=oracle(command,
            ['dense', path, reference, 48000])))
    checks.append(dict(test='1000 empty opens between audible files', result=oracle(command,
        ['empty', work / 'forty-48000.wav', work / 'empty.wav'])))
    checks.append(dict(test='repeating one-frame files', result=oracle(command, ['repeat', work / 'one-frame.wav'])))
    checks.append(dict(test='concurrent history overwrite', result=oracle(command, ['concurrent', work / 'one-frame.wav'])))
    checks.append(dict(test='known submillisecond chapter duration', result=oracle(command,
        ['tiny', work / 'submillisecond.wav', work / 'submillisecond-resampled.wav'])))
    if wine:
        snapshot_probe = out_dir() / 'ui-queue-snapshot-probe.obj'
        run([builder.tool('llvm-mc'), '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
             '-defsym=WINDOWS=1', '-I', ROOT / 'src', '-I', ROOT / 'src/win',
             ROOT / 'tests/ui-queue-snapshot-probe.s', '-o', snapshot_probe])
        ui_objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj'))
                      if p.stem not in {'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}]
        ui_target = ROOT / 'bin/ui-queue-snapshot-oracle.exe'
        run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
             '-I', ROOT / 'tests', ROOT / 'tests/ui-queue-snapshot-oracle.c', snapshot_probe,
             *ui_objects, *libs, '-lm', '-o', ui_target])
        checks.append(dict(test='Windows producer/UI snapshot handoff', result=oracle(['wine', ui_target],
            [work / 'forty-48000.wav', work / 'one-frame.wav', work / 'submillisecond-resampled.wav'])))
    source_names = ['src/queue.s', 'src/decoder.s', 'tests/queue-timeline-probe.s',
                    'tests/queue-timeline-oracle.c', 'tests/verify-queue-timeline.py']
    if wine:
        source_names += ['src/win/ui.s', 'src/win/ui_queue.inc', 'src/win/ui_resume.inc',
                         'src/win/player.s', 'src/win/resume_state.inc', 'src/win/ui_tracks.inc',
                         'src/win/ui_menu.inc', 'src/win/kernel32.def',
                         'tests/ui-queue-snapshot-probe.s', 'tests/ui-queue-snapshot-oracle.c']
    write_report('queue-timeline-wine' if wine else 'queue-timeline', dict(result='passed', checks=checks,
        fixture_hashes=hashes, reference_pcm_hashes=pcm_hashes,
        sources={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in source_names},
        environment=dict(platform=platform.platform(), python=sys.version),
        scope='Real dense queues, exact restarted PCM at native/resampled rates, protected output, empty-file coalescing and repeat; retained-window wrap and 64-bit ordinals seeded through test-only private aliases. The Wine run also stresses the Windows UI snapshot/cover handoff on two threads. Native Windows hardware remains unverified.'))
    print(f'Passed {len(checks)} queue timeline checks.', flush=True)


if __name__ == '__main__': main_guard(main)
