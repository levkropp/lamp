#!/usr/bin/env python3
"""Signed FLV packet audio clocks, independent sample placement and seeks."""
import argparse,hashlib,importlib.util,json,platform,random,shutil,struct,subprocess,sys
from bisect import bisect_right
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def run(args,timeout=120):
 p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if p.returncode:raise RuntimeError(f'{args[0]} ({p.returncode}): {p.stdout[-1000:]} {p.stderr[-2000:]}')
 return p.stdout
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def tags(data):
 at=int.from_bytes(data[5:9],'big')+4;result=[]
 while at+11<=len(data):
  n=int.from_bytes(data[at+1:at+4],'big');assert at+11+n<=len(data);result.append((data[at],data[at+11:at+11+n]));at+=15+n
 return result
def tag(kind,data,ms):return bytes([kind])+len(data).to_bytes(3,'big')+(ms&0xffffff).to_bytes(3,'big')+bytes([ms>>24&255])+bytes(3)+data+(11+len(data)).to_bytes(4,'big')
def mux(packets,times,config=None,foreign=False,extra=0):
 result=b'FLV\1\4'+(9+extra).to_bytes(4,'big')+bytes(extra)+bytes(4)
 if config is not None:result+=tag(8,config,0x7fffffff)
 for i,(packet,ms) in enumerate(zip(packets,times)):
  if foreign and i:result+=tag(18,b'script',0x7fffffff)+tag(9,b'video',-0x80000000)+tag(0x28,packet,0x12345678)+tag(8,b'\x62junk',-999999)
  if config is not None and i==3:result+=tag(8,config,0x1000001)
  result+=tag(8,packet,ms)
 return result
