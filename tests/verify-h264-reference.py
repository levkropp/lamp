"""H.264 P-picture/DPB metadata, native GPU images and guarded parser checks."""
import argparse
import hashlib
import json
import platform
import re
import runpy
import shutil
import struct
import subprocess
from pathlib import Path
from lamp_test import ROOT, WINDOWS, compile_c
from h264_reference_fixtures import cases, rewrite_flat_marking, rewrite_flat_intra
from h264_file_fixtures import Writer, annex, units, poc_zero


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(args, timeout=90):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout,
                          **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))


def packets(path):
    data = path.read_bytes(); magic, width, height, count = struct.unpack_from('<4I', data)
    assert magic == 0x31305657
    result = []; pos = 16
    for _ in range(count):
        size, slices = struct.unpack_from('<2I', data, pos); pos += 8
        result.append(data[pos:pos+1040]); pos += 1040+224+10*slices+size
    assert pos == len(data)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', type=Path, required=True)
    p.add_argument('--fixtures', type=Path, default=ROOT/'tests/generated/h264-reference')
    p.add_argument('--generate', action='store_true')
    args = p.parse_args(); out = args.bin.resolve(); folder = args.fixtures.resolve(); folder.mkdir(exist_ok=True, parents=True)
    work = out/'h264-reference'; work.mkdir(exist_ok=True)
    suffix = '.exe' if WINDOWS else ''; obj = out/'obj'
    oracle = work/('h264-file-oracle'+suffix)
    compile_c(oracle, [ROOT/'tests/h264-file-oracle.c'], objects=[obj/('h264.obj' if WINDOWS else 'h264.o'), obj/('platform.obj' if WINDOWS else 'linux_platform.o')],
              libraries=list(obj.glob('*.lib')) if WINDOWS else [])
    syntax = []
    for name, data, expected in cases():
        source = work/(name+'.synthetic'); source.write_bytes(data); packet = work/(name+'.wv')
        r = run([oracle, source, packet]); assert r.returncode == (0 if expected is not None else 1), (name, r.stdout, r.stderr)
        if expected is not None:
            pictures = packets(packet); assert len(pictures) == len(expected)
            for pic, (surface, num, poc, refs) in zip(pictures, expected):
                assert pic[4] == surface and struct.unpack_from('<H', pic, 214)[0] == num, (name, surface, pic[4])
                assert struct.unpack_from('<ii', pic, 32) == (poc, poc), (name, poc, struct.unpack_from('<ii', pic, 32))
                assert pic[16:32] == bytes([slot | (128 if long else 0) for slot, _, _, long in refs]+[255]*(16-len(refs))), (name, refs, pic[16:32])
                assert struct.unpack_from('<16H', pic, 176) == tuple([num for _, num, _, _ in refs]+[0]*(16-len(refs)))
                assert struct.unpack_from('<32i', pic, 40) == tuple([value for _, _, value, _ in refs for i in range(2)]+[0]*(32-2*len(refs)))
                assert struct.unpack_from('<I', pic, 208)[0] == (1 << (2*len(refs)))-1
        syntax.append(dict(name=name, accepted=expected is not None, source_sha256=sha(source), result=json.loads(r.stdout)))
    print(json.dumps(dict(stage='syntax', cases=len(syntax))), flush=True)
    guard = run([oracle, work/'marking-1-through-6.synthetic', '--guard']); assert guard.returncode == 0, (guard.stdout, guard.stderr)
    ffmpeg = shutil.which('ffmpeg')
    if args.generate:
        assert ffmpeg, 'Generate the corpus on a host with FFmpeg/x264.'
        fixtures = []
        configs = [(f'refs-{n}', 192, 112, 80, f'ref={n}:keyint=40:min-keyint=40:scenecut=0') for n in (1, 3, 8, 16)]
        configs += [('slices-4', 320, 240, 45, 'ref=3:slices=4:keyint=30'),
                    ('crop-sar', 318, 242, 45, 'ref=3:keyint=30'),
                    ('hd', 1280, 720, 16, 'ref=4:keyint=30'),
                    ('poc0-flat', 64, 64, 40, 'ref=3:keyint=100:min-keyint=100:scenecut=0')]
        configs += [(name, 64, 64, 40, 'ref=1:keyint=100:min-keyint=100:scenecut=0') for name in ('long6', 'adaptive1234', 'reset5')]
        configs.append(('non-idr-i', 64, 64, 40, 'ref=1:keyint=1'))
        for name, width, height, count, options in configs:
            source = folder/(name+'.h264'); ref = folder/(name+'.nv12')
            flat = name in ('poc0-flat', 'long6', 'adaptive1234', 'reset5', 'non-idr-i')
            retained = [source, ref]
            if flat:
                raw = folder/(name+'.yuv'); raw.write_bytes(b''.join(bytes([32+i*4])*4096+bytes([90+i])*1024+bytes([210-i])*1024 for i in range(count)))
                input_args = ['-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', '64x64', '-framerate', '30', '-i', raw]
            else:
                input_args = ['-f', 'lavfi', '-i', f'testsrc2=size={width}x{height}:rate=30']
            r = run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *input_args,
                     '-frames:v', count, '-c:v', 'libx264', '-profile:v', 'baseline', '-qp', '18', '-x264-params', options+':bframes=0:threads=1',
                     *(['-vf', 'setsar=4/3', '-colorspace', 'bt709', '-color_range', 'pc'] if name == 'crop-sar' else []), '-f', 'h264', source]); assert r.returncode == 0, r.stderr
            if flat:
                original = source.read_bytes(); before = folder/(name+'-before.nv12'); original_path = folder/(name+'-original.h264'); original_path.write_bytes(original)
                retained += [original_path, before, raw]
                r = run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', source, '-pix_fmt', 'nv12', '-f', 'rawvideo', before]); assert r.returncode == 0, r.stderr
                legacy = runpy.run_path(str(ROOT/'tests/verify-windows-video.py')); Bits = legacy['Bits']
                frame_bits = legacy['sps'](next(n for n in units(original) if n[0]&31 == 7))['frame_bits']
                if name == 'poc0-flat':
                    changed = []; index = -1
                    for nal in units(original):
                        kind = nal[0]&31
                        if kind == 7:
                            nal = poc_zero(nal, Bits)
                        elif kind in (1, 5):
                            b = Bits(nal); assert b.ue() == 0; assert b.ue() in (0, 2, 5, 7); b.ue(); b.read(frame_bits)
                            if kind == 5:
                                index = 0; b.ue()
                            else:
                                index += 1
                            raw_bits = ''.join(f'{x:08b}' for x in b.data); stop = raw_bits.rfind('1')
                            writer = Writer(); writer.bits = raw_bits[:b.position]; writer.u((index*2)&15, 4)
                            writer.bits += raw_bits[b.position:stop]; nal = writer.nal(nal[0])
                        changed.append(nal)
                    source.write_bytes(annex(*changed))
                elif name == 'non-idr-i':
                    source.write_bytes(rewrite_flat_intra(original, Bits, frame_bits))
                else:
                    source.write_bytes(rewrite_flat_marking(original, name, Bits, frame_bits))
            r = run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', source, '-vf', 'scale=in_range=full:out_range=full,format=nv12' if name == 'crop-sar' else 'format=nv12', '-f', 'rawvideo', ref]); assert r.returncode == 0, r.stderr
            if flat:
                assert ref.read_bytes() == before.read_bytes(), 'POC-only transformation must preserve decoded coefficients/pixels'
            trace = run([ffmpeg, '-hide_banner', '-loglevel', 'info', '-i', source, '-c:v', 'copy', '-bsf:v', 'trace_headers', '-f', 'null', '-']); assert trace.returncode == 0
            headers = trace.stderr.decode('utf-8', errors='replace')
            frame_nums = [int(x) for x in re.findall(r'\bframe_num\s+\S+\s+=\s+(\d+)', headers)]
            mmco = [int(x) for x in re.findall(r'\bmemory_management_control_operation\s+\S+\s+=\s+(\d+)', headers)]
            fixtures.append(dict(name=name, width=width, height=height, frames=count, frame_num_headers=frame_nums, mmco_headers=mmco, sha256={f.name: sha(f) for f in retained}))
        (folder/'manifest.json').write_text(json.dumps(dict(ffmpeg_executable_sha256=sha(Path(ffmpeg)), reference=run([ffmpeg, '-version']).stdout.decode().splitlines()[0], fixtures=fixtures), indent=2)+'\n', encoding='utf-8')
    manifest = json.loads((folder/'manifest.json').read_text(encoding='utf-8'))
    mock = None
    if WINDOWS:
        mock_exe = work/'windows-video-mock.exe'
        compile_c(mock_exe, [ROOT/'tests/windows-video-mock.c'], objects=[obj/'video.obj'])
        r = run([mock_exe]); assert r.returncode == 0, (r.stdout, r.stderr)
        mock = json.loads(r.stdout)
    images = []; frames = 0; total = 0
    for fixture in manifest['fixtures']:
        name = fixture['name']; source = folder/(name+'.h264'); reference = folder/(name+'.nv12')
        for f in (source, reference):
            assert sha(f) == fixture['sha256'][f.name]
        packet = work/(name+'.wv'); r = run([oracle, source, packet]); assert r.returncode == 0, (name, r.stdout, r.stderr)
        pics = packets(packet); assert len(pics) == fixture['frames']
        if 'frame_num_headers' in fixture:
            assert [struct.unpack_from('<H', pic, 214)[0] for pic in pics] == [num for i, num in enumerate(fixture['frame_num_headers']) if i % (4 if name == 'slices-4' else 1) == 0], name
        record = dict(name=name, pictures=len(pics), packet_sha256=sha(packet), parsed=json.loads(r.stdout))
        if WINDOWS:
            output = work/(name+'.nv12'); output.unlink(missing_ok=True)
            r = run([out/'lamp-cli.exe', '--video-decode', source, output]); assert r.returncode == 0, (name, r.stdout, r.stderr)
            assert output.read_bytes() == reference.read_bytes(), name
            frames += len(pics); total += output.stat().st_size; record.update(image_sha256=sha(output), bytes=output.stat().st_size)
        images.append(record)
    sources = [ROOT/'src'/n for n in ['h264.s', 'h264.inc', 'h264_headers.inc', 'h264_frames.inc', 'h264_dpb.inc']]+[ROOT/'tests'/n for n in ['h264-file-oracle.c', 'h264_reference_fixtures.py', 'verify-h264-reference.py', 'windows-video-mock.c']]
    artifacts = [oracle, obj/('h264.obj' if WINDOWS else 'h264.o'), out/('lamp-cli.exe' if WINDOWS else 'lamp-cli')]
    if WINDOWS:
        sources += [ROOT/'src/win'/n for n in ['video.s', 'video.inc', 'video_cli.s', 'video_present.s', 'video_present.inc']]+[ROOT/'tools/build-windows.py']
        artifacts += [mock_exe, out/'lamp.exe', *[obj/(n+'.obj') for n in ['video', 'video_cli', 'video_present']]]
    report = dict(result='passed', platform=platform.platform(), scope='Progressive Baseline/CAVLC I/P reference-picture decoding in decoding/display order. Synthetic syntax/marking cases and mutations are CPU-only, never submitted to a GPU.',
                  syntax=syntax, guarded=json.loads(guard.stdout), fixtures=manifest, images=images, native_images=frames, native_bytes=total, mock=mock,
                  sources={p.relative_to(ROOT).as_posix(): sha(p) for p in sources},
                  artifacts={p.relative_to(out).as_posix(): sha(p) for p in artifacts})
    path = out/'h264-reference-verification.json'; path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(result='passed', syntax_cases=len(syntax), guarded=report['guarded'], native_images=frames, native_bytes=total, report=str(path))))


if __name__ == '__main__':
    main()
