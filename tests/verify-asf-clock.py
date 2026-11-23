#!/usr/bin/env python3
"""ASF AAC object clocks: independent sample placement, seek primers and bounds."""
import argparse,hashlib,json,platform,shutil,struct,sys
from bisect import bisect_right
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
import importlib.util
def module(name,file):
 s=importlib.util.spec_from_file_location(name,ROOT/'tests'/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
f=module('flv_clock_helpers','verify-flv-clock.py');w=module('asf_clock_writer','verify-asf.py')
run=f.run;nearest=f.nearest

def mux(packets,times,config,rate,ch,layout='plain',preroll=0,offset=0,delta=0):
 fmt=struct.pack('<HHIIHHH',0xff,ch,rate,4000,1,0,len(config))+config
 result=[]
 if layout=='compressed':
  for k in range(0,len(packets),3):
   group=packets[k:k+3];assert all(0<len(x)<=255 for x in group)
   result.append(w.packet([w.payload(b''.join(bytes([len(x)])+x for x in group),k&255,times[k],replic=1,delta=delta)],physical=2048))
 else:
  for k,(data,ms) in enumerate(zip(packets,times)):
   if layout=='fragment':
    cuts=[data[:1],data[1:9],data[9:]];at=0
    for i,piece in enumerate(cuts):
     if not piece:continue
     result.append(w.packet([w.payload(piece,k&255,at,len(data),replic=0 if i==1 else 8,time=ms)],physical=2048));at+=len(piece)
   else:
    items=[w.payload(data,k&255,time=ms,replic=12 if layout=='foreign' else 8)]
    if layout=='foreign':items.insert(0,w.payload(b'ignored',k&255,stream=2,time=0xffffffff))
    result.append(w.packet(items,physical=2048,multi=layout=='foreign' or k%2==0,ecc=k%3!=0))
 streams=[w.stream(fmt,time_offset=offset)]
 if layout=='foreign':streams.append(w.stream(struct.pack('<HHIIHH',0x161,1,8000,8000,1,8),ident=2,time_offset=(1<<64)-1))
 return w.asf(streams,result,minimum=2048,preroll=preroll)

def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/asf-clock-check' if WINDOWS else 'build/asf-clock-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true');args=p.parse_args();out=args.bin.resolve();work=out/'asf-clock';work.mkdir(parents=True,exist_ok=True);ext='.exe' if WINDOWS else '';cli=out/('lamp-cli'+ext)
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'];helpers={}
 for name,file in [('source','track-source-oracle.c'),('oracle','matroska-timing-oracle.c'),('chain','chain-oracle.c'),('guard','asf-clock-oracle.c'),('sparse','flv-clock-sparse-oracle.c'),('compressed','asf-compressed-clock-oracle.c')]:
  helpers[name]=out/('asf-clock-'+name+ext);compile_c(helpers[name],[ROOT/'tests'/file],objects=objects,libraries=libraries)
 def source(path):
  target=work/'source.f32';run([helpers['source'],path,0,target]);return target.read_bytes()
 if args.fixtures:
  origin=args.fixtures.resolve();manifest=json.loads((origin/'fixtures.json').read_text(encoding='utf-8'))
  if origin!=work:
   for name in manifest['files']:shutil.copyfile(origin/name,work/name)
 else:
  manifest={'files':[],'cases':[],'sparse':[],'rejects':[],'lifecycle':[]};bases=[]
  def save(name,data):(work/name).write_bytes(data);manifest['files'].append(name)
  for i,rate in enumerate([8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000]):
   ch=2 if rate==48000 else 1+i%2;name=f'aac-{rate}-{ch}';path=work/(name+'-encoded.flv');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=0.4','-ac',ch,'-c:a','aac','-b:a','32k','-aac_pns','0',path]);audio=[data for kind,data in f.tags(path.read_bytes()) if kind==8];config=next(x[2:] for x in audio if x[1]==0);bases.append((name,rate,ch,[x[2:] for x in audio if x[1]==1],config,1))
  he=module('asf_he_helpers','verify-heaac.py');fixtures=he.Fixtures(work)
  for ps in [False,True]:
   channels=1 if ps else 2;adts,_=fixtures.stream('he-'+str(ps)+'.aac',channels,24000,347 if ps else 139,frames=18,steady=True,ps=ps);packets=list(he.sbr_vectors.raw_blocks(adts.read_bytes()))
   configs={'implicit':[(2,5),(6,4),(channels,4),(0,3)],'explicit':[(29 if ps else 5,5),(6,4),(channels,4),(3,4),(2,5),(0,3)],'sync':[(2,5),(6,4),(channels,4),(0,3),(0x2b7,11),(5,5),(1,1),(3,4)]+([(0x548,11),(1,1)] if ps else [])}
   for kind,fields in configs.items():bases.append(('aac-'+('ps' if ps else 'sbr')+'-'+kind,48000,2,packets,he.sbr_vectors.config_bits(fields),2))
  for label,rate,ch,packets,config,primers in bases:
   path=work/'neutral.asf';path.write_bytes(mux(packets,[0]*len(packets),config,rate,ch));pcm=source(path);lengths=[];before=0
   for n in range(1,len(packets)+1):path.write_bytes(mux(packets[:n],[0]*n,config,rate,ch));after=len(source(path))//8;lengths.append(after-before);before=after
   starts=[];raw=0
   for n in lengths:starts.append(raw);raw+=n
   assert raw*8==len(pcm);suffixes={}
   for pattern in ['continuous','leading','internal','overlap','negative','reorder','foreign','fragment','offset','cancel-large','all-negative','repeat']+(['compressed'] if all(len(x)<=255 for x in packets) else []):
    preroll=3100;offset100=0;shift=-20 if pattern=='negative' else 25 if pattern=='leading' else -0xffffffff if pattern=='all-negative' else 0
    if pattern=='offset':offset100=250061;shift=0
    if pattern=='cancel-large':offset100=((1<<64)//10000-1)*10000;preroll=offset100//10000
    mapping=[];times=[];current=None
    for i,(start,n) in enumerate(zip(starts,lengths)):
     if i==len(packets)//2 and pattern in ['internal','overlap','reorder']:shift+=40 if pattern=='internal' else -20 if pattern=='overlap' else -300
     ms=nearest(start*1000,rate)+shift+(0 if pattern=='cancel-large' else preroll)
     if pattern=='compressed':ms=preroll+nearest(starts[i-i%3]*1000,rate)+i%3*nearest(lengths[0]*1000,rate)
     if pattern=='all-negative':ms=i
     if pattern=='repeat':ms=preroll
     times.append(ms);ns=ms*1000000+offset100*100-preroll*1000000;wanted=nearest(ns*rate,1000000000)-start
     if current is None or abs(wanted-current)>nearest(rate,1000):current=wanted
     for at in range(start,start+n):
      dest=at+current
      if dest<0 or dest<len(mapping):continue
      mapping.extend([None]*(dest-len(mapping)));mapping.append(at)
    name=label+'-'+pattern+'.asf';ref=name+'.f32';save(name,mux(packets,times,config,rate,ch,pattern,preroll,offset100,nearest(lengths[0]*1000,rate)));save(ref,b''.join(bytes(8) if at is None else pcm[at*8:at*8+8] for at in mapping));frames=len(mapping);blob=bytearray()
    for request in [0,1,2,17,119,120,511,512,4095,4096,frames//3,frames//2+1,max(0,frames-1),frames,frames+1,(1<<64)-1]:
     target=min(request,frames);goal=next((x for x in mapping[target:] if x is not None),raw);chosen=max(0,bisect_right(starts,goal)-1-primers)
     if chosen not in suffixes:path.write_bytes(mux(packets[chosen:],[0]*(len(packets)-chosen),config,rate,ch));suffixes[chosen]=source(path)
     decoded=suffixes[chosen];origin=starts[chosen];tail=b''.join(bytes(8) if at is None else decoded[(at-origin)*8:(at-origin+1)*8] for at in mapping[target:]);assert len(tail)==(frames-target)*8;blob+=struct.pack('<QI',target,len(tail))+tail
    reset=name+'.seek-reference';save(reset,blob);manifest['cases'].append(dict(file=name,reference=ref,seek_reference=reset,rate=rate,channels=ch,frames=frames))
   if label=='aac-48000-2':
    small=[x for x in packets if len(x)<=255][:3];assert len(small)==3
    for base,delta in [(0xffffffff,0),(0xffffffff,255)]:
     name=f'compressed-{base}-{delta}.asf';save(name,mux(small,[base+i*delta for i in range(3)],config,rate,ch,'compressed',0,0,delta));path.write_bytes(mux(small,[0]*3,config,rate,ch));ref=name+'.f32';decoded=source(path)
     # Zero delta presents only the first object; nonzero delta inserts two gaps.
     if not delta:decoded=decoded[:lengths[0]*8]
     if delta:
      # Separate sparse checks for each compressed subobject keep reads bounded.
      for count in [1,2,3]:
       only=small[:count];single=f'compressed-tail-{count}.asf';save(single,mux(only,[base+i*delta for i in range(count)],config,rate,ch,'compressed',delta=delta));path.write_bytes(mux(only,[0]*count,config,rate,ch));tail=source(path)[(count-1)*1024*8:];tailref=single+'.f32';save(tailref,tail);manifest['sparse'].append(dict(file=single,reference=tailref,gap_frames=(base+(count-1)*delta)*48,tail_only=True))
     else:save(ref,decoded);manifest['sparse'].append(dict(file=name,reference=ref,gap_frames=base*48))
    for clock in [(1<<63)//100*100, (1<<63)//100*100-100]:
     name=f'offset-limit-{clock}.asf';save(name,mux(packets[:1],[0],config,rate,ch,offset=clock//100));path.write_bytes(mux(packets[:1],[0],config,rate,ch));ref=name+'.f32';save(ref,source(path));manifest['sparse'].append(dict(file=name,reference=ref,gap_frames=nearest(clock*rate,1000000000)))
    for suffix,data in [('offset-overflow',mux(packets[:1],[0],config,rate,ch,offset=(1<<64)-1)),('preroll-overflow',mux(packets[:1],[0],config,rate,ch,preroll=(1<<64)-1))]:
     name=suffix+'.asf';save(name,data);manifest['rejects'].append(name)
    fragmented=bytearray(mux(packets[:1],[3100],config,rate,ch,'fragment',3100));needle=struct.pack('<II',len(packets[0]),3100);at=fragmented.rfind(needle);assert at>0;struct.pack_into('<I',fragmented,at+4,3101);name='fragment-time-conflict.asf';save(name,fragmented);manifest['rejects'].append(name)
    # Serialize the missing offset field coherently instead of deleting bytes.
    fmt=struct.pack('<HHIIHHH',0xff,ch,rate,4000,1,0,len(config))+config
    missing=w.asf([w.stream(fmt)],[w.packet([w.payload(bytes([len(small[0])])+small[0],replic=1)],offset=0,physical=2048)],minimum=2048);name='compressed-missing-time.asf';save(name,missing);manifest['rejects'].append(name)
   if label in ['aac-48000-2','aac-ps-explicit']:
    copies=(rate*12+raw-1)//raw;longpackets=packets*copies;times=[3100+nearest(i*lengths[0]*1000,rate)+100+(500 if i*lengths[0]>=rate*5 else 0) for i in range(len(longpackets))];name=label+'-lifecycle.asf';save(name,mux(longpackets,times,config,rate,ch,preroll=3100));manifest['lifecycle'].append(name)
  manifest['writer_sha256']=hashlib.sha256(Path(__file__).read_bytes().split(b'def main():')[0]+Path(w.__file__).read_bytes().split(b'def main():')[0]).hexdigest()
  manifest['hashes']={name:hashlib.sha256((work/name).read_bytes()).hexdigest() for name in manifest['files']}
 assert manifest['writer_sha256']==hashlib.sha256(Path(__file__).read_bytes().split(b'def main():')[0]+Path(w.__file__).read_bytes().split(b'def main():')[0]).hexdigest()
 for name,digest in manifest['hashes'].items():assert hashlib.sha256((work/name).read_bytes()).hexdigest()==digest
 (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8');checks=[]
 for case in manifest['cases']:
  detail=json.loads(run([helpers['oracle'],work/case['file'],work/case['reference'],0,case['rate'],case['channels'],work/case['seek_reference']]).strip().splitlines()[-1]);target=work/'cli.f32';target.unlink(missing_ok=True);run([cli,'--decode',work/case['file'],target]);assert target.read_bytes()==(work/case['reference']).read_bytes();checks.append({**case,'oracle':detail});print(case['file']+': exact PCM and seeks',flush=True)
 bounds=[]
 for name in ['aac-48000-2-fragment.asf','aac-sbr-explicit-internal.asf','aac-ps-sync-overlap.asf']:
  c=next(x for x in manifest['cases'] if x['file']==name);bounds.append({'file':name,**json.loads(run([helpers['guard'],work/name,work/c['reference'],1,c['rate'],c['channels']]).strip().splitlines()[-1])})
 sparse=[]
 for c in manifest['sparse']:
  sparse.append({**c,**json.loads(run([helpers['compressed' if c.get('tail_only') else 'sparse'],work/c['file'],work/c['reference'],c['gap_frames']]).strip().splitlines()[-1])})
 rejects=[{'file':name,**json.loads(run([helpers['guard'],'--reject',work/name]).strip().splitlines()[-1])} for name in manifest['rejects']];cancellation=[{'mode':mode,**json.loads(run([helpers['chain'],mode,work/manifest['lifecycle'][1]]).strip().splitlines()[-1])} for mode in ['cancel-open','cancel-read']];lifecycle=[]
 if args.probe:
  assert WINDOWS;probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  for name in manifest['lifecycle']:detail=run([probe,work/name],75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'file':name,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 paths=['src/asf.s','src/asf_spread.inc','src/asf_extended.inc','src/track.s','src/track_time.s','src/decoder.s','tests/verify-asf-clock.py','tests/verify-asf.py','tests/verify-flv-clock.py','tests/lamp_test.py','tests/lamp-test.h','tests/verify-heaac.py','tests/sbr_vectors.py','tests/sbr_model.py','tests/ps_model.py','tests/asf-clock-oracle.c','tests/asf-compressed-clock-oracle.c','tests/flv-clock-sparse-oracle.c','tests/matroska-timing-oracle.c','tests/track-source-oracle.c','tests/chain-oracle.c'];report={'result':'passed','platform':platform.platform(),'scope':'ASF AAC-LC and HE-AAC v1/v2 object clocks, preroll and stream offset. Independent media placement and codec primer suffix seeks. Gathered ASF codecs, video synchronization, native Mac and Linux device playback remain unestablished.','fixture_hashes':manifest['hashes'],'fixture_writer_sha256':manifest['writer_sha256'],'checks':checks,'guarded':bounds,'sparse':sparse,'rejects':rejects,'cancellation':cancellation,'native_lifecycle':lifecycle,'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},'binaries':{x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cli,*helpers.values()]}}
 (out/'asf-clock-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files and',len(checks)*16,'media seeks.')
if __name__=='__main__':main()
