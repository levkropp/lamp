#!/usr/bin/env python3
"""FLV Speex against unchanged official float decoding, exact seeks and guards."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT, WINDOWS, compile_c

def run(args,timeout=180):
    p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,
                     **({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    if p.returncode:raise RuntimeError(f'{Path(str(args[0])).name} ({p.returncode}): {p.stdout[-2500:]} {p.stderr[-2500:]}')
    return p.stdout

def tag(kind,data,timestamp=0):
    return bytes([kind])+len(data).to_bytes(3,'big')+(timestamp&0xffffff).to_bytes(3,'big')+bytes([timestamp>>24&255])+bytes(3)+data+(11+len(data)).to_bytes(4,'big')

def flv(tags,extra=0):
    return b'FLV\x01\x04'+(9+extra).to_bytes(4,'big')+bytes(extra)+bytes(4)+b''.join(tag(k,d,20*i) for i,(k,d) in enumerate(tags))

def tags(data):
    at=int.from_bytes(data[5:9],'big')+4;out=[]
    while at+11<=len(data):
        n=int.from_bytes(data[at+1:at+4],'big')
        if at+11+n>len(data):break
        out.append((data[at],data[at+11:at+11+n]));at+=15+n
    return out

def packets(path):
    selected=None;out=[]
    for kind,data in tags(path.read_bytes()):
        if kind&0x3f!=8 or not data:continue
        codec=data[0]>>4
        if selected is None:selected=codec
        if selected==11 and codec==11 and len(data)>1:out.append(data[1:])
    if not out:raise RuntimeError('Missing Speex fixture packets')
    return out

def null_packet(count):
    bits='000001000'*count
    # Canonical zero/ones alignment, no extra byte if already aligned.
    if len(bits)%8:bits+='0'+'1'*((-len(bits)-1)%8)
    return int(bits,2).to_bytes(len(bits)//8,'big')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin',type=Path,default=ROOT/('bin/speex-flv-check' if WINDOWS else 'build/speex-flv-check'))
    p.add_argument('--fixtures',type=Path,help='reuse the recorded FFmpeg corpus')
    p.add_argument('--probe',action='store_true',help='run the muted native Windows engine probe')
    args=p.parse_args();out=args.bin.resolve();work=out/'speex-flv';work.mkdir(parents=True,exist_ok=True);suffix='.exe' if WINDOWS else '';cli=out/('lamp-cli'+suffix)
    fixture_source=args.fixtures.resolve() if args.fixtures else None
    if fixture_source:
        cases=json.loads((fixture_source/'fixtures.json').read_text());version=(fixture_source/'ffmpeg-version.txt').read_text().strip()
        if fixture_source!=work:
            for case in cases:shutil.copyfile(fixture_source/case['file'],work/case['file'])
    else:
        version=run(['ffmpeg','-version']).splitlines()[0];cases=[]
        def add(name,description):cases.append({'file':name,'description':description})
        def encode(name,quality=8,group=1,duration=.43,vbr=False,video=False):
            path=work/name
            source=f'aevalsrc=if(lt(mod(t\\,0.4)\\,0.21)\\,0.24*sin(2*PI*337*t)+0.06*sin(2*PI*911*t)\\,0):s=16000:d={duration}'
            command=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',source]
            if video:command+=['-f','lavfi','-i',f'testsrc=size=64x48:rate=10:duration={duration}','-c:v','flv']
            command+=['-c:a','libspeex','-frames_per_packet',group,'-cbr_quality',quality]
            if vbr:command+=['-q:a','5','-vad','1','-dtx','1']
            run([*command,path]);add(name,f'FFmpeg libspeex quality {quality}, group {group}'+(', VBR/VAD/DTX' if vbr else '')+(', interleaved Sorenson video' if video else ''));return path
        for quality in range(11):encode(f'q{quality}.flv',quality)
        for group in (2,5,8):encode(f'group{group}.flv',group=group,duration=.83)
        encode('vbr-dtx.flv',group=5,duration=1.63,vbr=True)
        encode('video.flv',duration=.63,video=True)
        encode('lifecycle.flv',group=8,duration=12)
        base=tags((work/'q8.flv').read_bytes());audio=[(k,d) for k,d in base if k==8]
        def written(name,contents,description):(work/name).write_bytes(contents);add(name,description)
        written('spec-flags.flv',flv([(8,b'\xb2'+d[1:]) for _,d in audio]),'Adobe 16 kHz mono flags')
        written('changing-flags.flv',flv([(8,bytes([0xb0|(i%16)])+d[1:]) for i,(_,d) in enumerate(audio)]),'all low audio flags ignored; format remains 16 kHz mono')
        interleaved=[]
        for k,d in audio:interleaved += [(8,d),(18,b'ignored script'),(9,b'video'),(0x28,d),(8,b'\x72\0\1')]
        written('skipped-tags.flv',flv(interleaved),'script, video, encrypted and other audio tags skipped')
        mixed=[(8,b'\xb2'+packet) for name in ['q8.flv','group2.flv','group5.flv','group8.flv'] for packet in packets(work/name)[:3]]
        written('changing-groups.flv',flv(mixed),'packet frame counts change across tags')
        written('null-groups.flv',flv([(8,b'\xb2'+null_packet(n)) for n in (1,2,8,64,3)]),'null WB modes, including 64 frames in one bounded packet')
        written('large-header.flv',flv(audio,23),'extended FLV header')
        whole=flv(audio);last=audio[-1][1];written('cut-final-tag.flv',whole[:-(4+len(last)//2)],'incomplete final Speex tag dropped')
        written('empty-tags.flv',flv([item for entry in audio for item in [(8,b''),(8,b'\xb2'),entry]]),'empty audio tags ignored')
    (work/'fixtures.json').write_text(json.dumps(cases,indent=2)+'\n',encoding='utf-8');(work/'ffmpeg-version.txt').write_text(version+'\n',encoding='utf-8')
    spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);source,includes,sources=ref.prepare()
    reference=out/('speex-flv-reference'+suffix)
    compile_c(reference,[ROOT/'tests/speex-file-reference.c',*sources],defines=['FLOATING_POINT','EXPORT=','MAX_CHARS_PER_FRAME=16384'],includes=[*includes,ROOT/'tests'])
    shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'}
    objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared]
    libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
    seek=out/('speex-flv-seek'+suffix);chain=out/('speex-flv-chain'+suffix);guard=out/('speex-flv-guard'+suffix)
    for target,file in [(seek,'seek-oracle.c'),(chain,'chain-oracle.c'),(guard,'speex-flv-oracle.c')]:compile_c(target,[ROOT/'tests'/file],objects=objects,libraries=libraries)
    header=b'Speex   '+b'LAMP test reference'.ljust(20,b'\0')+struct.pack('<13i',1,80,16000,1,4,1,-1,320,0,64,0,0,0)
    checks=[]
    for case in cases:
        path=work/case['file'];ps=packets(path);blob=work/(path.stem+'.packets');blob.write_bytes(struct.pack('<I',80)+header+struct.pack('<I',len(ps))+b''.join(struct.pack('<I',len(x))+x for x in ps));expected=work/(path.stem+'.reference.f32');run([reference,blob,expected]);pcm=work/(path.stem+'.lamp.f32');pcm.unlink(missing_ok=True);stats=run([cli,'--decode',path,pcm]);assert pcm.read_bytes()==expected.read_bytes(),(case,stats)
        detail=json.loads(run([seek,path,expected,0]).strip().splitlines()[-1]);guarded=json.loads(run([guard,path,expected,int(path.name=='q8.flv')]).strip().splitlines()[-1]);checks.append({**case,'result':'exact official float PCM','frames':pcm.stat().st_size//8,'seeks':detail,'guarded':guarded,'fixture_sha256':hashlib.sha256(path.read_bytes()).hexdigest()});print(f"{path.name}: exact PCM, {detail['checks']} seeks and guarded input/output",flush=True)
    malformed=[('illegal-nb-mode.flv',flv([(8,b'\xb2\x48')]),60),('illegal-high-mode.flv',flv([(8,b'\xb2\x06\xbf')]),60),('control-only.flv',flv([(8,b'\xb2\x7f')]),60),('65-frames.flv',flv([(8,b'\xb2'+null_packet(65))]),60),('oversized.flv',flv([(8,b'\xb2'+bytes(1048577))]),101),('empty-only.flv',flv([(8,b'\xb2')]),100)]
    rejected=[]
    for name,data,error in malformed:
        path=work/name;path.write_bytes(data);detail=json.loads(run([chain,'reject',path]).strip().splitlines()[-1]);assert detail['decode_error']==error,(name,detail);rejected.append({'file':name,**detail})
    cancellation=[]
    for mode in ['cancel-open','cancel-read']:cancellation.append({'test':mode,**json.loads(run([chain,mode,work/'lifecycle.flv']).strip().splitlines()[-1])})
    lifecycle=None
    if args.probe:
        if not WINDOWS:raise RuntimeError('Native Windows required for audio probe')
        probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
        detail=run([probe,work/'lifecycle.flv'],timeout=75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail
        lifecycle={'result':'passed','details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()}
    paths=['src/flv.s','src/track.s','src/speex_track.s','tests/speex-file-reference.c','tests/speex-flv-oracle.c','tests/verify-speex-flv.py','tests/seek-oracle.c','tests/chain-oracle.c']
    report={'result':'passed','suite':'speex-flv','recorded_utc':datetime.now(timezone.utc).isoformat(),'platform':platform.platform(),'ffmpeg':version,'reference':'Unchanged test-only Speex 1.2.1 encoder/float decoder; no Ogg trimming for FLV packets','archive_url':ref.URL,'archive_sha256':ref.SHA256,'checks':checks,'rejections':rejected,'cancellation':cancellation,'native_lifecycle':lifecycle,'scope':'FLV 16 kHz mono Speex, grouped packets, ignored low flags, bounded parser/decoding, exact cold seeks and cancellation. FLV timestamp gaps/scheduling, audible latency, captured hardware PCM and native Mac execution are not established.','binaries':{x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cli,reference,seek,chain,guard]},'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}}
    (out/'speex-flv-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(f'Passed {len(checks)} files, {len(checks)*15} exact seeks, {len(rejected)} malformed cases and cancellation.')
if __name__=='__main__':main()
