#!/usr/bin/env python3
"""Shipping player versus independent Speex packets and official float PCM."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def run(args,timeout=120):
 r=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if r.returncode:raise RuntimeError(f'{Path(str(args[0])).name}: {r.stdout[-1800:]} {r.stderr[-1800:]}')
 return r.stdout
def packets(path):
 data=path.read_bytes();streams={};selected=None;at=0;pages=[]
 while at<len(data):
  if data[at:at+4]!=b'OggS' or at+27>len(data):raise ValueError('Invalid fixture page')
  flags=data[at+5];gp=struct.unpack_from('<q',data,at+6)[0];serial=struct.unpack_from('<I',data,at+14)[0];laces=data[at+27:at+27+data[at+26]];body=at+27+len(laces);s=streams.setdefault(serial,{'partial':bytearray(),'packets':[]});complete=[]
  for n in laces:
   s['partial']+=data[body:body+n];body+=n
   if n<255:
    p=bytes(s['partial']);s['partial'].clear();s['packets'].append(p);complete.append(len(s['packets']))
    if p.startswith(b'Speex   ') and selected is None:selected=serial
  if serial==selected and complete:pages.append((len(s['packets']),gp,flags))
  at=body
 if selected is None:raise ValueError('Missing Speex fixture')
 allp=streams[selected]['packets'];h=allp[0];extra=struct.unpack_from('<I',h,68)[0];return h,allp[2+extra:],[(c-2-extra,g,f) for c,g,f in pages if c>2+extra]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/('bin/speex-check' if WINDOWS else 'build/speex-check'));p.add_argument('--fixtures',type=Path,help='reuse FFmpeg fixture/probe files from a prior run');args=p.parse_args();out=args.bin.resolve();work=out/'speex-player';work.mkdir(parents=True,exist_ok=True);suffix='.exe' if WINDOWS else '';cli=out/('lamp-cli'+suffix);fixture_source=args.fixtures.resolve() if args.fixtures else None
 ffversion=(fixture_source/'ffmpeg-version.txt').read_text().strip() if fixture_source else run(['ffmpeg','-version']).splitlines()[0];(work/'ffmpeg-version.txt').write_text(ffversion+'\n',encoding='utf-8')
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);source,includes,sources=ref.prepare();reference=out/('speex-file-reference'+suffix);compile_c(reference,[ROOT/'tests/speex-file-reference.c',*sources],defines=['FLOATING_POINT','EXPORT=','MAX_CHARS_PER_FRAME=16384'],includes=[*includes,ROOT/'tests'])
 skip={'player','ui','linux_cli','engine-probe','ui-preview','ui-list','ui-driver'}
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'}
 objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared and x.stem not in skip];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
 chain=out/('speex-chain-oracle'+suffix);compile_c(chain,[ROOT/'tests/chain-oracle.c'],objects=objects,libraries=libraries)
 checks=[];fixtures=[]
 def ff(*args):return run(['ffmpeg','-hide_banner','-loglevel','error','-y',*args])
 def decode(path,output,extra=()):
  if output.exists():output.unlink()
  stats=run([cli,'--decode',*extra,path,output]);return output.read_bytes(),stats
 for mode,rate in enumerate((8000,16000,32000)):
  for channels in (1,2):
   for variant,duration in enumerate((.37,1.23)):
    name=f'speex-{rate}-{channels}-{variant}';path=work/(name+'.spx')
    if fixture_source:shutil.copyfile(fixture_source/path.name,path)
    else:ff('-f','lavfi','-i',f'aevalsrc=0.17*sin(2*PI*337*t)|0.11*sin(2*PI*911*t):s={rate}:d={duration}','-ac',channels,'-c:a','libspeex','-metadata','title='+name,path)
    head,ps,pages=packets(path);blob=work/(name+'.packets');blob.write_bytes(struct.pack('<I',len(head))+head+struct.pack('<I',len(ps))+b''.join(struct.pack('<I',len(x))+x for x in ps));raw=work/(name+'.raw.f32');run([reference,blob,raw]);pcm=raw.read_bytes();raw_frames=len(pcm)//8;group=struct.unpack_from('<I',head,64)[0] or 1;n=160<<mode
    # FFprobe independently timestamps the first audio packet. Final-only
    # pages use the canonical encoder delay when trailing pad obscures it.
    probe=json.loads((fixture_source/(name+'.probe.json')).read_text()) if fixture_source else json.loads(run(['ffprobe','-v','error','-select_streams','a:0','-show_packets','-of','json',path]));(work/(name+'.probe.json')).write_text(json.dumps(probe),encoding='utf-8');first=int(probe['packets'][0]['pts']);encoder_delay=40
    for _ in range(mode):encoder_delay=encoder_delay*2+63
    nonfinal=next(((c,g) for c,g,f in pages if not f&4),None)
    if nonfinal:
     c,g=nonfinal;assert first==g-c*group*n,(name,first,g,c)
    start=max(-first,0)+(40<<mode) if nonfinal else encoder_delay+(40<<mode)
    origin=max(first,0) if nonfinal else 0;end=min(raw_frames,pages[-1][1]-origin+start);expected=pcm[start*8:end*8];expected_path=work/(name+'.expected.f32');expected_path.write_bytes(expected);ours,stats=decode(path,work/(name+'.lamp.f32'));assert ours==expected,(name,len(ours),len(expected),stats);detail=json.loads(run([chain,'check',path,expected_path]).strip().splitlines()[-1]);checks.append({'test':name,'frames':len(ours)//8,'seeks':detail['seeks'],'pcm':'exact official float reference','sha256':hashlib.sha256(path.read_bytes()).hexdigest()});fixtures.append((path,expected_path,rate,channels))
 # Same-rate links compare directly with the independent expected decodes.
 same=work/'same-rate-chain.ogg';same.write_bytes(fixtures[4][0].read_bytes()+fixtures[6][0].read_bytes());expected=work/'same-rate-chain.f32';expected.write_bytes(fixtures[4][1].read_bytes()+fixtures[6][1].read_bytes());checks.append({'test':'same-rate chained Speex','details':json.loads(run([chain,'check',same,expected]).strip().splitlines()[-1])})
 mixed=work/'mixed-rate-chain.ogg';mixed.write_bytes(fixtures[0][0].read_bytes()+fixtures[9][0].read_bytes());resampled,_=decode(fixtures[9][0],work/'resampled.f32',('--rate','8000'));expected=work/'mixed-rate-chain.f32';expected.write_bytes(fixtures[0][1].read_bytes()+resampled);checks.append({'test':'mixed-rate chained Speex and exact seeks','details':json.loads(run([chain,'check',mixed,expected]).strip().splitlines()[-1])})
 # A later Speex BOS page must remain selectable beside a different codec.
 mux=work/'opus-speex.ogg';single=work/'speex-second.spx'
 if fixture_source:
  shutil.copyfile(fixture_source/mux.name,mux);shutil.copyfile(fixture_source/single.name,single)
 else:
  ff('-f','lavfi','-i','sine=frequency=443:sample_rate=48000:duration=1.23','-f','lavfi','-i','sine=frequency=997:sample_rate=16000:duration=1.23','-map','0:a','-map','1:a','-c:a:0','libopus','-c:a:1','libspeex','-metadata:s:a:0','title=Opus first','-metadata:s:a:1','title=Speex second',mux);ff('-copyts','-i',mux,'-map','0:a:1','-c','copy','-avoid_negative_ts','disabled',single)
 a,_=decode(mux,work/'mux.f32',('--track','2'));b,_=decode(single,work/'single.f32');assert a==b;tags=run([cli,'--tags','--track','2',mux]);assert 'Speex second' in tags,tags;checks.append({'test':'second-BOS Speex track selection and tags','frames':len(a)//8})
 # Reverse only the initial BOS pages. Packet bytes, timestamps and CRCs
 # remain unchanged, while the automatic/explicit audio ordinals exchange.
 data=mux.read_bytes();chunks=[];at=0
 while at<len(data):
  count=data[at+26];end=at+27+count+sum(data[at+27:at+27+count]);chunks.append(data[at:end]);at=end
 bos=0
 while bos<len(chunks) and chunks[bos][5]&2:bos+=1
 first_speex=work/'speex-opus.ogg';first_speex.write_bytes(b''.join(reversed(chunks[:bos]))+b''.join(chunks[bos:]));automatic,_=decode(first_speex,work/'speex-auto.f32');explicit,_=decode(first_speex,work/'speex-a1.f32',('--track','1'));assert automatic==explicit==a;original_opus,_=decode(mux,work/'opus-auto.f32');selected_opus,_=decode(first_speex,work/'opus-a2.f32',('--track','2'));assert original_opus==selected_opus;assert 'Speex second' in run([cli,'--tags',first_speex]);checks.append({'test':'automatic first Speex, both audio ordinals and selected metadata','frames':len(a)//8})
 for mode,path in [('cancel-open',fixtures[5][0]),('cancel-read',fixtures[5][0])]:checks.append({'test':mode,'details':json.loads(run([chain,mode,path]).strip().splitlines()[-1])})
 report={'suite':'speex-player','result':'passed','platform':platform.platform(),'ffmpeg':ffversion,'checks':checks,'scope':'Actual CLI decode, selected Ogg stream, tags, same/mixed-rate chains, cold seek/lifecycle/cancellation via full shipping decoder. Native output-device playback and Mac execution are separate checks.','binaries':{x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cli,chain,reference]},'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/speex.s','src/ogg_chain.s','src/tags.s','tests/speex-file-reference.c','tests/chain-oracle.c','tests/verify-speex-player.py']}};(out/'speex-player-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
