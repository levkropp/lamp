"""Actual D3D11 H.264 IDR hardware image checks (Windows only).

The Python bitstream reader is test-only. The unintegrated assembly submission
backend does not yet parse files, present images or provide player video support.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import time
from pathlib import Path
from lamp_test import ROOT, WINDOWS, compile_c


class Bits:
    def __init__(self, nal):
        self.data = re.sub(b'\x00\x00\x03', b'\x00\x00', nal[1:])
        self.position = 0

    def read(self, n=1):
        value = 0
        for _ in range(n):
            if self.position >= len(self.data)*8:
                raise ValueError('truncated fixture header')
            value = value*2+((self.data[self.position//8] >> (7-self.position%8)) & 1)
            self.position += 1
        return value

    def ue(self):
        zeros = 0
        while not self.read():
            zeros += 1
            if zeros > 31:
                raise ValueError('fixture Exp-Golomb overflow')
        return (1 << zeros)-1+self.read(zeros)

    def se(self):
        value = self.ue()
        return (value+1)//2 if value & 1 else -value//2


def sps(nal):
    b = Bits(nal)
    profile, constraints, level = b.read(8), b.read(8), b.read(8)
    assert profile == 66 and not constraints & 3
    ident, frame_bits, poc = b.ue(), b.ue()+4, b.ue()
    assert 4 <= frame_bits <= 16 and poc in (0, 2)
    poc_bits = b.ue()+4 if poc == 0 else 0
    refs, gaps = b.ue(), b.read()
    width, height = (b.ue()+1)*16, (b.ue()+1)*16
    assert b.read() == 1  # progressive
    direct = b.read()
    assert b.read() == 0  # uncropped fixture
    return dict(id=ident, frame_bits=frame_bits, poc=poc, poc_bits=poc_bits,
                refs=refs, gaps=gaps, width=width, height=height, direct=direct, level=level)


def pps(nal):
    b = Bits(nal)
    ident, seq, entropy, order = b.ue(), b.ue(), b.read(), b.read()
    groups = b.ue()
    assert entropy == order == groups == 0
    l0, l1, weighted, bipred = b.ue(), b.ue(), b.read(), b.read(2)
    qp, qs, chroma = b.se(), b.se(), b.se()
    deblock, constrained, redundant = b.read(), b.read(), b.read()
    assert weighted == bipred == redundant == 0
    return dict(id=ident, seq=seq, l0=l0, l1=l1, qp=qp, qs=qs, chroma=chroma,
                deblock=deblock, constrained=constrained)


def packet(nal, seq, pic, index):
    b = Bits(nal)
    assert b.ue() == 0 and b.ue() in (2, 7) and b.ue() == pic['id']
    frame_num = b.read(seq['frame_bits'])
    ident = b.ue()
    poc = b.read(seq['poc_bits']) if seq['poc'] == 0 else 0
    assert frame_num == poc == 0 and ident <= 65535
    no_output, long_term = b.read(), b.read()
    assert long_term == 0
    params = bytearray(1040)
    flags = 0x9810 | 0x40 | (pic['constrained'] << 7)
    if seq['level'] >= 31:
        flags |= 0x4000
    struct.pack_into('<HHBBHBBHI', params, 0, seq['width']//16-1, seq['height']//16-1,
                     0, seq['refs'], flags, 0, 0, 3, index+1)
    params[16:32] = bytes([255])*16
    struct.pack_into('<ii', params, 32, poc, poc)
    struct.pack_into('<bbbbbbb', params, 168, pic['qs'], pic['chroma'], pic['chroma'],
                     1, pic['qp'], pic['l0'], pic['l1'])
    struct.pack_into('<H', params, 214, frame_num)
    params[216:227] = bytes([seq['frame_bits']-4, seq['poc'], max(0, seq['poc_bits']-4),
                            0, seq['direct'], 0, 0, 0, 0, pic['deblock'], 0])
    bitstream = b'\0\0\1'+nal
    bitstream += bytes((-len(bitstream)) % 128)
    return struct.pack('<II', len(bitstream), 1)+params+bytes([16])*224+struct.pack('<IIH', 0, len(bitstream), 0)+bitstream


def fixture(path, target):
    units = re.split(b'\x00\x00(?:\x00)?\x01', path.read_bytes())
    seq = pic = None
    packets = []
    for nal in units:
        if not nal:
            continue
        kind = nal[0] & 31
        if kind == 7:
            current = sps(nal)
            assert seq is None or current == seq
            seq = current
        elif kind == 8:
            current = pps(nal)
            assert pic is None or current == pic
            pic = current
        elif kind == 5:
            assert seq and pic and seq['id'] == pic['seq']
            packets.append(packet(nal, seq, pic, len(packets)))
        else:
            assert kind in (6, 9, 12)
    assert len(packets) == 8
    target.write_bytes(struct.pack('<4sIII', b'WV01', seq['width'], seq['height'], len(packets))+b''.join(packets))
    return seq, pic


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', required=True, type=Path)
    p.add_argument('--controls', action='store_true', help='prove five deliberately broken backend objects fail mock checks')
    args = p.parse_args()
    if not WINDOWS:
        raise SystemExit('Windows hardware execution required.')
    out = args.bin.resolve()
    obj = out/'obj/video.obj'
    assert obj.is_file(), 'Build tools/build-windows.py first.'
    work = out/'windows-video'
    work.mkdir(exist_ok=True)
    ffmpeg = os.environ.get('FFMPEG', 'ffmpeg')
    encoder_version = subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0]
    files, arguments = [], []
    for w, h in [(64, 64), (192, 112), (320, 240), (640, 368), (1280, 720), (1920, 1088)]:
        source, packed, reference = [work/f'{w}x{h}.{suffix}' for suffix in ['h264', 'wv', 'nv12']]
        command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                   f'testsrc2=size={w}x{h}:rate=24', '-frames:v', '8', '-c:v', 'libx264',
                   '-profile:v', 'baseline', '-preset', 'medium', '-x264-params',
                   'keyint=1:scenecut=0:ref=1:bframes=0:cabac=0:8x8dct=0:threads=1:slices=1',
                   '-pix_fmt', 'yuv420p', '-f', 'h264', source]
        subprocess.run([str(x) for x in command], check=True)
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
                        '-pix_fmt', 'nv12', '-f', 'rawvideo', str(reference)], check=True)
        seq, pic = fixture(source, packed)
        files.append(dict(width=w, height=h, frames=8, sps=seq, pps=pic,
                          sha256={x.name: hashlib.sha256(x.read_bytes()).hexdigest() for x in [source, packed, reference]}))
        arguments.extend([str(packed), str(reference)])
    binary = work/'windows-video-oracle.exe'
    mock_binary = work/'windows-video-mock.exe'
    compile_c(mock_binary, [ROOT/'tests/windows-video-mock.c'], objects=[obj])
    mocked = subprocess.run([str(mock_binary)], capture_output=True, timeout=30,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    if mocked.returncode:
        raise SystemExit(f'GPU failure/ownership checks failed: {mocked.stderr.decode("utf-8", "replace")}')
    mock_report = json.loads(mocked.stdout)
    compile_c(binary, [ROOT/'tests/windows-video-oracle.c'], objects=[obj], libraries=['d3d11.lib'])
    begin = time.perf_counter()
    result = subprocess.run([str(binary), *arguments], capture_output=True, timeout=90,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    log = result.stdout.decode('utf-8', 'replace')
    (work/'oracle-output.txt').write_text(log, encoding='utf-8')
    if result.returncode:
        raise SystemExit(f'GPU image verification failed ({result.returncode}): {log} {result.stderr.decode("utf-8", "replace")}')
    report = json.loads(log.splitlines()[-1])
    import winreg
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'HARDWARE\DESCRIPTION\System\CentralProcessor\0') as cpu_key:
        cpu = winreg.QueryValueEx(cpu_key, 'ProcessorNameString')[0].strip()
    inventory = subprocess.run(['powershell', '-NoProfile', '-Command',
        '@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,VideoProcessor) | ConvertTo-Json -Compress'],
        capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
    inventory_text = inventory.stdout.decode('utf-8', 'replace').strip()
    try:
        graphics_inventory = json.loads(inventory_text) if inventory.returncode == 0 else None
    except ValueError:
        graphics_inventory = None
    report.update(scope='Hardware submission/readback component only. Test-only Python supplies H.264 headers and DXVA metadata. No assembly file parser, player video playback, presentation, reference pictures, A/V sync or other codec support is established.',
                  verification_host=dict(cpu=cpu, platform=platform.platform(), graphics=graphics_inventory),
                  elapsed_seconds=round(time.perf_counter()-begin, 6), reference=encoder_version,
                  ffmpeg_executable_sha256=hashlib.sha256(Path(shutil.which(ffmpeg) or ffmpeg).read_bytes()).hexdigest(),
                  mocked_failures=mock_report,
                  adapter_log=log.splitlines()[:-1], fixtures=files,
                  sources={s: hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in
                           ['src/win/video.s', 'src/win/video.inc', 'src/win/d3d11.def',
                            'src/lamp.inc', 'tests/windows-video-oracle.c', 'tests/windows-video-mock.c', 'tests/verify-windows-video.py']},
                  artifacts={str(x.relative_to(out)): hashlib.sha256(x.read_bytes()).hexdigest() for x in [obj, binary, mock_binary]})
    if args.controls:
        source = (ROOT/'src/win/video.s').read_text(encoding='utf-8')
        controls = [
            ('ignore-small-buffer', '    cmp [rbx+WV_BUFFER_SIZE], eax\n    jb .Lwv_decode_short',
             '    cmp [rbx+WV_BUFFER_SIZE], eax\n    nop'),
            ('skip-release', '    mov qword ptr [rbx+rdi], 0\n    mov rax, [rcx]\n    call [rax+16]',
             '    mov qword ptr [rbx+rdi], 0\n    mov rax, [rcx]\n    nop'),
            ('repeat-copy', '    cmp dword ptr [rbx+WV_COPY_PENDING], 0\n    jne .Lwv_read_map',
             '    cmp dword ptr [rbx+WV_COPY_PENDING], 0\n    nop'),
            ('blocking-map', '    mov qword ptr [rsp+32], 0x100000', '    mov qword ptr [rsp+32], 0'),
            ('missing-syntax', '    cmp byte ptr [rsi+171], 1 # remaining syntax fields must be present\n    jne .Lwv_decode_invalid',
             '    cmp byte ptr [rsi+171], 1\n    nop'),
        ]
        report['negative_controls'] = []
        for name, before, after in controls:
            assert source.count(before) == 1, name
            path, control_obj = work/(name+'.s'), work/(name+'.obj')
            path.write_text(source.replace(before, after), encoding='utf-8')
            assembler = shutil.which('llvm-mc')
            if assembler:
                subprocess.run([assembler, '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
                                '-defsym=WINDOWS=1', '-I', ROOT/'src', '-I', ROOT/'src/win', path, '-o', control_obj], check=True)
            else:
                def wsl_path(x):
                    s = str(x.absolute())
                    return '/mnt/'+s[0].lower()+s[2:].replace('\\', '/')
                toolchain = ROOT/'build/toolchain/root/usr/lib'
                assembler = toolchain/'llvm-18/bin/llvm-mc'
                assert assembler.parent.is_dir(), 'Controls need llvm-mc on PATH or the local WSL toolchain.'
                subprocess.run(['wsl', '-d', 'Ubuntu', '--', 'env',
                                'LD_LIBRARY_PATH='+wsl_path(toolchain/'x86_64-linux-gnu'), wsl_path(assembler),
                                '-triple=x86_64-pc-windows-msvc', '-filetype=obj', '-defsym=WINDOWS=1',
                                '-I', wsl_path(ROOT/'src'), '-I', wsl_path(ROOT/'src/win'),
                                wsl_path(path), '-o', wsl_path(control_obj)], check=True)
            control_exe = work/(name+'.exe')
            compile_c(control_exe, [ROOT/'tests/windows-video-mock.c'], objects=[control_obj])
            failed = subprocess.run([str(control_exe)], capture_output=True, timeout=30,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            error = failed.stderr.decode('utf-8', 'replace').strip()
            assert failed.returncode == 1 and error.startswith('video-mock line'), (name, failed.returncode, error)
            report['negative_controls'].append(dict(policy=name, exit_code=failed.returncode, failure=error,
                source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                object_sha256=hashlib.sha256(control_obj.read_bytes()).hexdigest(),
                executable_sha256=hashlib.sha256(control_exe.read_bytes()).hexdigest()))
    (out/'windows-video-verification.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'Hardware H.264 images passed: {report["frames"]} frames, {report["image_bytes_compared"]} exact NV12 bytes; {report["pending_readbacks"]} cancellable retry points.')


if __name__ == '__main__':
    main()
