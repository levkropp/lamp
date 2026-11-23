#!/usr/bin/env python3
"""PCM/G.711/MPEG tag clocks, byte fragmentation, source PCM and seeks."""
import argparse,hashlib,importlib.util,json,platform,random,shutil,struct,subprocess,sys
from bisect import bisect_right
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def run(args,timeout=180):
 p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if p.returncode:raise RuntimeError(f'{args[0]} ({p.returncode}): {p.stdout[-1000:]} {p.stderr[-2000:]}')
 return p.stdout
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def nearest(n,d):return (n+d//2)//d if n>=0 else -((-n+d//2)//d)
def tag(kind,data,ms):return bytes([kind])+len(data).to_bytes(3,'big')+(ms&0xffffff).to_bytes(3,'big')+bytes([ms>>24&255])+bytes(3)+data+(11+len(data)).to_bytes(4,'big')
def flv(parts,extra=0):return b'FLV\1\4'+(9+extra).to_bytes(4,'big')+bytes(extra)+bytes(4)+b''.join(tag(*p) for p in parts)
def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/flv-gathered-check' if WINDOWS else 'build/flv-gathered-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true');args=p.parse_args();out=args.bin.resolve();work=out/'flv-gathered';work.mkdir(parents=True,exist_ok=True);ext='.exe' if WINDOWS else '';cli=out/('lamp-cli'+ext)
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'];helpers={}
 for name,file in [('source','track-source-oracle.c'),('oracle','matroska-timing-oracle.c'),('guard','speex-flv-oracle.c'),('chain','chain-oracle.c'),('sparse','flv-clock-sparse-oracle.c')]:
  helpers[name]=out/('flv-gathered-'+name+ext);compile_c(helpers[name],[ROOT/'tests'/file],objects=objects,libraries=libraries)
 def source(data):
  path=work/'untimed.flv';path.write_bytes(data);target=work/'source.f32';run([helpers['source'],path,0,target]);return target.read_bytes()
 def decode(path):
  target=work/'decode.f32';target.unlink(missing_ok=True);run([cli,'--decode',path,target]);return target.read_bytes()
 if args.fixtures:
  origin=args.fixtures.resolve();manifest=json.loads((origin/'fixtures.json').read_text(encoding='utf-8'))
  if origin!=work:
   for name in manifest['files']:shutil.copyfile(origin/name,work/name)
 else:
  f=load('flv_fixture_helpers',ROOT/'tests/verify-flv.py');manifest={'files':[],'cases':[],'sparse':[],'lifecycle':[]};bases=[]
  def save(name,data):(work/name).write_bytes(data);manifest['files'].append(name)
  for rate in [11025,22050,44100]:
   for bits in [8,16]:
    for ch in [1,2]:
     raw=bytearray();pcm=bytearray()
     for i in range(1701):
      values=[(i*91+47*c)%251 for c in range(ch)] if bits==8 else [(i*157+71*c)%60001-30000 for c in range(ch)]
      for value in values:raw+=bytes([value]) if bits==8 else struct.pack('<h',value)
      pcm+=struct.pack('<ff',*(([(values[0]-128)/128,(values[-1]-128)/128]) if bits==8 else [values[0]/32768,values[-1]/32768]))
     flags=0x30|{11025:1,22050:2,44100:3}[rate]<<2|(2 if bits==16 else 0)|(ch-1);align=ch*(bits//8);units=[(i*align,i,1,align) for i in range(1701)];bases.append((f'pcm-{rate}-{bits}-{ch}',rate,ch,flags,bytes(raw),units,bytes(pcm)))
  for kind in [7,8]:
   for ch in [1,2]:
    raw=bytes((i*37+19)%256 for i in range(1701*ch));flags=kind<<4|ch-1;pcm=source(flv([(8,bytes([flags])+raw,0)]));bases.append((f'g711-{kind}-{ch}',8000,ch,flags,raw,[(i*ch,i,1,ch) for i in range(1701)],pcm))
  for rate,ch,vbr in [(8000,1,False),(22050,2,False),(44100,1,False),(44100,2,False),(48000,2,True)]:
   name=f'mpeg-{rate}-{ch}-'+('vbr' if vbr else 'cbr');path=work/(name+'.mp3');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=0.65','-ac',ch,'-c:a','libmp3lame',*(['-q:a','3'] if vbr else ['-b:a','32k' if rate==8000 else '96k']),'-write_xing','0','-id3v2_version','0',path]);raw=path.read_bytes();frames=list(f.mpeg_frames(raw));units=[(at,sample,384 if raw[at+1]>>1&3==3 else 576 if (raw[at+1]>>3&3)!=3 else 1152,size) for at,sample,_,size in frames];pcm=decode(path);assert sum(x[2] for x in units)*8==len(pcm);bases.append((name,rate,ch,0xe2 if rate==8000 else 0x2f,raw,units,pcm))
  for label,rate,ch,flags,raw,units,pcm in bases:
   frame_starts=[x[0] for x in units]
   for pattern in ['continuous','fragmented','leading','internal','overlap','negative','foreign','reorder']:
    if pattern=='continuous':lengths=[x[3] for x in units] if label.startswith('mpeg') else [len(raw)]
    else:
     lengths=[];remaining=len(raw);rng=random.Random(193+len(label))
     while remaining:n=min(remaining,rng.choice([1,2,3,17,31,157,509,1021]));lengths.append(n);remaining-=n
    starts=[];at=0
    for n in lengths:starts.append(at);at+=n
    parts=[];stamps=[];shifts=[]
    for i,(start,n) in enumerate(zip(starts,lengths)):
     shift=25 if pattern=='leading' else -20 if pattern=='negative' else (40 if pattern=='internal' else -20 if pattern=='overlap' else -300 if pattern=='reorder' else 0) if i>=len(starts)//2 else 0
     owner=max(0,bisect_right(frame_starts,start)-1);ms=nearest(units[owner][1]*1000,rate)+shift;stamps.append(ms);shifts.append(shift)
     if pattern=='foreign' and i:parts.extend([(18,b'script',0x7fffffff),(9,b'video',-0x80000000),(0x28,bytes([flags])+raw[start:start+n],0x12345678),(8,b'\x62foreign',-0x70000000)])
     parts.append((8,bytes([flags])+raw[start:start+n],ms))
    mapping=[];previous_shift=0;offset=0;last_owner=-1
    for unit_at,sample,count,size in units:
     owner=max(0,bisect_right(starts,unit_at)-1)
     if owner!=last_owner and shifts[owner]!=previous_shift:
      covering=max(0,bisect_right(frame_starts,starts[owner])-1);ns=stamps[owner]*1000000
      if unit_at>starts[owner]:ns+=nearest(units[covering][2]*1000000000,rate)
      offset=nearest(ns*rate,1000000000)-sample;previous_shift=shifts[owner]
     last_owner=owner
     for src in range(sample,sample+count):
      dest=src+offset
      if dest<0 or dest<len(mapping):continue
      mapping.extend([None]*(dest-len(mapping)));mapping.append(src)
    name=label+'-'+pattern+'.flv';ref=name+'.f32';save(name,flv(parts,23 if pattern=='foreign' else 0));save(ref,b''.join(bytes(8) if s is None else pcm[s*8:s*8+8] for s in mapping));manifest['cases'].append({'file':name,'reference':ref,'rate':rate,'channels':ch,'frames':len(mapping),'pattern':pattern,'units':len(units),'tags':len(lengths)})
   if label in ['pcm-44100-16-2','g711-7-2','mpeg-8000-1-cbr']:
    first=units[0][3];piece=raw[:first];expected=pcm[:units[0][2]*8];ms=0x7fffffff;name=label+'-maximum-clock.flv';ref=name+'.f32';save(name,flv([(8,bytes([flags])+piece,ms)]));save(ref,expected);manifest['sparse'].append({'file':name,'reference':ref,'gap_frames':nearest(ms*rate,1000)})
    # A clock at SI32_MAX plus a complete continuation frame must remain
    # positive; the adjusted nanoseconds are wider than signed milliseconds.
    name=label+'-maximum-continuation.flv';ref=name+'.f32';piece=raw[:first+units[1][3]];save(name,flv([(8,bytes([flags])+piece[:1],0),(8,bytes([flags])+piece[1:],ms)]));save(ref,pcm[:(units[0][2]+units[1][2])*8]);manifest['sparse'].append({'file':name,'reference':ref,'gap_frames':nearest(ms*rate,1000),'prefix_frames':units[0][2]})
  for base in ['pcm-11025-8-1-fragmented.flv','pcm-44100-16-2-internal.flv']:
   data=bytearray((work/base).read_bytes());at=int.from_bytes(data[5:9],'big')+4
   while at+11<=len(data):
    n=int.from_bytes(data[at+1:at+4],'big')
    if data[at]==8 and n:data[at+11]&=15
    at+=15+n
   original=next(c for c in manifest['cases'] if c['file']==base);name='platform-'+base;ref=name+'.f32';save(name,data);save(ref,(work/original['reference']).read_bytes());manifest['cases'].append({**original,'file':name,'reference':ref,'pattern':'format0 little-endian'})
  # A tag larger than the shared PCM packet buffer creates several views,
  # with one clock anchor and continuous samples across the view boundary.
  n=262181;pair=struct.pack('<hh',1234,-4321);file='large-pcm-tag.flv';ref=file+'.f32';save(file,flv([(8,b'\x3f'+pair*n,25)]));save(ref,bytes(1103*8)+struct.pack('<ff',1234/32768,-4321/32768)*n);manifest['cases'].append({'file':file,'reference':ref,'rate':44100,'channels':2,'frames':n+1103,'pattern':'multi-view tag'})
  # Empty and sub-frame PCM still have a valid format and seekable EOF.
  for name,flags,payload,rate,ch in [('empty-pcm',0x3f,b'',44100,2),('partial-pcm',0x3f,b'\1\2\3',44100,2),('empty-g711',0x71,b'',8000,2)]:
   file=name+'.flv';ref=file+'.f32';save(file,flv([(8,bytes([flags])+payload,0)]));save(ref,b'');manifest['cases'].append({'file':file,'reference':ref,'rate':rate,'channels':ch,'frames':0,'pattern':'empty presentation'})
  # Encoder metadata stays in the native MPEG byte stream, including ID3 and
  # Xing/LAME trimming; container timing must not alter the source waveform.
  path=work/'metadata.mp3';run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=337:sample_rate=44100:duration=0.65','-c:a','libmp3lame','-metadata','title=timestamp metadata','-write_xing','1',path]);pcm=decode(path);name='mpeg-metadata.flv';ref=name+'.f32';save(name,flv([(8,b'\x2e'+path.read_bytes(),0)]));save(ref,pcm);manifest['cases'].append({'file':name,'reference':ref,'rate':44100,'channels':1,'frames':len(pcm)//8,'pattern':'native metadata/trims'})
  # Metadata-only tail tags can carry unrelated clocks without adding PCM.
  raw=path.read_bytes()
  for kind,tail in [('id3v1',b'TAG'+bytes(125)),('ape',b'APETAGEX'+struct.pack('<4I',2000,32,0,0)+bytes(8))]:
   file='mpeg-metadata-'+kind+'.flv';ref=file+'.f32';save(file,flv([(8,b'\x2e'+raw,0),(8,b'\x2e'+tail,0x7fffffff)]));save(ref,pcm);manifest['cases'].append({'file':file,'reference':ref,'rate':44100,'channels':1,'frames':len(pcm)//8,'pattern':'metadata-only tail clock ignored'})
  for name,encoder,rate,ch,flags in [('pcm','pcm_s16le',44100,2,0x3f),('g711','pcm_alaw',8000,1,0x70),('mpeg','libmp3lame',44100,2,0x2f)]:
   path=work/(name+'-lifecycle-encoded.flv');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'sine=frequency=337:sample_rate={rate}:duration=12','-ac',ch,'-c:a',encoder,path]);data=path.read_bytes();at=int.from_bytes(data[5:9],'big')+4;parts=[]
   while at+11<=len(data):
    n=int.from_bytes(data[at+1:at+4],'big');ms=int.from_bytes(data[at+4:at+7],'big')|data[at+7]<<24;parts.append((data[at],data[at+11:at+11+n],ms+100+(500 if ms>=4700 else 0)));at+=15+n
   file=name+'-lifecycle.flv';save(file,flv(parts));manifest['lifecycle'].append(file)
 (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8');checks=[]
 for c in manifest['cases']:
  detail=json.loads(run([helpers['oracle'],work/c['file'],work/c['reference'],0,c['rate'],c['channels']]).strip().splitlines()[-1]);assert decode(work/c['file'])==(work/c['reference']).read_bytes();checks.append({**c,'result':'exact media PCM and seeks','oracle':detail});print(c['file']+': exact PCM and seeks',flush=True)
 guarded=[]
 for file in ['pcm-44100-16-2-internal.flv','g711-7-2-overlap.flv','mpeg-44100-2-cbr-fragmented.flv']:
  c=next(c for c in manifest['cases'] if c['file']==file);guarded.append({'file':file,**json.loads(run([helpers['guard'],work/file,work/c['reference'],1,c['rate'],c['channels']]).strip().splitlines()[-1])})
 sparse=[{**c,**json.loads(run([helpers['sparse'],work/c['file'],work/c['reference'],c['gap_frames'],*([c['prefix_frames']] if c.get('prefix_frames') else [])]).strip().splitlines()[-1])} for c in manifest['sparse']];lifecycle=[]
 if args.probe:
  if not WINDOWS:raise RuntimeError('Native Windows required')
  probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  for file in manifest['lifecycle']:detail=run([probe,work/file],75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'file':file,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 cancellation=[{'file':file,'mode':mode,**json.loads(run([helpers['chain'],mode,work/file]).strip().splitlines()[-1])} for file in manifest['lifecycle'] for mode in ['cancel-open','cancel-read']]
 paths=['src/flv.s','src/track.s','src/track_time.s','src/mp3.s','src/decoder.s','tests/verify-flv-gathered.py','tests/verify-flv.py','tests/matroska-timing-oracle.c','tests/speex-flv-oracle.c','tests/flv-clock-sparse-oracle.c','tests/track-source-oracle.c','tests/chain-oracle.c'];report={'result':'passed','platform':platform.platform(),'scope':'PCM/G.711/MPEG FLV timestamps and arbitrary byte fragmentation; independent sample placement with source codec PCM established separately. Continuation tags advance the next newly owned frame clock; empty PCM, native MPEG metadata/trims, sparse maximum timestamps and cancellation. Mutated reads capped at128 with midpoint seek64. No video/A-V sync or native Mac/Linux device coverage.','checks':checks,'guarded':guarded,'sparse':sparse,'cancellation':cancellation,'native_lifecycle':lifecycle,'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},'binaries':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [cli,*helpers.values()]}}
 (out/'flv-gathered-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files and',len(checks)*16,'media seeks.')
if __name__=='__main__':main()
