#!/usr/bin/env python3
"""Public MP4 H.264 checking/export and native hidden-window timestamp controls.

FFmpeg/FFprobe generate/decode fixtures only. No audio endpoint is opened.
Opaque/malformed models never enter hardware tests.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
from lamp_test import ROOT, WINDOWS, compile_c
from mp4_video_fixtures import box, full


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, timeout=120):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=timeout,creationflags=subprocess.CREATE_NO_WINDOW)
    assert p.returncode==0,(args,p.returncode,p.stdout[-2000:],p.stderr[-2000:])
    return p.stdout


def hex_data(value):
    return bytes.fromhex(''.join(line.split(':',1)[1].split('  ',1)[0].replace(' ','') for line in value.splitlines() if ':' in line))


def boxes(data):
    pos=0
    while pos<len(data):
        n,kind=struct.unpack_from('>I4s',data,pos);assert 8<=n<=len(data)-pos
        yield kind,pos,data[pos+8:pos+n]
        pos+=n


def find(data,path):
    for name in path.split('/'):
        data=next(body for kind,pos,body in boxes(data) if kind==name.encode())
    return data


def replace(data,path,replacement):
    name,*tail=path.split('/')
    return b''.join(box(kind.decode(),replace(body,'/'.join(tail),replacement)) if kind==name.encode() and tail else replacement if kind==name.encode() else box(kind.decode(),body) for kind,pos,body in boxes(data))


def generate(folder):
    for name,expression in [('cfr','N/(30*TB)'),('vfr','(N+60*floor(N/30))/(30*TB)')]:
        run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=192x112:rate=30','-frames:v','90',
             '-vf','setpts='+expression,'-fps_mode','vfr','-c:v','libx264','-profile:v','high','-qp','20',
             '-x264-params','threads=1:keyint=30:scenecut=0:bframes=3:b-adapt=0',folder/(name+'.mp4')])
    vfr=(folder/'vfr.mp4').read_bytes()
    assert list(boxes(vfr))[-1][0]==b'moov'
    movie_scale=struct.unpack_from('>I',find(vfr,'moov/mvhd'),12)[0]
    media_scale=struct.unpack_from('>I',find(vfr,'moov/trak/mdia/mdhd'),12)[0]
    old=find(vfr,'moov/trak/edts/elst');assert old[:8]==bytes(4)+struct.pack('>I',1)
    start=struct.unpack_from('>i',old,12)[0];assert media_scale%30==0 and movie_scale%4==0
    extra=media_scale*4//30
    elst=full('elst',struct.pack('>I',2)+struct.pack('>Iihh',movie_scale*3//4,-1,1,0)+struct.pack('>Iihh',movie_scale*7//2,start+extra,1,0))
    (folder/'gap-clip.mp4').write_bytes(replace(vfr,'moov/trak/edts/elst',elst))
    manifest=[]
    for name,base,shift,gap,end in [('cfr','cfr',Fraction(0),Fraction(0),None),('vfr','vfr',Fraction(0),Fraction(0),None),
                                   ('gap-clip','vfr',Fraction(3,4)-Fraction(4,30),Fraction(3,4),Fraction(17,4))]:
        source=folder/(name+'.mp4');original=folder/(base+'.mp4')
        probe_path=folder/(base+'.probe.json')
        if not probe_path.exists() or base==name:
            probe_path.write_bytes(run(['ffprobe','-v','error','-select_streams','v:0','-show_streams','-show_packets','-show_data','-of','json',original]))
        probe=json.loads(probe_path.read_text());scale=Fraction(probe['streams'][0]['time_base']);packets=probe['packets']
        stamp=lambda ticks:int((int(ticks)*scale+shift)*10**9//1)
        order=sorted(range(len(packets)),key=lambda i:int(packets[i]['pts']))
        pts=[stamp(x['pts']) for x in packets]
        spans=[stamp(int(x['dts'])+int(x['duration']))-stamp(x['dts']) for x in packets]
        display=list(spans)
        for a,b in zip(order,order[1:]):display[a]=pts[b]-pts[a]
        visible=[];times=[];duration=0;expected=[]
        for i,p in enumerate(packets):
            lo=max(pts[i],int(gap*10**9));hi=min(pts[i]+display[i],int(end*10**9) if end is not None else 2**63-1)
            shown=max(0,hi-lo)
            expected.append(dict(index=i,offset=int(p['pos']),size=int(p['size']),dts_ns=stamp(p['dts']),pts_ns=pts[i],decode_duration_ns=spans[i],flags=(1 if 'K' in p['flags'] else 0)|(2 if not shown else 0),show_pts_ns=lo,show_duration_ns=shown,display_duration_ns=display[i]))
        for rank,i in enumerate(order):
            if expected[i]['show_duration_ns']:
                visible.append(rank);times.append(expected[i]['show_pts_ns']);duration=max(duration,expected[i]['show_pts_ns']+expected[i]['show_duration_ns'])
        timeline=folder/(name+'.htm');timeline.write_bytes(struct.pack('<IIQ',0x314d5448,len(times),duration)+struct.pack('<'+'Q'*len(times),*times))
        (folder/(name+'.expected.json')).write_text(json.dumps(expected,indent=2)+'\n')
        manifest.append(dict(name=name,base=base,visible=visible,duration_ns=duration,source_sha256=sha(source),timeline_sha256=sha(timeline),expected_sha256=sha(folder/(name+'.expected.json'))))
    (folder/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,required=True)
    parser.add_argument('--fixtures',type=Path,default=ROOT/'tests/generated/mp4-play');parser.add_argument('--generate',action='store_true')
    args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();folder=args.fixtures.resolve();work=out/'mp4-play';work.mkdir(exist_ok=True);folder.mkdir(parents=True,exist_ok=True)
    if args.generate:generate(folder)
    obj=out/'obj';libs=[*obj.glob('*.lib'),'user32.lib']
    mock=work/'video-stream-mock.exe';compile_c(mock,[ROOT/'tests/video-stream-mock.c'],objects=[obj/'video_stream.obj'])
    mocked=json.loads(run([mock]));assert mocked['result']=='passed'
    cpu=work/'mp4-video-oracle.exe';compile_c(cpu,[ROOT/'tests/mp4-video-oracle.c'],objects=[obj/'video_mp4.obj',obj/'platform.obj'],libraries=libs)
    window=work/'video-mp4-window-oracle.exe';compile_c(window,[ROOT/'tests/video-mp4-window-oracle.c'],objects=[obj/(n+'.obj') for n in ['h264','video_mp4','video_mp4_h264','platform','video','video_stream','video_present','video_window']],libraries=libs)
    report=dict(result='passed',scope='Native MP4 window/public commands with source timestamps and video-only QPC clock; no audio synchronization',mock=mocked,inputs=[],sources={},artifacts={})
    for source in [*sorted((ROOT/'src/win').glob('video*')),ROOT/'src/video_mp4_h264.s',ROOT/'tests/video-stream-mock.c',ROOT/'tests/video-present-oracle.c',ROOT/'tests/video-mp4-window-oracle.c',Path(__file__)]:
        report['sources'][source.relative_to(ROOT).as_posix()]=sha(source)
    for artifact in [mock,cpu,window,out/'lamp-cli.exe',out/'lamp.exe',*[obj/(n+'.obj') for n in ['h264','video_mp4','video_mp4_h264','platform','video','video_stream','video_present','video_window','video_cli']]]:
        report['artifacts'][artifact.relative_to(out).as_posix()]=sha(artifact)
    for case in json.loads((folder/'manifest.json').read_text()):
        name=case['name'];source=folder/(name+'.mp4');timeline=folder/(name+'.htm');expected_path=folder/(name+'.expected.json')
        assert sha(source)==case['source_sha256'] and sha(timeline)==case['timeline_sha256'] and sha(expected_path)==case['expected_sha256']
        native=[json.loads(x) for x in run([cpu,source,work/(name+'.hpa')]).splitlines()]
        assert native[1:-1]==json.loads(expected_path.read_text()),(name,native[1:-1],json.loads(expected_path.read_text()))
        probe=json.loads((folder/(case['base']+'.probe.json')).read_text());data=source.read_bytes()
        assert bytes.fromhex(native[0]['config'])==hex_data(probe['streams'][0]['extradata'])
        for a,b in zip(native[1:-1],probe['packets']):assert data[a['offset']:a['offset']+a['size']]==hex_data(b['data'])
        reference=work/(name+'.all.nv12');run(['ffmpeg','-hide_banner','-loglevel','error','-y','-ignore_editlist','1','-i',source,'-map','0:v:0','-fps_mode','passthrough','-pix_fmt','nv12','-f','rawvideo',reference])
        stream=probe['streams'][0];frame_bytes=stream['width']*stream['height']*3//2;raw=reference.read_bytes();assert len(raw)==frame_bytes*len(probe['packets'])
        image=b''.join(raw[i*frame_bytes:(i+1)*frame_bytes] for i in case['visible'])
        check=run([out/'lamp-cli.exe','--video-check',source]).decode().strip()
        target=work/(name+'.nv12')
        if target.exists():target.unlink()
        decode=run([out/'lamp-cli.exe','--video-decode',source,target]).decode().strip();assert target.read_bytes()==image,(name,target.stat().st_size,len(image))
        window_result=json.loads(run([window,source,timeline],timeout=90));assert window_result['visible_frames']==len(case['visible'])
        report['inputs'].append(dict(**case,check=check,decode=decode,window=window_result,image_bytes=len(image),sha256={p.name:sha(p) for p in [source,timeline,expected_path,reference,target]}))
        print(name,'exact public export and timestamped window controls',flush=True)
    path=out/'mp4-play-verification.json';path.write_text(json.dumps(report,indent=2)+'\n');print('Passed',path)


if __name__=='__main__':main()
