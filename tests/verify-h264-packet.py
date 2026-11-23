"""Timestamped AVC packets extracted independently from encoded MP4 files. Test-only."""
import argparse
import hashlib
import json
import re
import shutil
import struct
import subprocess
from fractions import Fraction
from pathlib import Path
from lamp_test import ROOT,WINDOWS,compile_c


def run(args):
    r=subprocess.run(list(map(str,args)),capture_output=True,timeout=120,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    assert r.returncode==0,(args,r.returncode,r.stdout[-1000:],r.stderr[-2000:])
    return r.stdout


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def hex_data(text):
    return bytes.fromhex(''.join(line.split(':',1)[1].split('  ',1)[0].replace(' ','') for line in text.splitlines() if ':' in line))


def framing(config,packets):
    return struct.pack('<4I',0x31415048,len(config),len(packets),0)+config+b''.join(struct.pack('<IIqqQQ',len(p['data']),p['rank'],p['dts'],p['pts'],p['duration'],p['epoch'])+p['data'] for p in packets)


def unpack(data):
    _,length,count,_=struct.unpack_from('<4I',data);config=data[16:16+length];pos=16+length;packets=[]
    for _ in range(count):
        size,rank,dts,pts,duration,epoch=struct.unpack_from('<IIqqQQ',data,pos);pos+=40
        packets.append(dict(data=data[pos:pos+size],rank=rank,dts=dts,pts=pts,duration=duration,epoch=epoch));pos+=size
    assert pos==len(data)
    return config,packets


def boundaries(oracle,folder,work):
    config,packets=unpack((folder/'main-b-4.hpa').read_bytes());records=[]
    def reject_config(name,data):
        source=work/(name+'.config');source.write_bytes(data);result=json.loads(run([oracle,source,'--reject-config']));records.append(dict(name=name,config=True,result=result,sha256=sha(source)))
    for name,offset,value in [('version',0,0),('reserved-length',4,3),('three-byte-length',4,254),('no-sps',5,224),('two-sps',5,226),('profile-mismatch',1,100),('constraints-mismatch',2,0),('level-mismatch',3,20),('sps-forbidden',8,231)]:
        b=bytearray(config);b[offset]=value;reject_config(name,b)
    pps_count=8+int.from_bytes(config[6:8],'big')
    for value in [0,2]:
        b=bytearray(config);b[pps_count]=value;reject_config('pps-count-'+str(value),b)
    for size in [0,4097]:
        b=bytearray(config);b[6:8]=size.to_bytes(2,'big');reject_config('sps-size-'+str(size),b)
    reject_config('truncated-pps',config[:pps_count]);reject_config('trailing-main',config+b'\xfd\xf8\xf8\0')
    high,_=unpack((folder/'high-b-4.hpa').read_bytes());assert high[-4:]==b'\xfd\xf8\xf8\0'
    for i in range(4):
        b=bytearray(high);b[-4+i]^=1;reject_config('high-extension-'+str(i),b)
    bad_packets=[('empty-prefix',[dict(packets[0],data=b'\0'*3)]),('zero-nal',[dict(packets[0],data=b'\0'*4)]),('nal-overrun',[dict(packets[0],data=b'\0\0\1\0\x65\x80')]),('nal-limit',[dict(packets[0],data=b'\x01\0\0\x01\x65')]),('forbidden-nal',[dict(packets[0],data=b'\0\0\0\x02\xe5\x80')]),('no-picture',[dict(packets[0],data=b'\0\0\0\x02\x09\xf0')]),('two-pictures',[dict(packets[0],data=packets[0]['data']+packets[1]['data'])]),('duration-zero',[dict(packets[0],duration=0)]),('duration-negative',[dict(packets[0],duration=1<<63)]),('pts-overflow',[dict(packets[0],pts=(1<<63)-1)]),('epoch-zero',[dict(packets[0],epoch=0)]),('epoch-change',[packets[0],dict(packets[1],epoch=2)]),('dts-reversal',[packets[0],dict(packets[1],dts=packets[0]['dts']-1)])]
    for name,items in bad_packets:
        items=[dict(item,rank=i) for i,item in enumerate(items)]
        source=work/(name+'.bad.hpa');source.write_bytes(framing(config,items));result=json.loads(run([oracle,source,'--reject-packet']));records.append(dict(name=name,config=False,result=result,sha256=sha(source)))
    # Negative preroll, equal coarse DTS and older High records without extension.
    sps_size=int.from_bytes(config[6:8],'big');pps_offset=9+sps_size;pps_size=int.from_bytes(config[pps_offset:pps_offset+2],'big')
    parameter_packet=sps_size.to_bytes(4,'big')+config[8:8+sps_size]+pps_size.to_bytes(4,'big')+config[pps_offset+2:pps_offset+2+pps_size]+packets[0]['data']
    for name,cfg,items in [('negative-preroll',config,[dict(packets[0],pts=-1000000000)]),('equal-dts',config,[packets[0],dict(packets[1],dts=packets[0]['dts'])]),('high-no-extension',high[:-4],unpack((folder/'high-b-4.hpa').read_bytes())[1][:1]),('trailing-filler',config,[dict(packets[0],data=packets[0]['data']+b'\0\0\0\x03\x0c\xff\x80')]),('inband-parameters',config,[dict(packets[0],data=parameter_packet)]),('minimum-pts',config,[dict(packets[0],pts=-(1<<63),duration=(1<<63)-1,epoch=(1<<64)-1)])]:
        items=[dict(item,rank=i) for i,item in enumerate(items)]
        source=work/(name+'.valid.hpa');source.write_bytes(framing(cfg,items));result=json.loads(run([oracle,source,work/(name+'.wv')]));records.append(dict(name=name,accepted=True,result=result,sha256=sha(source)))
    return records


def controls(out,work):
    original=(ROOT/'src/h264_packets.inc').read_text(encoding='utf-8');records=[]
    cases=[('three-byte-length','    cmp eax, 2\n    je .Lhpa_open_unsupported','    cmp eax, 2\n    nop','three-byte-length.config','--reject-config'),
           ('profile-mismatch','    cmp al, [r12+1]\n    jne .Lhpa_open_bad','    cmp al, [r12+1]\n    nop','profile-mismatch.config','--reject-config'),
           ('epoch-change','    cmp r8, [rbx+HP_PACKET_EPOCH]\n    jne .Lhpa_next_bad','    cmp r8, [rbx+HP_PACKET_EPOCH]\n    nop','epoch-change.bad.hpa','--reject-packet'),
           ('dts-reversal','    cmp r8, [rbx+HP_PACKET_DTS]\n    jl .Lhpa_next_bad','    cmp r8, [rbx+HP_PACKET_DTS]\n    nop','dts-reversal.bad.hpa','--reject-packet'),
           ('two-pictures','    test eax, eax\n    jnz .Lhpa_next_bad','    test eax, eax\n    nop','two-pictures.bad.hpa','--reject-packet')]
    assembler=shutil.which('llvm-mc')
    def convert(path):
        s=str(path.absolute());return s if assembler else '/mnt/'+s[0].lower()+s[2:].replace('\\','/')
    for name,before,after,input_name,mode in cases:
        assert original.count(before)==1
        header=work/(name+'-control.inc');source=work/(name+'-control.s');obj=work/(name+'-control.obj');binary=work/(name+'-control.exe')
        header.write_text(original.replace(before,after),encoding='utf-8');source.write_text((ROOT/'src/h264.s').read_text(encoding='utf-8').replace('.include "h264_packets.inc"','.include "'+header.name+'"'),encoding='utf-8')
        options=['-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',convert(ROOT/'src'),'-I',convert(work),convert(source),'-o',convert(obj)]
        if assembler:command=[assembler,*options]
        else:
            lib=ROOT/'build/toolchain/root/usr/lib';command=['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+convert(lib/'x86_64-linux-gnu'),convert(lib/'llvm-18/bin/llvm-mc'),*options]
        run(command);compile_c(binary,[ROOT/'tests/h264-packet-oracle.c'],objects=[obj,out/'obj/platform.obj',out/'obj/video.obj'],libraries=list((out/'obj').glob('*.lib')))
        r=subprocess.run([str(binary),str(work/input_name),mode],capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
        assert r.returncode==2 and r.stderr.startswith(b'h264-packet line'),(name,r.returncode,r.stderr)
        records.append(dict(policy=name,scope='Isolated CPU-only parser object; no GPU or audio calls.',exit_code=r.returncode,failure=r.stderr.decode().strip(),sha256={f.name:sha(f) for f in (header,source,obj,binary)}))
    return records


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',required=True,type=Path);p.add_argument('--fixtures',type=Path,default=ROOT/'tests/generated/h264-packet');p.add_argument('--generate',action='store_true')
    p.add_argument('--controls',action='store_true')
    args=p.parse_args();out=args.bin.resolve();work=out/'h264-packet';work.mkdir(exist_ok=True);folder=args.fixtures.resolve();folder.mkdir(exist_ok=True,parents=True);obj=out/'obj'
    oracle=work/('h264-packet-oracle'+('.exe' if WINDOWS else ''))
    objects=[obj/('h264.obj' if WINDOWS else 'h264.o'),obj/('platform.obj' if WINDOWS else 'linux_platform.o')]
    if WINDOWS:objects.append(obj/'video.obj')
    compile_c(oracle,[ROOT/'tests/h264-packet-oracle.c'],objects=objects,libraries=list(obj.glob('*.lib')) if WINDOWS else [])
    if args.generate:
        ffmpeg=shutil.which('ffmpeg');ffprobe=shutil.which('ffprobe');assert ffmpeg and ffprobe;fixtures=[]
        for name,profile,w,h,n,extra,options in [('main-b','main',320,240,90,'bframes=3',[]),('high-b','high',320,240,90,'bframes=8:b-pyramid=strict',[]),('slices','high',192,112,60,'bframes=3:slices=4',[]),('crop','high',318,242,60,'bframes=3',[]),('vfr','main',96,64,30,'bframes=3',['-vf','setpts=(N+floor(N/7))/(30*TB)','-fps_mode','vfr']),('flat','baseline',64,64,45,'bframes=0',[])]:
            source=folder/(name+'.mp4');ref=folder/(name+'.nv12');probe=folder/(name+'.probe.json')
            run([ffmpeg,'-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'color=color=gray:size={w}x{h}:rate=30' if name=='flat' else f'testsrc2=size={w}x{h}:rate=30','-frames:v',n,*options,'-c:v','libx264','-profile:v',profile,'-qp','18','-x264-params','threads=1:keyint=30:b-adapt=0:'+extra,source])
            run([ffmpeg,'-hide_banner','-loglevel','error','-y','-i',source,'-fps_mode','passthrough','-pix_fmt','nv12','-f','rawvideo',ref]);assert ref.stat().st_size==w*h*3//2*n
            info=json.loads(run([ffprobe,'-v','error','-select_streams','v:0','-show_streams','-show_packets','-show_data','-of','json',source]));probe.write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8');assert len(info['packets'])==n
            config=hex_data(info['streams'][0]['extradata']);scale=Fraction(info['streams'][0]['time_base']);pts=sorted(int(x['pts']) for x in info['packets']);assert len(set(pts))==n
            packets=[dict(data=hex_data(x['data']),rank=pts.index(int(x['pts'])),dts=int(int(x['dts'])*scale*1000000000),pts=int(int(x['pts'])*scale*1000000000),duration=int(int(x['duration'])*scale*1000000000),epoch=1) for x in info['packets']]
            variants=[4,2,1] if name=='flat' else [4,2]
            for length in variants:
                cfg=bytearray(config);cfg[4]=(cfg[4]&252)|(length-1);converted=[]
                for packet in packets:
                    data=packet['data'];offset=0;units=[]
                    while offset<len(data):
                        size=int.from_bytes(data[offset:offset+4],'big');offset+=4;nal=data[offset:offset+size];offset+=size;assert len(nal)==size
                        if length==1 and size>255:assert nal[0]&31 not in (1,5);continue
                        assert size<(1<<(8*length));units.append(size.to_bytes(length,'big')+nal)
                    converted.append(dict(packet,data=b''.join(units)))
                packet_file=folder/(name+'-'+str(length)+'.hpa');packet_file.write_bytes(framing(cfg,converted));fixtures.append(dict(name=packet_file.stem,frames=n,sha256={f.name:sha(f) for f in (source,ref,probe,packet_file)},reference=ref.name))
        (folder/'manifest.json').write_text(json.dumps(dict(reference=run([ffmpeg,'-version']).decode().splitlines()[0],ffmpeg_sha256=sha(Path(ffmpeg)),ffprobe_sha256=sha(Path(ffprobe)),fixtures=fixtures),indent=2)+'\n',encoding='utf-8')
    manifest=json.loads((folder/'manifest.json').read_text());images=[]
    for f in manifest['fixtures']:
        for name,digest in f['sha256'].items():assert sha(folder/name)==digest
        target=work/(f['name']+'.wv');args2=[oracle,folder/(f['name']+'.hpa'),target]
        if WINDOWS:args2.append(folder/f['reference'])
        result=json.loads(run(args2));assert result['frames']==f['frames'];images.append(dict(name=f['name'],result=result,packet_sha256=sha(target)));print(json.dumps(images[-1]),flush=True)
    guarded={name:json.loads(run([oracle,folder/(name+'.hpa'),'--guard'])) for name in ['main-b-4','high-b-4']}
    syntax=boundaries(oracle,folder,work)
    negative_controls=controls(out,work) if WINDOWS and args.controls else []
    sources=[ROOT/'src'/n for n in ['h264.s','h264.inc','h264_headers.inc','h264_frames.inc','h264_dpb.inc','h264_scaling.inc','h264_limits.inc','h264_packets.inc','lamp.inc']]+[ROOT/'tests'/n for n in ['h264-packet-oracle.c','verify-h264-packet.py']]
    if WINDOWS:sources += [ROOT/'src/win/video.s',ROOT/'src/win/video.inc',ROOT/'src/win/platform.s',ROOT/'tools/build-windows.py']
    else:sources += [ROOT/'src/linux/platform.s',ROOT/'build.sh']
    report=dict(result='passed',scope='Timestamped AVC packet/frontend component; test-only FFprobe extracts MP4 configuration and access units. No runtime MP4 video demux, window timestamps or audio synchronization established.',fixtures=manifest,images=images,guarded=guarded,syntax=syntax,negative_controls=negative_controls,sources={f.relative_to(ROOT).as_posix():sha(f) for f in sources},artifacts={f.relative_to(out).as_posix():sha(f) for f in [oracle,*objects,out/('lamp-cli.exe' if WINDOWS else 'lamp-cli')]})
    (out/'h264-packet-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(result='passed',images=sum(f['result']['frames'] for f in images),bytes=sum(f['result']['image_bytes'] for f in images),guarded=guarded)))


if __name__=='__main__':main()
