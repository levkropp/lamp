"""Original B-picture syntax/guards and hardware display-order image comparison."""
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
from h264_b_fixtures import cases
from h264_b_transforms import explicit_b


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, timeout=120):
    return subprocess.run(list(map(str,args)),capture_output=True,timeout=timeout,
                          **({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))


def pictures(path):
    data=path.read_bytes();magic,w,h,n=struct.unpack_from('<4I',data);assert magic==0x31305657
    pos=16;result=[]
    for _ in range(n):
        length,slices=struct.unpack_from('<2I',data,pos);pos+=8
        result.append(data[pos:pos+1040]);pos+=1264+10*slices+length
    assert pos==len(data)
    return result


def negative_controls(out,work):
    source=(ROOT/'src/win/video_stream.s').read_text(encoding='utf-8');records=[]
    controls=[('skip-output-pin','    bts [rsi+HP_HOLD_MASK], eax','    nop'),
              ('reverse-poc','    jle .Lvs_min_next','    jge .Lvs_min_next'),
              ('drop-old-idr','    cmp dword ptr [rsi+HP_FRAME_NOOUTPUT], 0\n    je .Lvs_pop','    cmp dword ptr [rsi+HP_FRAME_NOOUTPUT], 0\n    nop'),
              ('retain-old-display','    btr [rsi+HP_HOLD_MASK], eax\n.Lvs_selected:','    nop\n.Lvs_selected:'),
              ('ignore-busy-decode','    cmp eax, WV_PENDING\n    je .Lvs_return\n    test eax, eax\n    js .Lvs_fail\n    mov dword ptr [rbx+VS_PENDING], 0','    cmp eax, WV_PENDING\n    nop\n    test eax, eax\n    js .Lvs_fail\n    mov dword ptr [rbx+VS_PENDING], 0'),
              ('peek-restores-display','    mov [rcx+WV_CURRENT], edx\n    mov dword ptr [rcx+WV_HAVE_FRAME], 1','    nop'),
              ('preserve-source-pts','    mov rdx, [rbx+VS_PACKET+24]\n    mov [rbx+rcx+VS_QUEUE+16], rdx','    mov rdx, [rbx+VS_PACKET+16]\n    mov [rbx+rcx+VS_QUEUE+16], rdx'),
              ('skip-hidden-output','    test dword ptr [rbx+r13+VS_QUEUE+40], 2\n    jnz .Lvs_hidden','    nop'),
              ('source-epoch-change','    cmp rax, [rbx+VS_SOURCE_EPOCH]\n    jne .Lvs_invalid','    nop'),
              ('peek-does-not-consume','    cmp dword ptr [rbx+VS_PEEK], 0\n    jne .Lvs_peek_ready','    nop')]
    assembler=shutil.which('llvm-mc')
    def convert(path):
        name=str(path.absolute());return name if assembler else '/mnt/'+name[0].lower()+name[2:].replace('\\','/')
    for name,before,after in controls:
        assert source.count(before)==1,name
        path=work/(name+'.s');obj=work/(name+'.obj');binary=work/(name+'.exe');path.write_text(source.replace(before,after),encoding='utf-8')
        options=['-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',convert(ROOT/'src'),'-I',convert(ROOT/'src/win'),convert(path),'-o',convert(obj)]
        if assembler:command=[assembler,*options]
        else:
            lib=ROOT/'build/toolchain/root/usr/lib';command=['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+convert(lib/'x86_64-linux-gnu'),convert(lib/'llvm-18/bin/llvm-mc'),*options]
        r=run(command);assert r.returncode==0,r.stderr
        compile_c(binary,[ROOT/'tests/video-stream-mock.c'],objects=[obj]);r=run([binary])
        assert r.returncode==1 and r.stderr.startswith(b'stream line'),(name,r.returncode,r.stdout,r.stderr)
        records.append(dict(policy=name,scope='CPU-only isolated output-order object; never linked into runtime or used with a GPU.',exit_code=r.returncode,failure=r.stderr.decode().strip(),source_sha256=sha(path),object_sha256=sha(obj),binary_sha256=sha(binary)))
    return records


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',required=True,type=Path)
    p.add_argument('--fixtures',type=Path,default=ROOT/'tests/generated/h264-b');p.add_argument('--generate',action='store_true')
    p.add_argument('--controls',action='store_true')
    args=p.parse_args();out=args.bin.resolve();obj=out/'obj';work=out/'h264-b';work.mkdir(exist_ok=True)
    folder=args.fixtures.resolve();folder.mkdir(parents=True,exist_ok=True)
    oracle=work/('h264-file-oracle'+('.exe' if WINDOWS else ''))
    compile_c(oracle,[ROOT/'tests/h264-file-oracle.c'],objects=[obj/('h264.obj' if WINDOWS else 'h264.o'),obj/('platform.obj' if WINDOWS else 'linux_platform.o')],libraries=list(obj.glob('*.lib')) if WINDOWS else [])
    syntax=[]
    for name,data,accepted,order in cases():
        source=work/(name+'.synthetic');source.write_bytes(data);packet=work/(name+'.wv')
        r=run([oracle,source,packet]);assert r.returncode==(0 if accepted else 1),(name,r.stdout,r.stderr)
        result=json.loads(r.stdout)
        if accepted:assert result['ordering']==list(order),(name,result)
        syntax.append(dict(name=name,accepted=accepted,result=result,source_sha256=sha(source),packet_sha256=sha(packet)))
    print(json.dumps(dict(stage='syntax',cases=len(syntax))),flush=True)
    r=run([oracle,work/'explicit-weights.synthetic','--guard']);assert r.returncode==0,(r.stdout,r.stderr);guarded=json.loads(r.stdout)
    ffmpeg=shutil.which('ffmpeg')
    if args.generate:
        assert ffmpeg
        Bits=runpy.run_path(str(ROOT/'tests/verify-windows-video.py'))['Bits']
        configs=[('main-b1','main','bframes=1:b-pyramid=none'),('main-b3','main','bframes=3:b-pyramid=none'),
                 ('high-pyramid','high','bframes=3:b-pyramid=normal'),('high-strict','high','bframes=8:b-pyramid=strict'),
                 ('high-temporal','high','bframes=3:direct=temporal'),('high-cavlc','high','bframes=3:cabac=0'),
                 ('high-spatial-slices','high','bframes=8:direct=spatial:slices=4'),('main-unweighted','main','bframes=3:weightb=0'),
                 ('high-refs16','high','bframes=3:ref=16'),('high-open-gop','high','bframes=3:open-gop=1'),
                 ('main-explicit-b','main','bframes=3:cabac=0'),('crop-sar','high','bframes=3'),('hd','high','bframes=3')]
        fixtures=[]
        for name,profile,extra in configs:
            w,h,n=(1280,720,24) if name=='hd' else ((318,242,60) if name=='crop-sar' else (320,240,90))
            source,reference,trace=[folder/(name+suffix) for suffix in ('.h264','.nv12','.headers.txt')]
            options=['-vf','setsar=4/3','-colorspace','bt709','-color_range','pc'] if name=='crop-sar' else []
            r=run([ffmpeg,'-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'testsrc2=size={w}x{h}:rate=30',*options,'-frames:v',n,'-c:v','libx264','-profile:v',profile,'-qp','18','-x264-params','threads=1:keyint=30:scenecut=0:b-adapt=0:'+extra,'-f','h264',source]);assert r.returncode==0,r.stderr
            retained=[source,reference,trace]
            if name=='main-explicit-b':
                before=folder/(name+'-original.h264');before.write_bytes(source.read_bytes());retained.append(before)
                source.write_bytes(explicit_b(before.read_bytes(),Bits))
            r=run([ffmpeg,'-hide_banner','-loglevel','error','-y','-i',source,'-vf','scale=in_range=full:out_range=full,format=nv12' if name=='crop-sar' else 'format=nv12','-f','rawvideo',reference]);assert r.returncode==0 and not r.stderr,(name,r.stderr)
            assert reference.stat().st_size==w*h*3//2*n
            r=run([ffmpeg,'-hide_banner','-loglevel','info','-i',source,'-c:v','copy','-bsf:v','trace_headers','-f','null','-']);assert r.returncode==0
            data=b'\n'.join(x for x in r.stderr.splitlines() if b'[trace_headers @' in x)+b'\n';data=re.sub(rb'\[trace_headers @ [^\]]+\]',b'[trace_headers]',data);trace.write_bytes(data)
            fields={field:[int(x) for x in re.findall(rb'\b'+field.encode()+rb'(?:\[\d+\])*\s+\S+\s+=\s+(-?\d+)',data)] for field in ['profile_idc','slice_type','pic_order_cnt_lsb','frame_num','max_num_reorder_frames','max_dec_frame_buffering','weighted_bipred_idc','luma_weight_l1_flag','chroma_weight_l1_flag']}
            assert any(x%5==1 for x in fields['slice_type']),name
            assert set(fields['profile_idc'])=={77 if profile=='main' else 100},(name,fields)
            if name=='main-explicit-b':assert set(fields['weighted_bipred_idc'])=={1} and 1 in fields['chroma_weight_l1_flag']
            fixtures.append(dict(name=name,width=w,height=h,frames=n,header_fields=fields,sha256={f.name:sha(f) for f in retained}))
        (folder/'manifest.json').write_text(json.dumps(dict(reference=run([ffmpeg,'-version']).stdout.decode().splitlines()[0],ffmpeg_sha256=sha(Path(ffmpeg)),fixtures=fixtures),indent=2)+'\n',encoding='utf-8')
    manifest=json.loads((folder/'manifest.json').read_text(encoding='utf-8'));images=[];total=frames=0
    for fixture in manifest['fixtures']:
        name=fixture['name'];source=folder/(name+'.h264');packet=work/(name+'.wv')
        for filename,digest in fixture['sha256'].items():assert sha(folder/filename)==digest
        r=run([oracle,source,packet]);assert r.returncode==0,(name,r.stdout,r.stderr)
        parsed=json.loads(r.stdout);pics=pictures(packet);assert len(pics)==fixture['frames']
        pocs=[struct.unpack_from('<i',pic,32)[0] for pic in pics]
        assert any(y<x for x,y in zip(pocs,pocs[1:])),name
        assert parsed['ordering']==[fixture['header_fields']['max_num_reorder_frames'][0],fixture['header_fields']['max_dec_frame_buffering'][0]]
        image=dict(name=name,pictures=len(pics),parsed=parsed,packet_sha256=sha(packet),decode_order_pocs=pocs)
        if WINDOWS:
            target=work/(name+'.nv12');target.unlink(missing_ok=True)
            r=run([out/'lamp-cli.exe','--video-decode',source,target]);assert r.returncode==0,(name,r.stdout,r.stderr)
            reference=folder/(name+'.nv12');assert target.read_bytes()==reference.read_bytes(),name
            assert f'frames={len(pics)}'.encode() in r.stdout
            frames+=len(pics);total+=target.stat().st_size;image.update(bytes=target.stat().st_size,image_sha256=sha(target))
        images.append(image);print(json.dumps(dict(stage='images',name=name,pictures=len(pics),hardware=WINDOWS)),flush=True)
    mock=None;controls=[]
    if WINDOWS:
        binary=work/'video-stream-mock.exe';compile_c(binary,[ROOT/'tests/video-stream-mock.c'],objects=[obj/'video_stream.obj'])
        r=run([binary]);assert r.returncode==0,(r.stdout,r.stderr);mock=dict(output=r.stdout.decode(),binary_sha256=sha(binary))
        if args.controls:controls=negative_controls(out,work)
    sources=[ROOT/'src'/n for n in ['h264.s','h264.inc','h264_headers.inc','h264_frames.inc','h264_dpb.inc','h264_limits.inc']]+[ROOT/'tests'/n for n in ['h264-file-oracle.c','h264_b_fixtures.py','h264_b_transforms.py','verify-h264-b.py','video-stream-mock.c']]
    artifacts=[oracle,obj/('h264.obj' if WINDOWS else 'h264.o')]
    if WINDOWS:
        sources+=[ROOT/'src/win'/n for n in ['video.s','video.inc','video_stream.s','video_stream.inc','video_cli.s','video_window.s','video_window.inc']]
        artifacts+=[obj/(n+'.obj') for n in ['video','video_stream','video_cli','video_window']]+[out/'lamp-cli.exe',out/'lamp.exe']
    report=dict(result='passed',scope='Progressive8bit420 Main/High B syntax, protected-input CPU mutations, retained output surfaces, GPU display-order NV12 comparison. No container timestamps, audio clock, seeks, fields, higher bit depth or other codec claim.',platform=platform.platform(),syntax=syntax,guarded=guarded,fixtures=manifest,images=images,native_images=frames,native_bytes=total,mock=mock,negative_controls=controls,sources={f.relative_to(ROOT).as_posix():sha(f) for f in sources},artifacts={f.relative_to(out).as_posix():sha(f) for f in artifacts})
    path=out/'h264-b-verification.json';path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(result='passed',syntax=len(syntax),guarded=guarded,native_images=frames,native_bytes=total,report=str(path))))


if __name__=='__main__':main()
