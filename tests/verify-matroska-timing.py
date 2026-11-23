#!/usr/bin/env python3
"""Matroska CodecDelay and signed per-block padding against a sample-mask model."""
import argparse,hashlib,importlib.util,json,platform,shutil,struct,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def run(args,timeout=180):
 p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if p.returncode:raise RuntimeError(f'{Path(str(args[0])).name} ({p.returncode}): {p.stdout[-2000:]} {p.stderr[-2000:]}')
 return p.stdout
def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/mkv-timing-check' if WINDOWS else 'build/mkv-timing-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true');p.add_argument('--case',help='debug one filename prefix; writes a separate partial report');args=p.parse_args();out=args.bin.resolve();work=out/'matroska-timing';work.mkdir(parents=True,exist_ok=True);suffix='.exe' if WINDOWS else '';cli=out/('lamp-cli'+suffix);m=module('mkv_helpers',ROOT/'tests/verify-matroska.py')
 def decode(path,output,choice=0):
  output.unlink(missing_ok=True);stats=run([cli,'--decode',*(['--track',choice] if choice else []),path,output]);return output.read_bytes(),stats
 shared={p.stem for p in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[p for p in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
 source_oracle=out/('matroska-timing-source'+suffix);compile_c(source_oracle,[ROOT/'tests/track-source-oracle.c'],objects=objects,libraries=libraries)
 def source_decode(path,output,target=0):
  run([source_oracle,path,target,output]);return output.read_bytes(),''
 if args.fixtures:
  source=args.fixtures.resolve();manifest=json.loads((source/'fixtures.json').read_text(encoding='utf-8'))
  if source!=work:
   for name in manifest['files']:shutil.copyfile(source/name,work/name)
 else:
  manifest={'cases':[],'bad':[],'files':[],'ffmpeg':run(['ffmpeg','-version']).splitlines()[0]}
  def save(name,data): (work/name).write_bytes(data);manifest['files'].append(name)
  def make(t,lengths,*,delay=None,padding=None,lacing=0,unknown=False,extra_entries=b'',foreign=False,bad=None):
   private=m.element(0x63A2,t['private']) if t.get('private') else b'';entry=m.uint(0xD7,1)+m.uint(0x83,2)+m.element(0x86,t['codec'].encode())+private+m.element(0xE1,t['audio'])
   if delay is not None:entry+=m.uint(0x56AA,delay)
   if bad=='duplicate-delay':entry+=m.uint(0x56AA,1)+m.uint(0x56AA,2)
   if bad=='long-delay':entry+=m.element(0x56AA,bytes(9))
   header=m.element(0x1A45DFA3,m.element(0x4282,b'matroska'));tracks=m.element(0x1654AE6B,m.element(0xAE,entry)+extra_entries)
   groups=m.blocks_of(t['frames'],lacing,3);blocks=[];intervals=[];raw=0;packet=0;presented=0
   head=(delay*t['rate']+500000000)//1000000000 if delay is not None else int.from_bytes(t['private'][10:12],'little') if t['codec']=='A_OPUS' else 0
   for i,group in enumerate(groups):
    n=sum(lengths[packet:packet+len(group)]);packet+=len(group);amount=0
    if padding=='mixed' and n:amount=(1 if i%2 else -1)*min(n,[1,17,n,n//2][i%4])
    elif padding=='negative' and i==0:amount=-min(n,17)
    elif padding=='positive' and i==len(groups)//2:amount=min(n,17)
    elif padding=='excess':amount=n+1
    ns=(abs(amount)*1000000000+t['rate']//2)//t['rate'];ns=-ns if amount<0 else ns
    block=m.size_bytes(1)+b'\0\0'+bytes([0x80|((lacing<<1) if len(group)>1 else 0)])+(m.lace(group,lacing) if len(group)>1 else group[0]);body=m.element(0xA1,block)
    if amount:body+=m.sint(0x75A2,ns)
    if bad=='long-padding' and i==0:body+=m.element(0x75A2,bytes(9))
    if bad=='duplicate-padding' and i==0:body+=m.sint(0x75A2,1)+m.sint(0x75A2,2)
    if bad=='duplicate-block' and i==0:body+=m.element(0xA1,block)
    if bad=='missing-block' and i==0:body=m.sint(0x75A2,1)
    first=max(raw+max(-amount,0),head);end=raw+n-max(amount,0)
    coded=presented+head-(first-raw) if first<end else raw
    pts=(abs(coded)*1000000000+t['rate']//2)//t['rate'];pts=-pts if coded<0 else pts
    ticks=(abs(pts)+500)//1000;ticks=-ticks if pts<0 else ticks
    cluster=max(0,ticks);relative=ticks-cluster
    # Replace the placeholder Block time, then wrap each group in a Clock.
    block=m.size_bytes(1)+struct.pack('>h',relative)+bytes([0x80|((lacing<<1) if len(group)>1 else 0)])+(m.lace(group,lacing) if len(group)>1 else group[0])
    original=m.element(0xA1,m.size_bytes(1)+b'\0\0'+bytes([0x80|((lacing<<1) if len(group)>1 else 0)])+(m.lace(group,lacing) if len(group)>1 else group[0]))
    body=body.replace(original,m.element(0xA1,block),1)
    blocks.append(m.element(0x1F43B675,m.uint(0xE7,cluster)+m.element(0xA0,body),unknown))
    if first<end:presented+=end-first
    if amount<0:intervals.append((raw,raw-amount))
    elif amount>0:intervals.append((raw+n-amount,raw+n))
    raw+=n
   if foreign:blocks.insert(0,m.element(0x1F43B675,m.uint(0xE7,0)+m.element(0xA0,m.element(0xA1,m.size_bytes(2)+b'\0\0\x80junk')+m.sint(0x75A2,-(1<<63)))))
   return header+m.element(0x18538067,m.element(0x1549A966,m.uint(0x2AD7B1,1000))+tracks+b''.join(blocks),unknown),intervals
  # All expected trimming is applied to an unpadded decode of unchanged packets.
  # PCM additionally has a direct integer-to-float reference independent of LAMP.
  sources=[]
  for rate in [8000,11025,44100,48000,96000,192000]:
   channels=2;lengths=[1,7,13,37,64,129,256,511,97,31,257,11];frames=[];pcm=bytearray();at=0
   for n in lengths:
    packet=bytearray()
    for _ in range(n):
     a=(at*91)%60001-30000;b=(at*157+47)%56001-28000;packet+=struct.pack('<hh',a,b);pcm+=struct.pack('<ff',a/32768,b/32768);at+=1
    frames.append(bytes(packet))
   t={'codec':'A_PCM/INT/LIT','private':None,'audio':m.element(0xB5,struct.pack('>d',float(rate)))+m.uint(0x9F,2)+m.uint(0x6264,16),'frames':frames,'discard':0,'rate':rate,'channels':2}
   sources.append((f'pcm-{rate}',t,lengths,bytes(pcm)))
  for codec,encoder,rate in [('flac','flac',48000),('opus','libopus',48000),('mp2','mp2',48000),('mp3','libmp3lame',48000),('aac','aac',48000),('alac','alac',48000),('speex','libspeex',16000),('vorbis','libvorbis',48000)]:
   source=work/(codec+'-encoder.mka');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=0.53','-c:a',encoder,source]);t=m.parse(source);t.update(rate=rate,channels=2,discard=0)
   clean=dict(t);clean.pop('codec_delay',None)
   if codec=='opus':private=bytearray(t['private']);private[10:12]=b'\0\0';clean['private']=bytes(private)
   base=work/(codec+'-base.mka');base.write_bytes(m.mux(clean));raw,_=source_decode(base,work/(codec+'-raw.f32'))
   if codec in ['opus','aac']:
    save(codec+'-seek-base.mka',base.read_bytes());t['seek_base']=codec+'-seek-base.mka'
   if codec=='opus':
    def samples(packet):
     c,k=packet[0]>>3,packet[0]&3;per=(480,960,1920,2880)[c&3] if c<12 else 480<<(c&1) if c<16 else 120<<(c&3);return per*(1 if k==0 else packet[1]&63 if k==3 else 2)
    lengths=[samples(x) for x in t['frames']]
   elif codec=='speex':lengths=[320]*len(t['frames'])
   elif codec in ['mp2','mp3']:lengths=[1152]*len(t['frames'])
   elif codec=='aac':lengths=[1024]*len(t['frames'])
   else:
    # Prefix decodes measure codec overlap/frame lengths before any timing map.
    # FLAC STREAMINFO's declared total must be zero for a shorter prefix.
    prefix=dict(clean);lengths=[];before=0
    if codec=='flac':private=bytearray(clean['private']);private[21]&=0xf0;private[22:26]=bytes(4);prefix['private']=bytes(private)
    for n in range(1,len(t['frames'])+1):
     prefix['frames']=t['frames'][:n];path=work/(codec+'-prefix.mka');path.write_bytes(m.mux(prefix));data,_=source_decode(path,work/(codec+'-prefix.f32'));lengths.append(len(data)//8-before);before=len(data)//8
   assert sum(lengths)*8==len(raw),(codec,lengths,len(raw));sources.append((codec,t,lengths,raw))
  for label,t,lengths,raw in sources:
   count=sum(lengths);head=int.from_bytes(t['private'][10:12],'little') if t['codec']=='A_OPUS' else 0
   patterns=[('delay',{'delay':6500000}),('explicit-zero',{'delay':0}),('head',{'padding':'negative'}),('middle',{'padding':'positive'}),('mixed',{'delay':6500000,'padding':'mixed'}),('xiph',{'delay':6500000,'padding':'mixed','lacing':1,'unknown':True}),('ebml',{'padding':'mixed','lacing':3}),('fixed',{'padding':'mixed','lacing':2})]
   if label=='pcm-8000':patterns += [('round-below',{'delay':62499}),('round-half',{'delay':62500}),('round-above',{'delay':62501})]
   for pattern,options in patterns:
    data,removed=make(t,lengths,**options);start=(options['delay']*t['rate']+500000000)//1000000000 if options.get('delay') is not None else head
    visible=bytearray(b'\1'*count);visible[:start]=bytes(min(start,count))
    for a,b in removed:visible[a:b]=bytes(b-a)
    expected=b''.join(raw[i*8:i*8+8] for i in range(count) if visible[i]);name=label+'-'+pattern+'.mka';ref=name+'.reference.f32';save(name,data);save(ref,expected);manifest['cases'].append({'file':name,'reference':ref,'rate':t['rate'],'channels':2,'description':options,'model_frames':len(expected)//8,'seek_base':t.get('seek_base'),'start_trim':start,'removed_intervals':removed,'raw_frames':count})
  source=work/'lifecycle-encoder.mka';run(['ffmpeg','-v','error','-y','-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s=16000:d=24','-c:a','libspeex',source]);t=m.parse(source);t.update(rate=16000,channels=2,discard=0);lengths=[320]*len(t['frames']);data,_=make(t,lengths,delay=6500000,padding='mixed',lacing=1);save('lifecycle.mka',data);manifest['lifecycle']='lifecycle.mka'
  t,lengths=sources[0][1:3];count=sum(lengths)
  # Empty presentation, unrelated track timing and integer/structure failures.
  data,_=make(t,lengths,delay=count*125000);save('empty.mka',data);save('empty.f32',b'');manifest['cases'].append({'file':'empty.mka','reference':'empty.f32','rate':8000,'channels':2,'description':'delay removes entire stream','model_frames':0})
  other=m.element(0xAE,m.uint(0xD7,2)+m.uint(0x83,2)+m.element(0x86,b'A_DTS')+m.uint(0x56AA,(1<<64)-1));data,_=make(t,lengths,extra_entries=other,foreign=True);save('unselected.mka',data);save('unselected.f32',sources[0][3]);manifest['cases'].append({'file':'unselected.mka','reference':'unselected.f32','rate':8000,'channels':2,'description':'unselected track delay/padding ignored','model_frames':count})
  for name,options in [('excess-delay',{'delay':(1<<64)-1}),('excess-padding',{'padding':'excess'}),*[(x,{'bad':x}) for x in ['long-delay','long-padding','duplicate-delay','duplicate-padding','duplicate-block','missing-block']]]:
   data,_=make(t,lengths,**options);file='bad-'+name+'.mka';save(file,data);manifest['bad'].append(file)
 (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
 shared={p.stem for p in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[p for p in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
 oracle=out/('matroska-timing-oracle'+suffix);chain=out/('matroska-timing-chain'+suffix);guard=out/('matroska-timing-guard'+suffix)
 for target,file in [(oracle,'matroska-timing-oracle.c'),(chain,'chain-oracle.c'),(guard,'speex-matroska-oracle.c')]:compile_c(target,[ROOT/'tests'/file],objects=objects,libraries=libraries)
 checks=[]
 for i,case in enumerate(manifest['cases']):
  if args.case and not case['file'].startswith(args.case):continue
  path=work/case['file'];reference=work/case['reference'];reset=[]
  if case.get('seek_base'):
   visible=bytearray(b'\1'*case['raw_frames']);visible[:case['start_trim']]=bytes(case['start_trim'])
   for a,b in case['removed_intervals']:visible[a:b]=bytes(b-a)
   positions=[p for p,v in enumerate(visible) if v];frames=case['model_frames'];targets=[0,1,2,17,119,120,511,512,4095,4096,frames//3,frames//2+1,frames-1 if frames else 0,frames,frames+1,(1<<64)-1];blob=bytearray()
   for requested in targets:
    target=min(requested,frames);raw_target=positions[target] if target<frames else case['raw_frames'];remaining=case['raw_frames']-raw_target;dump=work/'seek-raw.f32'
    if remaining:run([source_oracle,work/case['seek_base'],raw_target,dump]);raw=dump.read_bytes();assert len(raw)==remaining*8
    else:raw=b''
    tail=b''.join(raw[(p-raw_target)*8:(p-raw_target+1)*8] for p in positions[target:]);blob+=struct.pack('<QI',target,len(tail))+tail
   reset_file=work/(path.stem+'.seek-reference');reset_file.write_bytes(blob);reset=[reset_file]
  detail=json.loads(run([oracle,path,reference,0,case['rate'],case['channels'],*reset]).strip().splitlines()[-1]);assert detail['frames']==case['model_frames']
  if case['model_frames']:
   pcm,_=decode(path,work/(path.stem+'.cli.f32'));assert pcm==reference.read_bytes();bounds=json.loads(run([guard,path,reference,case['rate'],case['channels'],0,int(i==4)]).strip().splitlines()[-1])
  else:bounds=None
  checks.append({**case,'result':'exact independent visibility model','seek_comparator':'fresh unpadded codec seek plus independent visibility mask' if reset else 'continuous unpadded PCM plus independent visibility mask','oracle':detail,'guarded':bounds,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()});print(case['file']+': exact PCM and presentation seeks',flush=True)
 rejected=[] if args.case else [{'file':name,**json.loads(run([chain,'reject',work/name]).strip().splitlines()[-1])} for name in manifest['bad']]
 cancellation=[] if args.case else [{'test':mode,**json.loads(run([chain,mode,work/'speex-mixed.mka']).strip().splitlines()[-1])} for mode in ['cancel-open','cancel-read']]
 lifecycle=[]
 if args.probe:
  if not WINDOWS or args.case:raise RuntimeError('Full native Windows suite required for playback probes')
  probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  detail=run([probe,work/manifest['lifecycle']],timeout=75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail
  lifecycle.append({'file':manifest['lifecycle'],'description':'Speex 16 kHz stereo, CodecDelay, mixed signed whole-block padding and Xiph lacing','details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 interoperability=[]
 if not args.fixtures and not args.case:
  for name in ['pcm-48000-head.mka','pcm-48000-middle.mka']:
   target=work/(name+'.ffmpeg.f32');run(['ffmpeg','-v','error','-y','-i',work/name,'-f','f32le','-acodec','pcm_f32le',target]);assert target.read_bytes()==(work/(name+'.reference.f32')).read_bytes();interoperability.append({'file':name,'result':'exact installed FFmpeg PCM'})
 report={'result':'passed','platform':platform.platform(),'ffmpeg':manifest['ffmpeg'],'scope':'CodecDelay and signed BlockGroup padding; normative whole-block intervals including lacing, global-delay intersection, compressed presentation seeks and empty output. Expected intervals are selected by an independent per-sample mask from unchanged unpadded PCM; codec DSP has separate conformance suites. Timestamp gap scheduling and arbitrary SeekPreRoll are not established.','checks':checks,'rejections':rejected,'cancellation':cancellation,'binaries':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [cli,oracle,chain,guard]},'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/mkv.s','src/track.s','src/track_cuts.s','tests/verify-matroska-timing.py','tests/matroska-timing-oracle.c','tests/speex-matroska-oracle.c','tests/chain-oracle.c','tests/verify-matroska.py']}}
 report['native_lifecycle']=lifecycle;report['ffmpeg_interoperability']=interoperability;report['ffmpeg_comparator_limits']='FFmpeg 8.0.1 exposes CodecDelay as initial_padding without applying generic skip_samples; whole-block laced padding is checked against the normative mask rather than repeated per-lace trimming.';report['sources']['src/decoder.s']=hashlib.sha256((ROOT/'src/decoder.s').read_bytes()).hexdigest()
 report['scope']='CodecDelay and signed whole-Block padding, including lacing, global-delay intersections, compressed presentation seeks and empty output. Fine block clocks describe the intended compressed presentation. Independent sample masks select untimed source PCM; Opus/AAC seeks use fresh source seeks. Codec DSP, timestamp scheduling and SeekPreRoll have separate suites. Guarded mutations are capped at 128 reads and seek at 64.'
 report['sources'].update({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track_time.s','src/vorbis.s','src/vorbis_decode.inc','tests/track-source-oracle.c']});report['binaries'][source_oracle.name]=hashlib.sha256(source_oracle.read_bytes()).hexdigest()
 (out/('matroska-timing-debug.json' if args.case else 'matroska-timing-verification.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files and',len(checks)*16,'presentation seeks.')
if __name__=='__main__':main()
