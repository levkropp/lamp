"""Isolated CPU-only counterfactuals for MP4 packet/timestamp policies."""
import json
from pathlib import Path
import shutil
import subprocess

from lamp_test import ROOT, WINDOWS, compile_c


def check_controls(out, work, invoke, sha):
    controls = work/'controls'; controls.mkdir(exist_ok=True)
    main = (ROOT/'src/video_mp4.s').read_text(encoding='utf-8')
    policies = [
        ('late-cancellation', 'video_mp4.s',
         '    mov rax, [rbx+VM_CANCEL]\n    test rax, rax\n    jz .Lvm_open_ready\n    cmp dword ptr [rax], 0\n    jne .Lvm_open_cancel',
         '    jmp .Lvm_open_ready', 'one-allocation', None),
        ('media-range', 'video_mp4.s', '    mov r8, rdi\n    call vm_range',
         '    mov r8, rdi\n    mov eax, 1', 'outside-mdat', None),
        ('unsigned-composition', 'video_mp4_tables.inc',
         '    test r13d, r13d\n    jz .Lvm_ctts_offset\n    movsxd rax, eax',
         '    movsxd rax, eax', 'unsigned-ctts', 'unsigned-ctts'),
        ('fractional-carry', 'video_mp4_time.inc', '    inc rax\n    jo .Lvm_stamp_limit',
         '    nop', 'fraction-carry', 'fraction-carry'),
        ('open-edit-duration', 'video_mp4_time.inc',
         '    cmp qword ptr [rbx+VM_EDIT_DURATION], 0\n    je .Lvm_times_start',
         '    nop', 'open', 'open')]
    records = []
    for name, unit, before, after, fixture, expected in policies:
        original = (ROOT/'src'/unit).read_text(encoding='utf-8')
        assert original.count(before) == 1, name
        patched = original.replace(before, after)
        source = controls/(name+'.s')
        if unit == 'video_mp4.s':
            source.write_text(patched, encoding='utf-8')
            changed = [source]
        else:
            header = controls/(name+'.inc'); header.write_text(patched, encoding='utf-8')
            source.write_text(main.replace('.include "'+unit+'"', '.include "'+header.name+'"'), encoding='utf-8')
            changed = [source, header]
        obj = controls/(name+('.obj' if WINDOWS else '.o'))
        binary = controls/(name+('.exe' if WINDOWS else ''))
        assembler = shutil.which('llvm-mc')
        def convert(path):
            value = str(path.absolute())
            return '/mnt/'+value[0].lower()+value[2:].replace('\\', '/') if WINDOWS and not assembler else value
        lib = ROOT/'build/toolchain/root/usr/lib'
        options = ['-triple='+('x86_64-pc-windows-msvc' if WINDOWS else 'x86_64-pc-linux-gnu'), '-filetype=obj']
        if WINDOWS:
            options.append('-defsym=WINDOWS=1')
        options += ['-I', convert(ROOT/'src'), '-I', convert(controls), convert(source), '-o', convert(obj)]
        if assembler:
            command = [assembler, *options]
        elif WINDOWS:
            command = ['wsl', '-d', 'Ubuntu', '--', 'env', 'LD_LIBRARY_PATH='+convert(lib/'x86_64-linux-gnu'), convert(lib/'llvm-18/bin/llvm-mc'), *options]
        else:
            command = ['env', 'LD_LIBRARY_PATH='+str(lib/'x86_64-linux-gnu'), str(lib/'llvm-18/bin/llvm-mc'), *options]
        subprocess.run(command, check=True, capture_output=True, timeout=30)
        compile_c(binary, [ROOT/'tests/mp4-video-oracle.c'], objects=[obj], defines=['LAMP_MEMORY_ORACLE'])
        source_file = work/'models'/(fixture+'.mp4')
        if name == 'late-cancellation':
            result = subprocess.run([str(binary), str(source_file), '--alloc'], capture_output=True, timeout=30,
                                    **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
            assert result.returncode == 2 and result.stderr.startswith(b'mp4-video line'), (name, result.returncode, result.stderr)
            observation = dict(exit_code=2, failure=result.stderr.decode().strip())
        else:
            code, result = invoke(binary, source_file, controls/(name+'.hpa'))
            assert code == 0, (name, result)
            if expected:
                # Reference is the independent Fraction model, checked against
                # the unmodified assembly before reaching these controls.
                baseline = json.loads((work/'models'/(expected+'.expected.json')).read_text())
                assert result[1:-1] != baseline, name
            observation = dict(exit_code=code, failure='Accepted outside mdat' if not expected else 'Disagreed with independent rational timestamps')
        records.append(dict(policy=name, scope='Isolated altered CPU-only object; never a runtime or GPU fallback',
                            **observation, sha256={p.name: sha(p) for p in [*changed, obj, binary]}))
    return records