def nearest(n,d):return (n+d//2)//d if n>=0 else -((-n+d//2)//d)
def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/flv-clock-check' if WINDOWS else 'build/flv-clock-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true');args=p.parse_args();out=args.bin.resolve();work=out/'flv-clock';work.mkdir(parents=True,exist_ok=True);ext='.exe' if WINDOWS else '';cli=out/('lamp-cli'+ext)
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
 helpers={}
 for name,file in [('source','track-source-oracle.c'),('oracle','matroska-timing-oracle.c'),('chain','chain-oracle.c'),('guard','speex-flv-oracle.c'),('sparse','flv-clock-sparse-oracle.c')]:
  helpers[name]=out/('flv-clock-'+name+ext);compile_c(helpers[name],[ROOT/'tests'/file],objects=objects,libraries=libraries)
 def source(path):
  target=work/'source.f32';run([helpers['source'],path,0,target]);return target.read_bytes()
 if args.fixtures:
  origin=args.fixtures.resolve();manifest=json.loads((origin/'fixtures.json').read_text(encoding='utf-8'))
  if origin!=work:
   for name in manifest['files']:shutil.copyfile(origin/name,work/name)
 else:
  manifest={'files':[],'cases':[],'sparse':[],'lifecycle':[]};f=module('flv_helpers',ROOT/'tests/verify-flv.py');bases=[]
  def save(name,data):(work/name).write_bytes(data);manifest['files'].append(name)
  for rate,ch in [(8000,1),(16000,2),(32000,1),(44100,2),(48000,1),(96000,2)]:
   name=f'aac-{rate}-{ch}';path=work/(name+'-encoded.flv');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=0.65','-ac',ch,'-c:a','aac',path]);audio=[data for kind,data in tags(path.read_bytes()) if kind==8];config=next(x for x in audio if x[1]==0);bases.append((name,rate,ch,[x for x in audio if x[1]==1],config))
  he=module('he_fixture_helpers',ROOT/'tests/verify-heaac.py');fixtures=he.Fixtures(work)
  for ps in [False,True]:
   channels=1 if ps else 2;adts,_=fixtures.stream('he-'+str(ps)+'.aac',channels,24000,347 if ps else 139,frames=18,steady=True,ps=ps);packets=[b'\xaf\1'+x for x in he.sbr_vectors.raw_blocks(adts.read_bytes())]
   configs={'implicit':[(2,5),(6,4),(channels,4),(0,3)],'explicit':[(29 if ps else 5,5),(6,4),(channels,4),(3,4),(2,5),(0,3)],'sync':[(2,5),(6,4),(channels,4),(0,3),(0x2b7,11),(5,5),(1,1),(3,4)]+([(0x548,11),(1,1)] if ps else [])}
   for kind,fields in configs.items():bases.append(('aac-'+('ps' if ps else 'sbr')+'-'+kind,48000,2,packets,b'\xaf\0'+he.sbr_vectors.config_bits(fields)))
  for group in [1,5,8]:
   name=f'speex-group{group}';path=work/(name+'-encoded.flv');run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=337:sample_rate=16000:duration=0.83','-c:a','libspeex','-frames_per_packet',group,path]);bases.append((name,16000,1,[d for k,d in tags(path.read_bytes()) if k==8],None))
  rng=random.Random(96537)
  for bits in [2,3,4,5]:
   for ch in [1,2]:
    rate=[11025,22050,44100][(bits+ch)%3];flags=0x10|{11025:1,22050:2,44100:3}[rate]<<2|2|(ch-1);ps=[bytes([flags])+f.swf_packet(rng,ch,bits,shape) for shape in [[4096],[311],[4096,127],[33],[4096],[501],[4096],[81]]];bases.append((f'adpcm-{bits}-{ch}',rate,ch,ps,None))
  for label,rate,ch,packets,config in bases:
   path=work/'neutral.flv';path.write_bytes(mux(packets,[0]*len(packets),config));pcm=source(path);lengths=[];before=0
   for n in range(1,len(packets)+1):path.write_bytes(mux(packets[:n],[0]*n,config));after=len(source(path))//8;lengths.append(after-before);before=after
   assert sum(lengths)*8==len(pcm);starts=[];raw=0
   for n in lengths:starts.append(raw);raw+=n
   suffixes={}
   for pattern in ['continuous','leading','internal','overlap','negative','reorder','foreign','negative-limit']:
    shift=-20 if pattern=='negative' else 25 if pattern=='leading' else -0x80000000 if pattern=='negative-limit' else 0;offset=nearest(shift*rate,1000);mapping=[];times=[]
    for i,(start,n) in enumerate(zip(starts,lengths)):
     ms=nearest(start*1000,rate)+shift
     if i==len(packets)//2 and pattern in ['internal','overlap','reorder']:
      shift+=40 if pattern=='internal' else -20 if pattern=='overlap' else -300;ms=nearest(start*1000,rate)+shift;offset=nearest(ms*rate,1000)-start
     times.append(ms)
     for at in range(start,start+n):
      dest=at+offset
      if dest<0 or dest<len(mapping):continue
      mapping.extend([None]*(dest-len(mapping)));mapping.append(at)
    name=label+'-'+pattern+'.flv';ref=name+'.f32';save(name,mux(packets,times,config,pattern=='foreign',23 if pattern=='foreign' else 0));save(ref,b''.join(bytes(8) if at is None else pcm[at*8:at*8+8] for at in mapping));reset=None
    if label.startswith('aac'):
     frames=len(mapping);blob=bytearray()
     for request in [0,1,2,17,119,120,511,512,4095,4096,frames//3,frames//2+1,max(0,frames-1),frames,frames+1,(1<<64)-1]:
      target=min(request,frames);goal=next((x for x in mapping[target:] if x is not None),raw);primers=2 if label.startswith(('aac-sbr','aac-ps')) else 1;chosen=max(0,bisect_right(starts,goal)-1-primers)
      if chosen not in suffixes:path.write_bytes(mux(packets[chosen:],[0]*(len(packets)-chosen),config));suffixes[chosen]=source(path)
      decoded=suffixes[chosen];origin=starts[chosen];tail=b''.join(bytes(8) if at is None else decoded[(at-origin)*8:(at-origin+1)*8] for at in mapping[target:]);assert len(tail)==(frames-target)*8;blob+=struct.pack('<QI',target,len(tail))+tail
     reset=name+'.seek-reference';save(reset,blob)
    manifest['cases'].append({'file':name,'reference':ref,'rate':rate,'channels':ch,'frames':len(mapping),'pattern':pattern,'seek_reference':reset})
   if label=='speex-group1':
    for ms in [0x1000001,0x7fffffff]:
     name=f'extended-{ms}.flv';ref=name+'.f32';save(name,mux(packets[:1],[ms]));path.write_bytes(mux(packets[:1],[0]));save(ref,source(path));manifest['sparse'].append({'file':name,'reference':ref,'gap_frames':ms*16})
  for label,encoder,rate,opts in [('aac','aac',48000,[]),('speex','libspeex',16000,['-frames_per_packet','5']),('adpcm','adpcm_swf',44100,[])]:
   path=work/(label+'-lifecycle-encoded.flv');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'sine=frequency=337:sample_rate={rate}:duration=12','-c:a',encoder,*opts,path]);data=path.read_bytes();at=int.from_bytes(data[5:9],'big')+4;parts=[data[:at]]
   while at+11<=len(data):
    n=int.from_bytes(data[at+1:at+4],'big');ms=int.from_bytes(data[at+4:at+7],'big')|(data[at+7]<<24);parts.append(tag(data[at],data[at+11:at+11+n],ms+100+(500 if ms>=4700 else 0)));at+=15+n
   name=label+'-lifecycle.flv';save(name,b''.join(parts));manifest['lifecycle'].append(name)
 (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8');checks=[]
 for case in manifest['cases']:
  path=work/case['file'];ref=work/case['reference'];reset=[work/case['seek_reference']] if case.get('seek_reference') else [];detail=json.loads(run([helpers['oracle'],path,ref,0,case['rate'],case['channels'],*reset]).strip().splitlines()[-1]);target=work/'cli.f32';target.unlink(missing_ok=True);run([cli,'--decode',path,target]);assert target.read_bytes()==ref.read_bytes();checks.append({**case,'oracle':detail,'result':'exact independent media placement'});print(case['file']+': exact PCM and seeks',flush=True)
 bounds=[]
 for name in ['aac-44100-2-internal.flv','speex-group5-leading.flv','adpcm-5-2-overlap.flv']:
  c=next(x for x in manifest['cases'] if x['file']==name);bounds.append({'file':name,**json.loads(run([helpers['guard'],work/name,work/c['reference'],1,c['rate'],c['channels']]).strip().splitlines()[-1])})
 sparse=[{**c,**json.loads(run([helpers['sparse'],work/c['file'],work/c['reference'],c['gap_frames']]).strip().splitlines()[-1])} for c in manifest['sparse']];cancellation=[{'mode':mode,**json.loads(run([helpers['chain'],mode,work/manifest['lifecycle'][1]]).strip().splitlines()[-1])} for mode in ['cancel-open','cancel-read']];lifecycle=[]
 if args.probe:
  if not WINDOWS:raise RuntimeError('Native Windows required')
  probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  for name in manifest['lifecycle']:detail=run([probe,work/name],75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'file':name,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 paths=['src/flv.s','src/track.s','src/track_time.s','src/decoder.s','tests/verify-flv-clock.py','tests/verify-flv.py','tests/verify-heaac.py','tests/sbr_vectors.py','tests/sbr_model.py','tests/ps_model.py','tests/flv-clock-sparse-oracle.c','tests/speex-flv-oracle.c','tests/matroska-timing-oracle.c','tests/track-source-oracle.c','tests/chain-oracle.c'];report={'result':'passed','platform':platform.platform(),'scope':'AAC-LC, HE-AAC v1/v2 (implicit/explicit/sync), Flash ADPCM and Speex signed 32-bit millisecond tag clocks. Independent per-sample media placement and AAC packet-suffix seek references; codec DSP has separate suites. Guarded mutations stop at 128 reads and seek at64. PCM/G.711/MPEG gathered paths, video synchronization, native Mac and Linux device playback remain unestablished.','checks':checks,'guarded':bounds,'sparse':sparse,'cancellation':cancellation,'native_lifecycle':lifecycle,'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},'binaries':{x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cli,*helpers.values()]}}
 (out/'flv-clock-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files and',len(checks)*16,'media seeks.')
if __name__=='__main__':main()
