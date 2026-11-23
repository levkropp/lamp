#!/usr/bin/env python3
"""ASF PCM/G.711/ADPCM/MPEG/AC-3/ADTS clocks and arbitrary object boundaries."""
import argparse,hashlib,importlib.util,json,platform,random,shutil,struct,sys
from bisect import bisect_right
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
import asf_clock_model as model
def module(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/'tests'/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
w=module('asf_gathered_writer','verify-asf.py');f=module('asf_gathered_helpers','verify-flv-gathered.py');run=f.run;nearest=model.nearest

def wave(fmt,data):
 body=b'fmt '+struct.pack('<I',len(fmt))+fmt+bytes(len(fmt)%2)+b'data'+struct.pack('<I',len(data))+data+bytes(len(data)%2)
 return b'RIFF'+struct.pack('<I',len(body)+4)+b'WAVE'+body

def mux(fmt,parts,times,*,preroll=3100,offset100=0,fragmented=False,compressed=False,foreign=False,spread=None):
 packets=[];i=0
 while i<len(parts):
  if compressed:
   count=min(3,len(parts)-i);delta=times[i+1]-times[i] if count>1 else 0
   if not 0<=delta<=255 or count==3 and times[i+2]!=times[i]+2*delta:count=1;delta=0
   body=b''.join(bytes([len(x)])+x for x in parts[i:i+count]);packets.append(w.packet([w.payload(body,i&255,times[i],replic=1,delta=delta)],physical=8192));i+=count;continue
  data=parts[i];off=0
  if spread:
   span,packet,chunk=spread;assert len(data)==span*packet
   data=b''.join(data[(row*span+col)*chunk:(row*span+col+1)*chunk] for col in range(span) for row in range(packet//chunk))
  pieces=[data[:1],data[1:17]]+[data[k:k+4000] for k in range(17,len(data),4000)] if fragmented else [data]
  for n,piece in enumerate(pieces):
   if not piece:continue
   items=[w.payload(piece,i&255,off,len(data),replic=0 if n==1 else 12 if foreign else 8,time=times[i])]
   if foreign:items.insert(0,w.payload(b'ignored',i&255,stream=2,time=0xffffffff))
   packets.append(w.packet(items,physical=max(8192,len(piece)+128),multi=foreign or i%2==0,ecc=i%3!=0));off+=len(piece)
  i+=1
 streams=[w.stream(fmt,time_offset=offset100)]
 if spread:
  record=struct.pack('<BHHHB',*spread,1,0);body=w.AUDIO+w.guid('bfc3cd50-618f-11cf-8bb2-00aa00b4e220')+struct.pack('<QIIHI',offset100,len(fmt),len(record),1,0)+fmt+record;streams=[w.obj(w.STREAM,body)]
 if foreign:streams.append(w.stream(struct.pack('<HHIIHH',0x161,1,8000,8000,1,8),ident=2,time_offset=(1<<64)-1))
 return w.asf(streams,packets,minimum=min(map(len,packets)),maximum=max(map(len,packets)),preroll=preroll)

def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/asf-gathered-check' if WINDOWS else 'build/asf-gathered-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true');args=p.parse_args();out=args.bin.resolve();work=out/'asf-gathered';work.mkdir(parents=True,exist_ok=True);ext='.exe' if WINDOWS else '';cli=out/('lamp-cli'+ext)
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'];helpers={}
 for name,file in [('oracle','matroska-timing-oracle.c'),('source','track-source-oracle.c'),('chain','chain-oracle.c'),('guard','asf-gathered-oracle.c'),('sparse','flv-clock-sparse-oracle.c'),('reopen','asf-gathered-reopen-oracle.c')]:
  helpers[name]=out/('asf-gathered-'+name+ext);compile_c(helpers[name],[ROOT/'tests'/file],objects=objects,libraries=libraries)
 def decode(path):
  target=work/'decoded.f32';target.unlink(missing_ok=True);run([cli,'--decode',path,target]);return target.read_bytes()
 if args.fixtures:
  origin=args.fixtures.resolve();manifest=json.loads((origin/'fixtures.json').read_text(encoding='utf-8'))
  if origin!=work:
   for name in manifest['files']:shutil.copyfile(origin/name,work/name)
 else:
  manifest={'files':[],'cases':[],'sparse':[],'rejects':[],'lifecycle':[]};bases=[]
  def save(name,data):(work/name).write_bytes(data);manifest['files'].append(name)
  codecs=[('pcm_u8',1,11025),('pcm_s16le',2,44100),('pcm_s24le',6,48000),('pcm_s32le',8,96000),('pcm_f32le',2,32000),('pcm_f64le',1,48000),('pcm_alaw',1,8000),('pcm_mulaw',2,8000),('adpcm_ima_wav',1,22050),('adpcm_ima_wav',2,48000),('adpcm_ms',1,44100),('adpcm_ms',2,48000),('mp2',2,48000),('libmp3lame',1,8000),('libmp3lame',2,22050),('libmp3lame',2,44100),('ac3',2,48000)]
  for codec,ch,rate in codecs:
   name=f'{codec}-{rate}-{ch}';path=work/(name+'.wav');opts=['-b:a','32k' if rate==8000 else '128k'] if codec in ['mp2','libmp3lame','ac3'] else []
   run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=0.28','-ac',ch,'-c:a',codec,*opts,path]);w.untrimmed_wave(path);fmt,raw=w.wave_parts(path.read_bytes());bases.append((name,fmt,raw,rate,ch,path,codec in ['mp2','libmp3lame','ac3']))
  import adpcm_model,duck_adpcm_model
  rng=random.Random(465179)
  for bits in [2,3,5]:
   ch=2;align=4*ch+{2:4,3:12,5:20}[bits]*ch*11;raw=adpcm_model.random_ima(rng,ch,align,9,4*ch+{2:4,3:12,5:20}[bits]*ch*3);path=work/f'ima-{bits}.wav';path.write_bytes(adpcm_model.wave(0x11,ch,48000,align,raw,bits=bits));fmt,_=w.wave_parts(path.read_bytes());bases.append((f'ima-{bits}',fmt,raw,48000,ch,path,False))
  for kind,ch in [(0x61,1),(0x61,2),(0x62,2)]:
   raw=duck_adpcm_model.random_blocks(rng,kind,ch,256,9,39 if kind==0x62 else 4*ch+7);path=work/f'duck-{kind}-{ch}.wav';path.write_bytes(duck_adpcm_model.wave(kind,ch,48000,256,raw));fmt,_=w.wave_parts(path.read_bytes());bases.append((f'duck-{kind}-{ch}',fmt,raw,48000,ch,path,False))
  # Native WAVE precision, unusual speaker masks and direct-out routing must
  # survive packetization without the ordinary PCM opener resetting them.
  for bits,valid,ch,mask in [(24,20,2,3),(32,24,6,0x60f),(32,32,8,0)]:
   align=bits//8*ch;raw=b''.join((int(0.12*(1<<(valid-1))*((i*37)%193-96)/96)<<(bits-valid)).to_bytes(bits//8,'little',signed=True) for i in range(1357*ch));fmt=struct.pack('<HHIIHHHHI',0xfffe,ch,48000,48000*align,align,bits,22,valid,mask)+bytes.fromhex('0100000000001000800000aa00389b71');name=f'precision-{bits}-{valid}-{ch}-{mask}';path=work/(name+'.wav');path.write_bytes(wave(fmt,raw));bases.append((name,fmt,raw,48000,ch,path,False))
  path=work/'adts-lc.aac';run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=337:sample_rate=44100:duration=0.33','-ac','2','-c:a','aac','-aac_pns','0',path]);fmt=struct.pack('<HHIIHHH',0xff,2,44100,16000,1,0,0);bases.append(('adts-lc',fmt,path.read_bytes(),44100,2,path,True))
  he=module('asf_gathered_he','verify-heaac.py');fixtures=he.Fixtures(work)
  for ps in [False,True]:
   path,_=fixtures.stream('adts-he-'+str(ps)+'.aac',1 if ps else 2,24000,347 if ps else 139,frames=12,steady=True,ps=ps);fmt=struct.pack('<HHIIHHH',0xff,2,48000,16000,1,0,0);bases.append(('adts-ps' if ps else 'adts-sbr',fmt,path.read_bytes(),48000,2,path,True))
  for label,fmt,raw,rate,ch,source_path,reset_seeks in bases:
   pcm=decode(source_path);units=model.units(fmt,raw);assert sum(x[2] for x in units)*8==len(pcm),(label,'independent frame count');suffixes={}
   print('Prepared source '+label,flush=True)
   geometry=next(((span,len(raw)//2//span,1) for span in range(2,256) if len(raw)%2==0 and len(raw)//2%span==0 and len(raw)//2//span<=65535),None)
   for pattern in ['continuous','rebuilt','fragmented','leading','internal','overlap','negative','foreign','offset','all-negative','compressed','cancel-large']+(['spread-gap'] if geometry else []):
    lengths=[]
    if pattern=='spread-gap':lengths=[len(raw)//2]*2
    elif pattern in ['continuous','rebuilt']:
     if model.tag(fmt) in [1,3,6,7]:lengths=[min(4096,len(raw)-i) for i in range(0,len(raw),4096)]
     else:lengths=[x[3] for x in units]
    elif pattern=='compressed':
     align=struct.unpack_from('<H',fmt,12)[0];stride=min(240,align*max(1,rate//1000)) if model.tag(fmt) in [1,3,6,7] else 197;lengths=[min(stride,len(raw)-i) for i in range(0,len(raw),stride)]
    else:
     left=len(raw);r=random.Random(883+len(label))
     while left:n=min(left,r.choice([1,2,3,17,31,127,509,1021]));lengths.append(n);left-=n
    starts=[];at=0
    for n in lengths:starts.append(at);at+=n
    parts=[raw[start:start+n] for start,n in zip(starts,lengths)];times=model.object_times(units,starts,rate);preroll=3100;offset100=250061 if pattern=='offset' else 0
    if pattern=='cancel-large':preroll=(1<<64)//10000-1;offset100=preroll*10000
    for i in range(len(times)):
     shift=25 if pattern=='leading' else -20 if pattern=='negative' else (40 if pattern in ['internal','spread-gap'] else -20 if pattern=='overlap' else 0) if i>=len(times)//2 else 0;times[i]+=(0 if pattern=='cancel-large' else preroll)+shift
    if pattern=='all-negative':preroll=0xffffffff;times=[0]*len(times)
    mapping=model.placement(units,starts,times,rate,preroll,offset100);name=label+'-'+pattern+'.asf';ref=name+'.f32';save(name,mux(fmt,parts,times,preroll=preroll,offset100=offset100,fragmented=pattern in ['rebuilt','fragmented','spread-gap'],compressed=pattern=='compressed',foreign=pattern=='foreign',spread=geometry if pattern=='spread-gap' else None));save(ref,b''.join(bytes(8) if x is None else pcm[x*8:x*8+8] for x in mapping));frames=len(mapping);seek_ref=None
    if reset_seeks:
     blob=bytearray()
     for request in [0,1,2,17,119,120,511,512,4095,4096,frames//3,frames//2+1,max(0,frames-1),frames,frames+1,(1<<64)-1]:
      target=min(request,frames);goal=next((x for x in mapping[target:] if x is not None),len(pcm)//8)
      if goal not in suffixes:
       dest=work/'native-suffix.f32';run([helpers['oracle'],'--dump',source_path,goal,dest]);suffixes[goal]=dest.read_bytes()
      decoded=suffixes[goal];tail=b''.join(bytes(8) if x is None else decoded[(x-goal)*8:(x-goal+1)*8] for x in mapping[target:]);assert len(tail)==(frames-target)*8;blob+=struct.pack('<QI',target,len(tail))+tail
     seek_ref=name+'.seek-reference';save(seek_ref,blob)
    manifest['cases'].append(dict(file=name,reference=ref,seek_reference=seek_ref,rate=rate,channels=ch,frames=frames,pattern=pattern))
   if label in ['pcm_s16le-44100-2','adpcm_ima_wav-48000-2','libmp3lame-44100-2','adts-lc']:
    first=units[0][3];piece=raw[:first];ref=label+'-maximum.asf.f32';name=label+'-maximum.asf';save(name,mux(fmt,[piece],[0xffffffff],preroll=0));save(ref,pcm[:units[0][2]*8]);manifest['sparse'].append(dict(file=name,reference=ref,gap_frames=nearest(0xffffffff*rate,1000)))
    for kind in ['offset','preroll']:
     opts={'preroll':0,'offset100':(1<<64)-1} if kind=='offset' else {'preroll':(1<<64)-1};name=label+'-'+kind+'-overflow.asf';save(name,mux(fmt,[piece],[0],**opts));manifest['rejects'].append(name)
   if label in ['pcm_s16le-44100-2','adpcm_ima_wav-48000-2','libmp3lame-44100-2','adts-ps']:
    copies=(rate*12+len(pcm)//8-1)//(len(pcm)//8);blob=raw*copies;all_units=model.units(fmt,blob);parts=[blob[x[0]:x[0]+x[3]] for x in all_units] if model.tag(fmt) not in [1,3,6,7] else [blob[i:i+4096] for i in range(0,len(blob),4096)];starts=[];at=0
    for part in parts:starts.append(at);at+=len(part)
    times=model.object_times(all_units,starts,rate);times=[3100+ms+100+(500 if ms>=5000 else 0) for ms in times];name=label+'-lifecycle.asf';save(name,mux(fmt,parts,times));manifest['lifecycle'].append(name)
  fmt=struct.pack('<HHIIHH',1,2,44100,176400,4,16);pair=struct.pack('<hh',1234,-4321);count=262181;name='large-single-object.asf';ref=name+'.f32';save(name,mux(fmt,[pair*count],[3125],fragmented=True));save(ref,bytes(1103*8)+struct.pack('<ff',1234/32768,-4321/32768)*count);manifest['cases'].append(dict(file=name,reference=ref,rate=44100,channels=2,frames=count+1103,pattern='large fragmented single object'))
  for kind in [1,6,7]:
   fmt0=struct.pack('<HHIIHH',kind,2,8000,16000,2,8);name=f'empty-{kind}.asf';ref=name+'.f32';save(name,w.asf([w.stream(fmt0)],[],minimum=512));save(ref,b'');manifest['cases'].append(dict(file=name,reference=ref,rate=8000,channels=2,frames=0,pattern='empty presentation'))
  clock=(1<<63)//100*100;name='near-signed-ns-limit.asf';ref=name+'.f32';save(name,mux(fmt,[pair],[0],preroll=0,offset100=clock//100));save(ref,struct.pack('<ff',1234/32768,-4321/32768));manifest['sparse'].append(dict(file=name,reference=ref,gap_frames=nearest(clock*44100,1000000000)))
  name='continuation-adjustment-overflow.asf';save(name,mux(fmt,[pair[:1],(pair*2)[1:]],[0,0],preroll=0,offset100=clock//100));manifest['rejects'].append(name)
  raw=struct.pack('<hh',1234,-4321)*1357;file='next-caller.flv';ref=file+'.f32';save(file,f.flv([(8,b'\x3f'+raw,0)]));save(ref,struct.pack('<ff',1234/32768,-4321/32768)*1357);manifest['reopen']=['pcm_mulaw-8000-2-internal.asf','pcm_mulaw-8000-2-internal.asf.f32',file,ref]
  manifest['generator_sha256']={str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'tests/asf_clock_model.py',ROOT/'tests/verify-asf.py']};manifest['hashes']={name:hashlib.sha256((work/name).read_bytes()).hexdigest() for name in manifest['files']}
 for name,digest in manifest['generator_sha256'].items():assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
 for name,digest in manifest['hashes'].items():assert hashlib.sha256((work/name).read_bytes()).hexdigest()==digest
 (work/'fixtures.json').write_bytes((json.dumps(manifest,indent=2)+'\n').encode());checks=[]
 for c in manifest['cases']:
  extra=[work/c['seek_reference']] if c.get('seek_reference') else [];detail=json.loads(run([helpers['oracle'],work/c['file'],work/c['reference'],0,c['rate'],c['channels'],*extra]).strip().splitlines()[-1]);assert decode(work/c['file'])==(work/c['reference']).read_bytes();checks.append({**c,'oracle':detail});print(c['file']+': exact PCM and seeks',flush=True)
 guarded=[]
 for label in ['pcm_s16le-44100-2-internal','adpcm_ima_wav-48000-2-fragmented','libmp3lame-44100-2-overlap','adts-ps-internal']:
  c=next(x for x in manifest['cases'] if x['file']==label+'.asf');guarded.append({'file':c['file'],**json.loads(run([helpers['guard'],work/c['file'],work/c['reference'],work/'guarded-mutation.asf',1,c['rate'],c['channels']],300).strip().splitlines()[-1])})
 sparse=[{**c,**json.loads(run([helpers['sparse'],work/c['file'],work/c['reference'],c['gap_frames']]).strip().splitlines()[-1])} for c in manifest['sparse']];rejects=[{'file':name,**json.loads(run([helpers['guard'],'--reject',work/name]).strip().splitlines()[-1])} for name in manifest['rejects']];reopen=json.loads(run([helpers['reopen'],*[work/name for name in manifest['reopen']]]).strip().splitlines()[-1]);cancellation=[{'file':name,'mode':mode,**json.loads(run([helpers['chain'],mode,work/name]).strip().splitlines()[-1])} for name in manifest['lifecycle'] for mode in ['cancel-open','cancel-read']];lifecycle=[]
 if args.probe:
  assert WINDOWS;probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  for name in manifest['lifecycle']:detail=run([probe,work/name],75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'file':name,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 paths=['src/asf.s','src/asf_views.inc','src/asf_spread.inc','src/asf_extended.inc','src/decoder.s','src/track.s','src/track_time.s','src/mp3.s','tests/verify-asf-gathered.py','tests/asf_clock_model.py','tests/asf-gathered-oracle.c','tests/asf-gathered-reopen-oracle.c','tests/verify-asf.py','tests/lamp_test.py','tests/lamp-test.h','tests/verify-flv.py','tests/verify-flv-gathered.py','tests/adpcm_model.py','tests/duck_adpcm_model.py','tests/verify-heaac.py','tests/sbr_vectors.py','tests/sbr_model.py','tests/ps_model.py','tests/matroska-timing-oracle.c','tests/track-source-oracle.c','tests/chain-oracle.c','tests/flv-clock-sparse-oracle.c'];report=dict(result='passed',platform=platform.platform(),scope='Gathered ASF codec presentation; protected direct framing and whole-file second-pass clock/output checks. No video, native Mac or Linux device verification.',checks=checks,guarded=guarded,sparse=sparse,rejected_clocks=rejects,reopen=reopen,cancellation=cancellation,native_lifecycle=lifecycle,fixture_hashes=manifest['hashes'],sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},binaries={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cli,*helpers.values()]})
 (out/'asf-gathered-verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode());print('Passed',len(checks),'files and',len(checks)*16,'media seeks.')
if __name__=='__main__':main()
