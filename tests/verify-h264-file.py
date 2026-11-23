"""Assembly Annex B header/framing checks and native Windows IDR file export."""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path
from lamp_test import ROOT, WINDOWS, compile_c
from h264_file_fixtures import generate


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, timeout=90):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout,
                          **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))


def cancel_or_write_control(out, work, mode):
    source = (ROOT/'src/win/video_cli.s').read_text(encoding='utf-8')
    if mode == 'cancel':
        before = '    jne .Lvc_output_error\n    jmp .Lvc_next'
        after = '    jne .Lvc_output_error\n    mov dword ptr [rip+vc_cancel], 1\n    jmp .Lvc_next'
    else:
        before = '    mov eax, [rsp+56]\n    cmp eax, [rip+vc_written]'
        after = '    mov dword ptr [rip+vc_written], 0\n'+before
    assert source.count(before) == 1
    path, obj, exe = [work/(mode+'-after-frame'+suffix) for suffix in ['.s', '.obj', '.exe']]
    path.write_text(source.replace(before, after), encoding='utf-8')
    native = shutil.which('llvm-mc') and shutil.which('lld-link')
    def convert(p):
        if native:
            return str(p)
        s = str(p.absolute())
        return '/mnt/'+s[0].lower()+s[2:].replace('\\', '/')
    def llvm(name, args):
        if native:
            command = [shutil.which(name), *args]
        else:
            toolchain = ROOT/'build/toolchain/root/usr/lib'
            tool = toolchain/'llvm-18/bin'/name
            assert tool.parent.is_dir(), 'Test controls need LLVM on PATH or the local WSL toolchain.'
            command = ['wsl', '-d', 'Ubuntu', '--', 'env', 'LD_LIBRARY_PATH='+convert(toolchain/'x86_64-linux-gnu'), convert(tool), *args]
        subprocess.run(command, check=True)
    llvm('llvm-mc', ['-triple=x86_64-pc-windows-msvc', '-filetype=obj', '-defsym=WINDOWS=1',
                    '-I', convert(ROOT/'src'), '-I', convert(ROOT/'src/win'), convert(path), '-o', convert(obj)])
    objects = [out/'obj'/(p.stem+'.obj') for p in sorted((ROOT/'src').glob('*.s'))]
    objects += [out/'obj'/(n+'.obj') for n in ['platform', 'player', 'output_notifications', 'output_format', 'output_exclusive', 'video', 'video_present', 'video_window']]
    llvm('lld-link', ['/nologo', '/nodefaultlib', '/entry:start', '/subsystem:console', '/machine:x64',
                     '/dynamicbase', '/nxcompat', '/opt:ref', '/out:'+convert(exe),
                     *[convert(x) for x in [*objects, obj, *sorted((out/'obj').glob('*.lib'))]]])
    return exe, dict(mode=mode, scope='Test-only CLI object changes one cancel flag or reported write length after one real frame. No console event, desktop input, audio, disk-full simulation or production test hook.',
                     source_sha256=sha(path), object_sha256=sha(obj), executable_sha256=sha(exe))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', required=True, type=Path)
    p.add_argument('--fixtures', type=Path, default=ROOT/'tests/generated/h264-file')
    p.add_argument('--generate', action='store_true')
    p.add_argument('--baseline', type=Path)
    p.add_argument('--controls', action='store_true')
    args = p.parse_args(); out = args.bin.resolve(); folder = args.fixtures.resolve()
    if args.generate:
        generate(folder, os.environ.get('FFMPEG', 'ffmpeg'))
    manifest = json.loads((folder/'manifest.json').read_text(encoding='utf-8'))
    work = out/'h264-file'; work.mkdir(exist_ok=True)
    obj = out/'obj'; ext = '.exe' if WINDOWS else ''
    binary = work/('h264-file-oracle'+ext)
    compile_c(binary, [ROOT/'tests/h264-file-oracle.c'],
              objects=[obj/('h264.obj' if WINDOWS else 'h264.o'), obj/('platform.obj' if WINDOWS else 'linux_platform.o')],
              libraries=list(obj.glob('*.lib')) if WINDOWS else ['-no-pie', '-Wl,-z,noexecstack'])
    checks = []; actual_images = actual_bytes = 0
    cli = out/('lamp-cli'+ext)
    for item in manifest['fixtures']:
        name = item['name']; source = folder/(name+'.h264'); packed = work/(name+'.wv')
        for file, digest in item['sha256'].items():
            assert sha(folder/file) == digest, file
        result = run([binary, source, packed])
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        cpu = json.loads(result.stdout); assert cpu['pictures'] == item['frames']
        independent = item['independent_packet_oracle']
        if independent:
            assert packed.read_bytes() == source.with_suffix('.wv').read_bytes(), name
        record = dict(name=name, cpu=cpu, independent_packet_oracle=independent, packet_sha256=sha(packed))
        if WINDOWS:
            target = work/(name+'.nv12'); target.unlink(missing_ok=True)
            decoded = run([cli, '--video-decode', source, target])
            text = decoded.stdout.decode('utf-8', 'replace').strip()
            expected = f'width={item["width"]} height={item["height"]} '
            assert decoded.returncode == 0 and expected in text and f'frames={item["frames"]}' in text, (name, text, decoded.stderr)
            assert target.read_bytes() == (folder/(name+'.nv12')).read_bytes(), name
            digest = sha(target)
            overwrite = run([cli, '--video-decode', source, target])
            assert overwrite.returncode != 0 and sha(target) == digest, name
            checked = run([cli, '--video-check', source])
            assert checked.returncode == 0 and b'video=h264 backend=d3d11' in checked.stdout, name
            record.update(native_stats=text, image_sha256=digest, no_overwrite=True, native_check=True)
            actual_images += item['frames']; actual_bytes += target.stat().st_size
        checks.append(record)
    synthetic = []
    for item in manifest['synthetic']:
        source = folder/(item['name']+'.synthetic'); assert sha(source) == item['sha256']
        result = run([binary, source, work/(item['name']+'.synthetic.wv')])
        assert result.returncode == (0 if item['accepted'] else 1), (item['name'], result.stdout, result.stderr)
        record = json.loads(result.stdout)
        if item['metadata'] is not None:
            assert record['metadata'] == item['metadata'], (item['name'], record)
        synthetic.append(dict(name=item['name'], accepted=item['accepted'], result=record))
    unsupported = []
    for item in manifest['unsupported']:
        source = folder/(item['name']+'.h264'); assert sha(source) == item['sha256']
        result = run([binary, source, work/(item['name']+'.rejected.wv')])
        assert result.returncode == 1, (item['name'], result.stdout, result.stderr)
        if WINDOWS:
            target = work/(item['name']+'.rejected.nv12'); target.unlink(missing_ok=True)
            result = run([cli, '--video-decode', source, target])
            assert result.returncode != 0 and not target.exists(), (item['name'], result.stdout)
        unsupported.append(dict(name=item['name'], rejected=True))
    guarded = run([binary, folder/'base-64x64.h264', '--guard'])
    assert guarded.returncode == 0, (guarded.stdout, guarded.stderr)
    guards = json.loads(guarded.stdout)
    controls = []
    if WINDOWS:
        source = folder/'base-64x64.h264'; initial = sha(source)
        alias = run([cli, '--video-decode', source, source]); assert alias.returncode != 0 and sha(source) == initial
        for operands in [[], [source, source], ['--start', '1', source]]:
            bad = run([cli, '--video-check', *operands]); assert bad.returncode == 2
        unicode_source = work/'vidéo Ω 🎞.h264'; unicode_source.write_bytes(source.read_bytes())
        unicode_target = work/'décodé Ω 🎞.nv12'; unicode_target.unlink(missing_ok=True)
        result = run([cli, '--video-decode', unicode_source, unicode_target])
        assert result.returncode == 0 and unicode_target.read_bytes() == (folder/'base-64x64.nv12').read_bytes()
        if args.baseline:
            result = run([args.baseline.resolve(), '--video-check', source])
            assert b'video=h264' not in result.stdout
            controls.append(dict(mode='published-before-file-reader', executable_sha256=sha(args.baseline.resolve()),
                                 exit_code=result.returncode, missing_video_result=True))
        if args.controls:
            for mode, expected in [('cancel', b'Video operation cancelled.'), ('write', b'Cannot create or write video output')]:
                controlled, record = cancel_or_write_control(out, work, mode)
                target = work/(mode+'-partial.nv12'); target.unlink(missing_ok=True)
                result = run([controlled, '--video-decode', source, target])
                assert result.returncode == 1 and expected in result.stdout and not target.exists(), (mode, result.stdout, result.stderr)
                record.update(exit_code=1, partial_output_removed=True); controls.append(record)
    sources = ['src/h264.s', 'src/h264.inc', 'src/h264_headers.inc', 'src/h264_frames.inc', 'src/h264_dpb.inc', 'src/h264_scaling.inc', 'src/lamp.inc',
               'tests/h264-file-oracle.c', 'tests/h264_file_fixtures.py', 'tests/verify-h264-file.py', 'tests/verify-windows-video.py']
    if WINDOWS:
        sources += ['src/win/video_cli.s', 'src/win/video.s', 'src/win/video.inc', 'src/win/player.s', 'src/win/kernel32.def', 'tools/build-windows.py', 'tests/verify-runtime.js']
    report = dict(result='passed', scope='Assembly Baseline/CAVLC Annex B IDR frontend. CPU-only synthetic and mutated inputs never go to the GPU. Native Windows file check/export is exact against decoded NV12 references; no window presentation, P/B-reference frames, container video or A/V sync established.',
                  platform=platform.platform(), fixtures=manifest, checks=checks, synthetic=synthetic, unsupported=unsupported,
                  guarded=guards, controls=controls, native_images=actual_images, native_image_bytes=actual_bytes,
                  sources={s: sha(ROOT/s) for s in sources}, artifacts={str(x.relative_to(out)): sha(x) for x in [binary, obj/('h264.obj' if WINDOWS else 'h264.o'), cli]})
    if WINDOWS:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'HARDWARE\DESCRIPTION\System\CentralProcessor\0') as cpu_key:
            cpu = winreg.QueryValueEx(cpu_key, 'ProcessorNameString')[0].strip()
        inventory = run(['powershell', '-NoProfile', '-Command',
            '@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,VideoProcessor) | ConvertTo-Json -Compress'])
        try:
            graphics = json.loads(inventory.stdout) if inventory.returncode == 0 else None
        except ValueError:
            graphics = None
        report['verification_host'] = dict(cpu=cpu, graphics=graphics)
    (out/'h264-file-verification.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'H264 files passed: {len(checks)} encoded files, {len(synthetic)} CPU-only synthetic cases, {guards["opens"]} guarded opens, {actual_images} native GPU images / {actual_bytes} exact bytes.')


if __name__ == '__main__':
    main()
