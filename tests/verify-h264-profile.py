"""Main/High I/P matrix/weight/CABAC syntax and real hardware image comparison."""
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
from h264_profile_fixtures import cases
from h264_profile_transforms import relocate_scaling, explicit_chroma


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, timeout=90):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout,
                          **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))


def packets(path):
    data = path.read_bytes(); magic, width, height, count = struct.unpack_from('<4I', data); assert magic == 0x31305657
    result = []; position = 16
    for _ in range(count):
        length, slices = struct.unpack_from('<2I', data, position); position += 8
        result.append((data[position:position+1040], data[position+1040:position+1264]))
        position += 1264+10*slices+length
    assert position == len(data)
    return result


def beta_control(out, work):
    """Remove only the beta-offset parse in an isolated test object."""
    original = (ROOT/'src/h264_headers.inc').read_text(encoding='utf-8')
    before = '    HP_SE -1,-6,6,.Lhp_slice_bad\n    HP_SE -1,-6,6,.Lhp_slice_bad\n.Lhp_slice_alignment:'
    assert original.count(before) == 1
    header = work/'h264-skip-beta.inc'; source = work/'h264-skip-beta.s'; obj = work/'h264-skip-beta.obj'; binary = work/'h264-skip-beta.exe'
    header.write_text(original.replace(before, '    HP_SE -1,-6,6,.Lhp_slice_bad\n.Lhp_slice_alignment:'), encoding='utf-8')
    source.write_text((ROOT/'src/h264.s').read_text(encoding='utf-8').replace('.include "h264_headers.inc"', '.include "h264-skip-beta.inc"'), encoding='utf-8')
    assembler = shutil.which('llvm-mc')
    def convert(path):
        if assembler:
            return str(path)
        name = str(path.absolute()); return '/mnt/'+name[0].lower()+name[2:].replace('\\','/')
    args = ['-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',convert(ROOT/'src'),'-I',convert(work),convert(source),'-o',convert(obj)]
    if assembler:
        command = [assembler,*args]
    else:
        lib = ROOT/'build/toolchain/root/usr/lib'
        command = ['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+convert(lib/'x86_64-linux-gnu'),convert(lib/'llvm-18/bin/llvm-mc'),*args]
    subprocess.run(command,check=True)
    compile_c(binary,[ROOT/'tests/h264-file-oracle.c'],objects=[obj,out/'obj/platform.obj'],libraries=list((out/'obj').glob('*.lib')))
    r = run([binary,work/'cabac-deblock-offsets.synthetic',work/'broken-beta.wv'])
    assert r.returncode == 1, (r.stdout,r.stderr)
    return dict(policy='skip-only-beta-offset',scope='CPU-only isolated object rejects the valid nonzero-beta CABAC case; never submitted to a driver.',exit_code=r.returncode,source_sha256=sha(source),header_sha256=sha(header),object_sha256=sha(obj),executable_sha256=sha(binary))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', required=True, type=Path)
    p.add_argument('--fixtures', type=Path, default=ROOT/'tests/generated/h264-profile')
    p.add_argument('--generate', action='store_true')
    p.add_argument('--controls', action='store_true')
    args = p.parse_args(); out = args.bin.resolve(); obj = out/'obj'; folder = args.fixtures.resolve(); folder.mkdir(parents=True, exist_ok=True)
    work = out/'h264-profile'; work.mkdir(exist_ok=True); oracle = work/('h264-file-oracle.exe' if WINDOWS else 'h264-file-oracle')
    compile_c(oracle, [ROOT/'tests/h264-file-oracle.c'], objects=[obj/('h264.obj' if WINDOWS else 'h264.o'), obj/('platform.obj' if WINDOWS else 'linux_platform.o')], libraries=list(obj.glob('*.lib')) if WINDOWS else [])
    syntax = []
    for name, data, matrix, picture in cases():
        source = work/(name+'.synthetic'); source.write_bytes(data); target = work/(name+'.wv')
        r = run([oracle, source, target]); assert r.returncode == (0 if matrix is not None else 1), (name, r.stdout, r.stderr)
        if matrix is not None:
            frames = packets(target); assert len(frames) == 2
            for pic, values in frames:
                assert values == bytes(matrix), (name, list(values), matrix)
                flags = struct.unpack_from('<H', pic, 6)[0]
                assert pic[221] == picture.get('entropy', 0)
                assert (flags >> 8)&1 == picture.get('weighted', 0)
                assert (flags >> 13)&1 == picture.get('transform', 0)
        syntax.append(dict(name=name, accepted=matrix is not None, source_sha256=sha(source), result=json.loads(r.stdout)))
    print(json.dumps(dict(stage='syntax', cases=len(syntax))), flush=True)
    r = run([oracle, work/'sps-custom-inherit.synthetic', '--guard']); assert r.returncode == 0, (r.stdout, r.stderr)
    guarded = json.loads(r.stdout)
    controls = [beta_control(out,work)] if WINDOWS and args.controls else []
    if args.generate:
        ffmpeg = shutil.which('ffmpeg'); assert ffmpeg
        Bits = runpy.run_path(str(ROOT/'tests/verify-windows-video.py'))['Bits']
        custom = ':'.join(f'{name}='+','.join(str(8+(i*step)%100) for i in range(size)) for name, size, step in
                          [('cqm4iy',16,2),('cqm4ic',16,3),('cqm4py',16,4),('cqm4pc',16,5),('cqm8iy',64,1),('cqm8py',64,3)])
        configs = [('main-cabac', 'main', 'cabac=1:8x8dct=0:weightp=0', 320, 240, 45, None),
                   ('main-fade', 'main', 'cabac=1:8x8dct=0:weightp=2', 320, 240, 45, None),
                   ('high-cabac', 'high', 'cabac=1:8x8dct=1:weightp=2', 320, 240, 45, None),
                   ('high-cavlc', 'high', 'cabac=0:8x8dct=1:weightp=1', 320, 240, 45, None),
                   ('high-deblock', 'high', 'cabac=1:8x8dct=1:weightp=2', 320, 240, 30, None),
                   ('high-jvt', 'high', 'cabac=1:8x8dct=1:cqm=jvt', 320, 240, 45, None),
                   ('high-custom', 'high', 'cabac=1:8x8dct=1:'+custom, 320, 240, 45, None),
                   ('sps-custom', 'high', 'cabac=1:8x8dct=1:'+custom, 320, 240, 30, 'sps'),
                   ('pps-rule-b', 'high', 'cabac=1:8x8dct=1:cqm=jvt', 320, 240, 30, 'fallback'),
                   ('chroma-weights', 'main', 'cabac=1:8x8dct=0:weightp=2', 320, 240, 30, 'chroma'),
                   ('slices-4', 'high', 'cabac=1:8x8dct=1:weightp=2:slices=4', 320, 240, 30, None),
                   ('crop-sar', 'high', 'cabac=1:8x8dct=1:weightp=2', 318, 242, 30, None),
                   ('refs-16', 'high', 'cabac=1:8x8dct=1:ref=16', 192, 112, 40, None),
                   ('hd', 'high', 'cabac=1:8x8dct=1', 1280, 720, 16, None)]
        fixtures = []
        for name, profile, extra, width, height, count, transform in configs:
            source, reference, trace_path = [folder/(name+ext) for ext in ('.h264', '.nv12', '.headers.txt')]
            options = ['-vf', 'fade=t=in:st=0:d=1.3'] if name in ('main-fade','chroma-weights') else []
            if name == 'crop-sar':
                options = ['-vf','setsar=4/3','-color_range','pc','-colorspace','bt709']
            if name == 'high-deblock':
                options += ['-deblock','2:3']
            r = run([ffmpeg, '-hide_banner', '-loglevel', 'info', '-y', '-f', 'lavfi', '-i', f'testsrc2=size={width}x{height}:rate=30', *options,
                     '-frames:v', count, '-c:v', 'libx264', '-profile:v', profile, '-qp', '18', '-x264-params', 'threads=1:bframes=0:keyint=30:ref=3:'+extra, '-f', 'h264', source]); assert r.returncode == 0, r.stderr
            usage = [line.split('] ',1)[-1] for line in r.stderr.decode(errors='replace').splitlines() if '8x8 transform' in line or 'Weighted P-Frames' in line]
            retained = [source, reference, trace_path]
            if transform:
                original = folder/(name+'-original.h264'); original.write_bytes(source.read_bytes()); retained.append(original)
                if transform in ('sps', 'fallback'):
                    before = folder/(name+'-before.nv12'); retained.append(before)
                    r = run([ffmpeg, '-hide_banner','-loglevel','error','-y','-i',source,'-pix_fmt','nv12','-f','rawvideo',before]); assert r.returncode == 0, r.stderr
                    source.write_bytes(relocate_scaling(original.read_bytes(), Bits, transform == 'fallback'))
                else:
                    source.write_bytes(explicit_chroma(original.read_bytes(), Bits))
            r = run([ffmpeg, '-hide_banner','-loglevel','error','-y','-i',source,'-vf','scale=in_range=full:out_range=full,format=nv12' if name == 'crop-sar' else 'format=nv12','-f','rawvideo',reference]); assert r.returncode == 0 and not r.stderr, r.stderr
            if transform in ('sps','fallback'):
                assert reference.read_bytes() == before.read_bytes(), 'Relocating/inheriting the same scaling lists must preserve all decoded pixels.'
            r = run([ffmpeg, '-hide_banner','-loglevel','info','-i',source,'-c:v','copy','-bsf:v','trace_headers','-f','null','-']); assert r.returncode == 0
            # Normalize transient log prefixes for a reproducible reference trace.
            trace = b'\n'.join(line for line in r.stderr.splitlines() if b'[trace_headers @' in line)+b'\n'
            trace = re.sub(rb'\[trace_headers @ [^\]]+\]', b'[trace_headers]', trace); trace_path.write_bytes(trace)
            fields = {}
            for field in ['profile_idc','entropy_coding_mode_flag','transform_8x8_mode_flag','weighted_pred_flag','seq_scaling_matrix_present_flag','pic_scaling_matrix_present_flag','luma_weight_l0_flag','chroma_weight_l0_flag','cabac_init_idc','frame_num','slice_alpha_c0_offset_div2','slice_beta_offset_div2']:
                fields[field] = [int(x) for x in re.findall(rb'\b'+field.encode()+rb'(?:\[\d+\])*\s+\S+\s+=\s+(-?\d+)', trace)]
            assert set(fields['profile_idc']) == {77 if profile == 'main' else 100}, (name, fields['profile_idc'])
            if name == 'main-fade':
                assert 1 in fields['luma_weight_l0_flag']
            if transform == 'chroma':
                assert 1 in fields['chroma_weight_l0_flag']
            if name == 'high-deblock':
                assert 2 in fields['slice_alpha_c0_offset_div2'] and 3 in fields['slice_beta_offset_div2']
            fixtures.append(dict(name=name, width=width, height=height, frames=count, transform=transform, header_fields=fields, encoder_usage=usage, sha256={f.name:sha(f) for f in retained}))
        (folder/'manifest.json').write_text(json.dumps(dict(reference=run([ffmpeg,'-version']).stdout.decode().splitlines()[0], ffmpeg_executable_sha256=sha(Path(ffmpeg)), fixtures=fixtures),indent=2)+'\n',encoding='utf-8')
    manifest = json.loads((folder/'manifest.json').read_text(encoding='utf-8')); images = []; native_count = native_bytes = 0
    for item in manifest['fixtures']:
        name = item['name']; source = folder/(name+'.h264'); reference = folder/(name+'.nv12')
        for filename, digest in item['sha256'].items():
            assert sha(folder/filename) == digest
        target = work/(name+'.wv'); r = run([oracle,source,target]); assert r.returncode == 0, (name,r.stdout,r.stderr)
        frames = packets(target); assert len(frames) == item['frames']
        fields = item['header_fields']; expected_entropy = fields['entropy_coding_mode_flag'][0]; expected_transform = fields['transform_8x8_mode_flag'][0] if fields['transform_8x8_mode_flag'] else 0
        for picture, matrix in frames:
            assert picture[221] == expected_entropy
            assert (struct.unpack_from('<H',picture,6)[0] >> 13)&1 == expected_transform
        step = 4 if name == 'slices-4' else 1
        assert [struct.unpack_from('<H',p,214)[0] for p,m in frames] == fields['frame_num'][::step]
        record = dict(name=name, pictures=len(frames), parsed=json.loads(r.stdout), packet_sha256=sha(target))
        if WINDOWS:
            output = work/(name+'.nv12'); output.unlink(missing_ok=True)
            r = run([out/'lamp-cli.exe','--video-decode',source,output]); assert r.returncode == 0, (name,r.stdout,r.stderr)
            assert output.read_bytes() == reference.read_bytes(), name
            record.update(image_sha256=sha(output), bytes=output.stat().st_size); native_count += len(frames); native_bytes += output.stat().st_size
        images.append(record)
    sources = [ROOT/'src'/n for n in ['h264.s','h264.inc','h264_headers.inc','h264_frames.inc','h264_dpb.inc','h264_scaling.inc']]+[ROOT/'tests'/n for n in ['h264-file-oracle.c','h264_file_fixtures.py','h264_profile_fixtures.py','h264_profile_transforms.py','verify-h264-profile.py']]+[ROOT/'THIRD_PARTY_NOTICES']
    artifacts = [oracle,obj/('h264.obj' if WINDOWS else 'h264.o'),out/('lamp-cli.exe' if WINDOWS else 'lamp-cli')]
    if WINDOWS:
        sources += [ROOT/'src/win'/n for n in ['video.s','video.inc','video_cli.s']]
        artifacts += [obj/'video.obj',out/'lamp.exe']
    report = dict(result='passed',scope='Progressive 8-bit 4:2:0 Main/High I/P, CABAC/CAVLC, explicit P weights, 8x8 transform and SPS/PPS scaling-list images. Synthetic coefficient bodies and mutations remain CPU-only; no B/reorder, 10-bit/422/444, bypass or A/V integration established.',platform=platform.platform(),syntax=syntax,guarded=guarded,controls=controls,fixtures=manifest,images=images,native_images=native_count,native_bytes=native_bytes,sources={p.relative_to(ROOT).as_posix():sha(p) for p in sources},artifacts={p.relative_to(out).as_posix():sha(p) for p in artifacts})
    path = out/'h264-profile-verification.json'; path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(result='passed',syntax_cases=len(syntax),guarded=guarded,native_images=native_count,native_bytes=native_bytes,report=str(path))))


if __name__ == '__main__':
    main()
