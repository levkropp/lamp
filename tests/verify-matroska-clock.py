#!/usr/bin/env python3
"""Sample-exact Matroska media time, independent of decoded packet order."""
import argparse,hashlib,importlib.util,json,platform,shutil,struct,subprocess,sys
from bisect import bisect_right
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c

def run(args,timeout=120):
 p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if p.returncode:raise RuntimeError(f'{Path(str(args[0])).name} ({p.returncode}): {p.stdout[-1200:]} {p.stderr[-2000:]}')
 return p.stdout

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--bin',type=Path,default=ROOT/('bin/mkv-clock-check' if WINDOWS else 'build/mkv-clock-check'));parser.add_argument('--fixtures',type=Path);parser.add_argument('--probe',action='store_true');args=parser.parse_args();out=args.bin.resolve();work=out/'matroska-clock';work.mkdir(parents=True,exist_ok=True);ext='.exe' if WINDOWS else '';cli=out/('lamp-cli'+ext)
 spec=importlib.util.spec_from_file_location('m',ROOT/'tests/verify-matroska.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 shared={p.stem for p in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[p for p in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
 source_oracle=out/('matroska-clock-source'+ext);compile_c(source_oracle,[ROOT/'tests/track-source-oracle.c'],objects=objects,libraries=libraries)
 def source_pcm(path):
  target=work/'source.f32';run([source_oracle,path,0,target]);return target.read_bytes()
 if args.fixtures:
  source=args.fixtures.resolve();manifest=json.loads((source/'fixtures.json').read_text(encoding='utf-8'))
  if source!=work:
   for name in manifest['files']:shutil.copyfile(source/name,work/name)
 else:
  manifest={'cases':[],'files':[],'bad':[]}
  def save(name,data):(work/name).write_bytes(data);manifest['files'].append(name)
  for rate in [8000,11025,44100,48000,96000,192000]:
   # One segment tick is exactly one sample at 8 kHz; other rates deliberately
   # exercise conversion and fine timestamp precision with a 1 us tick.
   scale=125000 if rate==8000 else 1000;lengths=[31,127,17,511,63,256,97,129]
   for kind in ['continuous','leading-gap','interior-gap','overlap','negative','late-info','late-clock','unknown-clusters','track-scale','track-scale-two','track-scale-f32']:
    raw=0;offset=0;expected=[];clusters=[]
    entry=m.uint(0xD7,7)+m.uint(0x83,2)+m.element(0x86,b'A_PCM/INT/LIT')+m.element(0xE1,m.element(0xB5,struct.pack('>d',float(rate)))+m.uint(0x9F,2)+m.uint(0x6264,16))
    track_scale=0.5 if kind in ['track-scale','track-scale-f32'] else 2.0 if kind=='track-scale-two' else 1.0
    if kind.startswith('track-scale'):entry+=m.element(0x23314F,struct.pack('>f' if kind=='track-scale-f32' else '>d',track_scale))
    for index,n in enumerate(lengths):
     if kind=='leading-gap' and index==0:offset=rate//20
     if kind in ['interior-gap','late-info','late-clock','unknown-clusters','track-scale','track-scale-two','track-scale-f32'] and index==3:offset+=rate//25
     if kind=='overlap' and index==3:offset-=rate//50
     if kind=='negative' and index==0:offset-=rate//200
     target=raw+offset
     ns=(abs(target)*1000000000+rate//2)//rate;ns=-ns if target<0 else ns
     ticks=(abs(ns)+scale//2)//scale;ticks=-ticks if ns<0 else ticks
     # Force signed relative values and independently account for legacy scale.
     relative=-8 if ticks>=8 else ticks
     cluster=ticks-relative if track_scale==1 else ticks+int(8*track_scale)
     if track_scale!=1:relative=-8
     packet=bytearray()
     for i in range(n):
      at=raw+i;a=at*91%60001-30000;b=(at*157+47)%56001-28000;packet+=struct.pack('<hh',a,b)
      dest=at+offset
      if dest<0 or dest<len(expected):continue
      while len(expected)<dest:expected.append(b'\0'*8)
      expected.append(struct.pack('<ff',a/32768,b/32768))
     payload=m.size_bytes(7)+struct.pack('>h',relative)+b'\x80'+packet
     clock=m.uint(0xE7,cluster);block=m.element(0xA3,payload)
     clusters.append(m.element(0x1F43B675,block+clock if kind=='late-clock' else clock+block,kind=='unknown-clusters'))
     raw+=n
    info=m.element(0x1549A966,m.uint(0x2AD7B1,scale));tracks=m.element(0x1654AE6B,m.element(0xAE,entry));body=tracks+b''.join(clusters)+info if kind=='late-info' else info+tracks+b''.join(clusters)
    data=m.element(0x1A45DFA3,m.element(0x4282,b'matroska'))+m.element(0x18538067,body,kind=='unknown-clusters');name=f'pcm-{rate}-{kind}.mka';reference=name+'.f32';save(name,data);save(reference,b''.join(expected));manifest['cases'].append({'file':name,'reference':reference,'rate':rate,'frames':len(expected),'description':kind})
  suffix_cache={}
  for label,encoder,rate in [('flac','flac',48000),('opus','libopus',48000),('mp2','mp2',48000),('mp3','libmp3lame',48000),('aac','aac',48000),('alac','alac',48000),('speex','libspeex',16000),('vorbis','libvorbis',48000),('ac3','ac3',48000),('eac3','eac3',48000),('wavpack','wavpack',48000)]:
   path=work/(label+'-encoder.mka');run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=1.2','-c:a',encoder,path]);track=m.parse(path);track.update(rate=rate,discard=0);track.pop('codec_delay',None);track.pop('seek_preroll',None);clean=dict(track)
   if label=='opus':private=bytearray(track['private']);private[10:12]=bytes(2);clean['private']=bytes(private)
   neutral=work/(label+'-neutral.mka');neutral.write_bytes(m.mux(clean));pcm=source_pcm(neutral)
   lengths=[];before=0;prefix=dict(clean)
   if label=='flac':private=bytearray(clean['private']);private[21]&=0xf0;private[22:26]=bytes(4);prefix['private']=bytes(private)
   for n in range(1,len(track['frames'])+1):
    prefix['frames']=track['frames'][:n];path=work/'prefix.mka';path.write_bytes(m.mux(prefix));count=len(source_pcm(path))//8;lengths.append(count-before);before=count
   assert sum(lengths)*8==len(pcm),label
   starts=[];raw_total=0
   for n in lengths:starts.append(raw_total);raw_total+=n
   for kind in ['continuous','leading-gap','interior-gap','overlap','negative','laced-padding','preroll-gap']:
    ns=250000001 if kind=='preroll-gap' else 0;head=int.from_bytes(track['private'][10:12],'little') if label=='opus' else 0
    if kind=='laced-padding':head=(6500000*rate+500000000)//1000000000
    entry=m.uint(0xD7,7)+m.uint(0x83,2)+m.element(0x86,track['codec'].encode())+m.element(0xE1,track['audio'])
    if track.get('private'):entry+=m.element(0x63A2,track['private'])
    if kind=='laced-padding':entry+=m.uint(0x56AA,6500000)
    if ns:entry+=m.uint(0x56BB,ns)
    groups=m.blocks_of(track['frames'],3 if kind=='laced-padding' else 0,3);raw=0;packet=0;offset=0;mapping=[];clusters=[]
    for index,group in enumerate(groups):
     count=sum(lengths[packet:packet+len(group)]);packet+=len(group)
     if kind=='leading-gap' and index==0:offset=rate//20
     if kind in ['interior-gap','preroll-gap'] and index==len(groups)//2:offset+=rate//25
     if kind=='overlap' and index==len(groups)//2:offset-=rate//50
     if kind=='negative' and index==0:offset=-rate//50
     amount=((1 if index%2 else -1)*min(count,[17,count,1,count//2][index%4])) if kind=='laced-padding' else 0
     first=max(raw+max(-amount,0),head);end=raw+count-max(amount,0)
     for source_at in range(first,end):
      dest=source_at-head+offset
      if dest<0 or dest<len(mapping):continue
      mapping.extend([None]*(dest-len(mapping)));mapping.append(source_at)
     coded=raw+offset;pts=(abs(coded)*1000000000+rate//2)//rate;pts=-pts if coded<0 else pts;ticks=(abs(pts)+500)//1000;ticks=-ticks if pts<0 else ticks;clock=max(0,ticks);relative=ticks-clock
     payload=m.size_bytes(7)+struct.pack('>h',relative)+bytes([0x86 if len(group)>1 else 0x80])+(m.lace(group,3) if len(group)>1 else group[0]);body=m.element(0xA1,payload)
     if amount:
      value=(abs(amount)*1000000000+rate//2)//rate;body+=m.sint(0x75A2,-value if amount<0 else value)
     clusters.append(m.element(0x1F43B675,m.uint(0xE7,clock)+m.element(0xA0,body),kind=='laced-padding'));raw+=count
    name=label+'-'+kind+'.mka';reference=name+'.f32';data=m.element(0x1A45DFA3,m.element(0x4282,b'matroska'))+m.element(0x18538067,m.element(0x1549A966,m.uint(0x2AD7B1,1000))+m.element(0x1654AE6B,m.element(0xAE,entry))+b''.join(clusters),kind=='laced-padding');expected=b''.join(bytes(8) if p is None else pcm[p*8:p*8+8] for p in mapping);save(name,data);save(reference,expected)
    reset=None
    if label in ['opus','aac','ac3','eac3']:
     frames=len(mapping);targets=[0,1,2,17,119,120,511,512,4095,4096,frames//3,frames//2+1,frames-1 if frames else 0,frames,frames+1,(1<<64)-1];blob=bytearray()
     for request in targets:
      target=min(request,frames);goal=next((p for p in mapping[target:] if p is not None),raw_total);history=(ns*rate+999999999)//1000000000
      if label=='opus':history=max(history,3840)
      chosen=max(0,bisect_right(starts,max(0,goal-history))-1)
      if label!='opus':chosen=max(0,chosen-1)
      if request==0 and kind=='continuous':chosen=0
      key=(label,chosen)
      if key not in suffix_cache:
       suffix=dict(clean,frames=track['frames'][chosen:]);path=work/'suffix.mka';path.write_bytes(m.mux(suffix));suffix_cache[key]=source_pcm(path)
      suffix=suffix_cache[key];origin=starts[chosen];tail=b''.join(bytes(8) if p is None else suffix[(p-origin)*8:(p-origin+1)*8] for p in mapping[target:]);assert len(tail)==(frames-target)*8,(name,target,chosen)
      blob+=struct.pack('<QI',target,len(tail))+tail
     reset=name+'.seek-reference';save(reset,blob)
    manifest['cases'].append({'file':name,'reference':reference,'rate':rate,'frames':len(mapping),'description':kind,'codec':label,'seek_reference':reset})
  # Invalid clock metadata is rejected structurally before decoding payloads.
  good=(work/'pcm-8000-continuous.mka').read_bytes()
  old=m.uint(0x2AD7B1,125000)
  for name,value in [('zero-scale',m.uint(0x2AD7B1,0)),('duplicate-scale',old+old),('long-scale',m.element(0x2AD7B1,bytes(9)))]:
   # Rebuild containing EBML sizes, rather than corrupting unrelated lengths.
   segment=next(e for e in m.elements(good,0,len(good)) if e[0]==0x18538067);parts=[]
   for ident,a,b in m.elements(good,segment[1],segment[2]):parts.append(m.element(ident,value if ident==0x1549A966 else good[a:b]))
   file='bad-'+name+'.mka';save(file,good[:good.find(bytes.fromhex('18538067'))]+m.element(0x18538067,b''.join(parts)));manifest['bad'].append(file)
  def rewrite(data,change):
   def child(start,end):
    result=[]
    for ident,a,b in m.elements(data,start,end):
     payload=child(a,b) if ident in [0x18538067,0x1654AE6B,0xAE,0x1F43B675,0x1549A966] else data[a:b]
     result.append(change(ident,payload))
    return b''.join(result)
   return child(0,len(data))
  def bad(name,change):
   file='bad-'+name+'.mka';save(file,rewrite(good,change));manifest['bad'].append(file)
  bad('missing-clock',lambda i,p:b'' if i==0xE7 else m.element(i,p))
  bad('duplicate-clock',lambda i,p:m.element(i,p)*2 if i==0xE7 else m.element(i,p))
  bad('long-clock',lambda i,p:m.element(i,bytes(9) if i==0xE7 else p))
  bad('range-clock',lambda i,p:m.element(i,bytes.fromhex('7fffffffffffffff') if i==0xE7 else p))
  for label,value in [('zero',0.0),('negative',-1.0),('nan',float('nan')),('infinite',float('inf'))]:
   bad('track-scale-'+label,lambda i,p,value=value:m.element(i,p+(m.element(0x23314F,struct.pack('>d',value)) if i==0xAE else b'')))
  bad('track-scale-short',lambda i,p:m.element(i,p+(m.element(0x23314F,b'abc') if i==0xAE else b'')))
  bad('track-scale-duplicate',lambda i,p:m.element(i,p+(m.element(0x23314F,struct.pack('>d',1.0))*2 if i==0xAE else b'')))
  bad('huge-scale',lambda i,p:m.element(i,(1<<63).to_bytes(8,'big') if i==0x2AD7B1 else p))
  # An unselected, finite-but-unusable track clock and foreign Cluster cannot
  # change the selected track's times or selected ordinal.
  extra=m.element(0xAE,m.uint(0xD7,91)+m.uint(0x83,2)+m.element(0x86,b'A_DTS')+m.element(0x23314F,struct.pack('>d',1e300)))
  foreign=m.element(0x1F43B675,m.uint(0xE7,(1<<64)-1)+m.element(0xA3,m.size_bytes(91)+b'\0\0\x80junk'))
  # Keep Tracks before the foreign Cluster, as the reader requires.
  variant=rewrite(good,lambda i,p:m.element(i,extra+p if i==0x1654AE6B else p+foreign if i==0x18538067 else p))
  for choice in [0,2]:
   name=f'unselected-clock-{choice}.mka';ref=name+'.f32';save(name,variant);save(ref,(work/'pcm-8000-continuous.mka.f32').read_bytes());manifest['cases'].append({'file':name,'reference':ref,'rate':8000,'frames':len((work/ref).read_bytes())//8,'description':'unselected clock ignored','track_choice':choice})
  # One trillion samples of silence, represented by a tiny input and a span.
  entry=m.uint(0xD7,7)+m.uint(0x83,2)+m.element(0x86,b'A_PCM/INT/LIT')+m.element(0xE1,m.element(0xB5,struct.pack('>d',8000.0))+m.uint(0x9F,2)+m.uint(0x6264,16));packet=b''.join(struct.pack('<hh',i,-i) for i in range(1,5));gap=1000000000000
  data=m.element(0x1A45DFA3,m.element(0x4282,b'matroska'))+m.element(0x18538067,m.element(0x1549A966,m.uint(0x2AD7B1,125000))+m.element(0x1654AE6B,m.element(0xAE,entry))+m.element(0x1F43B675,m.uint(0xE7,gap)+m.element(0xA3,m.size_bytes(7)+b'\0\0\x80'+packet)));save('sparse-gap.mka',data);manifest['sparse']={'file':'sparse-gap.mka','gap':gap}
  manifest['lifecycle']=[]
  for label,encoder in [('opus','libopus'),('vorbis','libvorbis')]:
   path=work/(label+'-lifecycle-encoder.mka');run(['ffmpeg','-v','error','-y','-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s=48000:d=12','-c:a',encoder,path]);track=m.parse(path);times=track['timestamps_ns'];index=next(i for i,t in enumerate(times) if t>=4700000000);first=1 if label=='vorbis' else 0;index=first+4*((index-first)//4);track['timestamps_ns']=[t+100000000+(500000000 if i>=index else 0) for i,t in enumerate(times)];name=label+'-lifecycle.mka';save(name,m.mux(track,lacing=3,group=4));manifest['lifecycle'].append(name)
 (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
 shared={p.stem for p in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[p for p in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'];oracle=out/('matroska-clock-oracle'+ext);chain=out/('matroska-clock-chain'+ext)
 guard=out/('matroska-clock-guard'+ext);sparse=out/('matroska-clock-sparse'+ext)
 for target,file in [(oracle,'matroska-timing-oracle.c'),(chain,'chain-oracle.c'),(guard,'speex-matroska-oracle.c'),(sparse,'matroska-clock-sparse-oracle.c')]:compile_c(target,[ROOT/'tests'/file],objects=objects,libraries=libraries)
 checks=[]
 for case in manifest['cases']:
  path=work/case['file'];reference=work/case['reference'];choice=case.get('track_choice',0);reset=[work/case['seek_reference']] if case.get('seek_reference') else [];detail=json.loads(run([oracle,path,reference,choice,case['rate'],2,*reset]).strip().splitlines()[-1]);assert detail['frames']==case['frames'];target=work/'cli.f32';target.unlink(missing_ok=True);run([cli,'--decode',*(['--track',choice] if choice else []),path,target]);assert target.read_bytes()==reference.read_bytes();checks.append({**case,'result':'exact timestamped PCM and seeks','oracle':detail});print(case['file']+': exact media time and PCM',flush=True)
 rejected=[{'file':name,**json.loads(run([chain,'reject',work/name]).strip().splitlines()[-1])} for name in manifest['bad']]
 bounds=[]
 for name in ['pcm-8000-leading-gap.mka','opus-laced-padding.mka','vorbis-overlap.mka']:
  case=next(c for c in manifest['cases'] if c['file']==name);bounds.append({'file':name,**json.loads(run([guard,work/name,work/case['reference'],case['rate'],2,0,1]).strip().splitlines()[-1])})
 sparse_result=json.loads(run([sparse,work/manifest['sparse']['file'],manifest['sparse']['gap']]).strip().splitlines()[-1])
 lifecycle=[]
 if args.probe:
  if not WINDOWS:raise RuntimeError('Native Windows required for device probe')
  probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
  for name in manifest['lifecycle']:
   detail=run([probe,work/name],timeout=75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'file':name,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
 report={'result':'passed','platform':platform.platform(),'scope':'Initial PCM timestamp integration: signed relative clocks, six rates, fine TimestampScale, leading/interior silence, overlap/negative clipping, late Info/Cluster Timestamp, unknown Clusters and fractional legacy track scale. This is not complete codec, A/V synchronization or device coverage.','checks':checks,'rejections':rejected,'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track_time.s','src/mkv.s','src/track.s','src/track_cuts.s','src/decoder.s','tests/verify-matroska-clock.py','tests/matroska-timing-oracle.c']},'binaries':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [cli,oracle,chain]}}
 report.update(scope='Independent per-sample media placement of PCM and 11 compressed codec mappings; six PCM rates, fine/signed/scaled clocks, gaps/overlap/negative clipping, late metadata, lacing/padding/delay, selected ordinals and ignored foreign clocks. Opus/AAC/AC3/EAC3 seeks use independently decoded packet suffixes; codec DSP is established separately. Guarded mutations are capped at 128 reads and seek at 64. This does not establish video/A/V synchronization or native Mac playback.',guarded=bounds,sparse_gap=sparse_result,native_lifecycle=lifecycle)
 report['sources'].update({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/vorbis.s','src/vorbis_decode.inc','tests/track-source-oracle.c','tests/speex-matroska-oracle.c','tests/matroska-clock-sparse-oracle.c','tests/verify-matroska.py']});report['binaries'].update({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [source_oracle,guard,sparse]})
 (out/'matroska-clock-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files and',len(checks)*16,'media seeks.')
if __name__=='__main__':main()
