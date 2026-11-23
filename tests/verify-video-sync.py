"""Verify shipping assembly video scheduling against an independent bag model.

Build first; this suite never rebuilds or uses a C implementation in the player.
"""
import argparse
import hashlib
import json
import platform
import random
import shutil
import struct
import subprocess
import time
from pathlib import Path
from lamp_test import ROOT, WINDOWS, MACOS, compile_c

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--bin', type=Path, required=True)
p.add_argument('--controls', action='store_true', help='also prove five broken-policy test objects fail')
args = p.parse_args()
out = args.bin.resolve()
if MACOS:
    raise SystemExit('Native ARM64 execution is not yet covered by this suite.')
obj = out / 'obj' / ('video_sync.obj' if WINDOWS else 'video_sync.o')
if not obj.is_file():
    raise SystemExit(f'Build first: missing {obj}')
work = out / 'video-sync'
work.mkdir(exist_ok=True)
vectors = work / 'sample-ns.bin'
random_source = random.Random(0x4c414d50)
cases = []
limit = (1 << 63) - 1
rates = [0, 1, 8000, 11025, 44100, 48000, 96000, 192000, 768000, 768001, (1 << 32)-1]
for rate in rates:
    edge = limit * rate // 1000000000
    samples = {0, 1, (1 << 64)-1, 1 << 63, edge, edge+1, max(0, edge-1)}
    samples.update(random_source.randrange(1 << 64) for _ in range(1200))
    # Dense exact boundaries exercise floor rounding at conventional rates.
    samples.update(random_source.randrange(100000000000) for _ in range(100))
    for sample in sorted(x for x in samples if 0 <= x < (1 << 64)):
        ns = sample * 1000000000 // rate if 0 < rate <= 768000 else -1
        if ns > limit:
            ns = -1
        cases.append(struct.pack('<QIIq', sample, rate, 0, ns))
vectors.write_bytes(b''.join(cases))
binary = work / ('video-sync-oracle.exe' if WINDOWS else 'video-sync-oracle')
compile_c(binary, [ROOT / 'tests/video-sync-oracle.c'], objects=[obj],
          libraries=[] if WINDOWS else ['-no-pie', '-Wl,-z,noexecstack'])
begin = time.perf_counter()
result = subprocess.run([str(binary), str(vectors)], capture_output=True, timeout=90,
                        **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
if result.returncode:
    raise SystemExit(f'Video sync failed ({result.returncode}): {result.stdout.decode("utf-8", "replace")} {result.stderr.decode("utf-8", "replace")}')
report = json.loads(result.stdout)
report.update(elapsed_seconds=round(time.perf_counter()-begin, 6),
              platform=platform.platform(), machine=platform.machine(),
              scope='Assembly component verification only. Simulated media timestamps and audible sample clocks; no video decoder, GPU, real A/V playback, power or native macOS execution is established.',
              policies=['stable presentation ordering; 32 owned tokens maximum',
                        'atomic rejection of stale epochs, invalid clocks and overflowing frame ends',
                        'audible sample clock floor conversion using integer arithmetic',
                        'paused/starved hold; one frame per explicit step',
                        'late frames dropped only when a newer frame is due; last frame retained',
                        'explicit drain before epoch changes; ownership transferred exactly once'])
paths = ['src/video_sync.s', 'src/video_sync.inc', 'src/lamp.inc',
         'tests/video-sync-oracle.c', 'tests/verify-video-sync.py', 'tests/lamp_test.py']
report['sources'] = {s: hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in paths}
report['artifacts'] = {str(s.relative_to(out)): hashlib.sha256(s.read_bytes()).hexdigest()
                       for s in [obj, binary, vectors]}
if args.controls:
    source = (ROOT/'src/video_sync.s').read_text(encoding='utf-8')
    controls = [
        ('stale-epoch', '    cmp r9, [rcx+VS_EPOCH]\n    jne .Lvs_push_bad',
         '    cmp r9, [rcx+VS_EPOCH]\n    nop'),
        ('paused-advance', '    cmp r11d, VS_PAUSED\n    je .Lvs_select_hold',
         '    cmp r11d, VS_PAUSED\n    nop'),
        ('reverse-picture', '    cmp r9, [rcx+VS_LAST_PTS]\n    jl .Lvs_select_drop',
         '    cmp r9, [rcx+VS_LAST_PTS]\n    nop'),
        ('backward-clock', '    cmp r10, [rcx+VS_CLOCK]\n    jl .Lvs_select_bad',
         '    cmp r10, [rcx+VS_CLOCK]\n    nop'),
        ('drop-last-frame', '    cmp eax, 1\n    jbe .Lvs_select_present',
         '    cmp eax, 1\n    nop'),
    ]
    report['negative_controls'] = []
    for name, before, after in controls:
        if source.count(before) != 1:
            raise SystemExit(f'Control anchor changed: {name}')
        path = work/(name+'.s')
        path.write_text(source.replace(before, after), encoding='utf-8')
        control_obj = path.with_suffix('.obj' if WINDOWS else '.o')
        if WINDOWS:
            assembler = shutil.which('llvm-mc')
            command = [assembler, '-triple=x86_64-pc-windows-msvc', '-defsym=WINDOWS=1'] if assembler else None
            if not command:
                # Optional local cross-build toolchain, also used by the player build.
                def wsl_path(x):
                    s = str(x.resolve())
                    return '/mnt/'+s[0].lower()+s[2:].replace('\\', '/')
                toolchain = ROOT/'build/toolchain/root/usr/lib'
                assembler = toolchain/'llvm-18/bin/llvm-mc'
                if not assembler.is_file():
                    raise SystemExit('Negative COFF controls require llvm-mc on PATH or the local WSL toolchain.')
                subprocess.run(['wsl', '-d', 'Ubuntu', '--', 'env',
                                'LD_LIBRARY_PATH='+wsl_path(toolchain/'x86_64-linux-gnu'),
                                wsl_path(assembler), '-triple=x86_64-pc-windows-msvc',
                                '-defsym=WINDOWS=1', '-filetype=obj', '-I', wsl_path(ROOT/'src'),
                                wsl_path(path), '-o', wsl_path(control_obj)], check=True)
            else:
                subprocess.run([*command, '-filetype=obj', '-I', ROOT/'src', path, '-o', control_obj], check=True)
        else:
            subprocess.run(['as', '--64', '-I', ROOT/'src', path, '-o', control_obj], check=True)
        control_exe = work/(name+('.exe' if WINDOWS else ''))
        compile_c(control_exe, [ROOT/'tests/video-sync-oracle.c'], objects=[control_obj],
                  libraries=[] if WINDOWS else ['-no-pie', '-Wl,-z,noexecstack'])
        failed = subprocess.run([str(control_exe), str(vectors)], capture_output=True, timeout=90,
                                **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
        error = failed.stderr.decode('utf-8', 'replace').strip()
        if failed.returncode != 1 or not error.startswith('video-sync line '):
            raise SystemExit(f'Negative control was not detected cleanly: {name}, {failed.returncode}, {error}')
        report['negative_controls'].append(dict(policy=name, exit_code=failed.returncode,
            failure=error, source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            object_sha256=hashlib.sha256(control_obj.read_bytes()).hexdigest(),
            executable_sha256=hashlib.sha256(control_exe.read_bytes()).hexdigest()))
target = out / 'video-sync-verification.json'
target.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
print(f'Video scheduling passed: {report["checks"]} checks, {report["random_operations"]} random operations, {report["audio_clock_vectors"]} exact clock vectors; {report["elapsed_seconds"]}s.')
