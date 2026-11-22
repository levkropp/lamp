#!/usr/bin/env python3
"""Official WavPack hybrid/correction encoding versus original PCM and LAMP.

The pinned C reference is test-only. --core-only exercises paired frames
without filesystem discovery; ordinary mode also requires automatic .wvc use.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import random
import struct
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,DEFAULT_MASKS,stereo_view,WINDOWS

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(args,expected=0):
 kwargs={'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}
 p=subprocess.run([str(a) for a in args],capture_output=True,text=True,timeout=30,**kwargs)
 if p.returncode!=expected:raise RuntimeError(f'{args[0]} returned {p.returncode}: {p.stdout[-2000:]}{p.stderr[-2000:]}')
 return p.stdout
def blocks(data):
 p=0
 while p+32<=len(data):
  if data[p:p+4]!=b'wvpk':break
  n=int.from_bytes(data[p+4:p+8],'little')+8
  if n<32 or p+n>len(data):break
  yield p,data[p:p+n];p+=n
def metadata(block):
 p=32
 while p+2<=len(block):
  ident,n=block[p:p+2];p+=2
  if ident&128:n|=int.from_bytes(block[p:p+2],'little')<<8;p+=2
  n*=2;payload=block[p:p+n-(1 if ident&64 else 0)]
  yield ident&63,payload
  p+=n
def native_float(source,bits,floating):
 if floating:return source
 values=struct.unpack('<'+'i'*(len(source)//4),source)
 scale=2.**(1-((bits+7)//8*8))
 return struct.pack('<'+'f'*len(values),*[x*scale for x in values])

def subblock(ident,payload):
 words=(len(payload)+1)//2
 header=bytes([ident|(64 if len(payload)&1 else 0)|(128 if words>255 else 0),words&255])
 if words>255:header+=(words>>8).to_bytes(2,'little')
 return header+payload+(b'\0' if len(payload)&1 else b'')

def synthetic_vectors(work,reference,oracle,out,core_only):
 """Reference-normalized legacy weights and rare cross-prediction vectors.

 The official encoder no longer writes two-byte shaping weights or term -3.
 Reuse its entropy payload, change prediction metadata, obtain a proper
 prefix from the reference, then set independent sample CRCs. Every finished
 fixture must pass the ordinary full reference decode, including its CRC.
 """
 template=next(blocks((work/'int-16-2-0.wv').read_bytes()))[1]
 buddy=next(blocks((work/'int-16-2-0.wvc').read_bytes()))[1]
 cross=None
 for path in sorted(work.glob('*.wv')):
  if path.name.startswith('synthetic-'):continue
  companion=Path(str(path)+'c')
  if not companion.exists():continue
  for (_,main),(_,correction) in zip(blocks(path.read_bytes()),blocks(companion.read_bytes())):
   flags=int.from_bytes(main[24:28],'little')
   if flags&3!=1 or flags&(4|128|256):continue
   if any(ident==2 and any((v&31)==3 for v in payload) for ident,payload in metadata(main)):
    cross=(main,correction);break
  if cross:break
 if not cross:raise RuntimeError('No stereo 16-bit template with cross term -2')
 checks=[]
 cases=[('legacy-old',template,buddy,bytes([127,128]),False),('legacy-new',template,buddy,bytes([128,127]),True),('legacy-negative',template,buddy,bytes([192,192]),True),('legacy-zero',template,buddy,bytes([0,0]),False),('term-minus-3',*cross,None,False)]
 for name,main,correction,weights,new in cases:
  frames=int.from_bytes(main[20:24],'little')
  def change(block,is_correction):
   header=bytearray(block[:32]);flags=int.from_bytes(header[24:28],'little')
   flags=(flags&~(3|0x7c0000|0x10000000|64|0x20000000))|3|(29<<18)
   if weights is not None:flags|=64|(0x20000000 if new else 0)
   else:flags|=32
   header[10]=0;header[12:16]=frames.to_bytes(4,'little');header[16:20]=bytes(4);header[24:28]=flags.to_bytes(4,'little')
   items=[]
   for ident,payload in metadata(block):
    if ident in (7,0x2f):continue
    if weights is None and ident==2:
     payload=bytes((v&224)|2 if (v&31)==3 else v for v in payload)
    items.append(subblock(ident,payload))
   if is_correction and weights is not None:items.append(subblock(7,weights))
   data=header+b''.join(items);data[4:8]=(len(data)-8).to_bytes(4,'little');return data
  first,second=change(main,False),change(correction,True)
  # Prefix decoding stops before the declared final sample and hence before
  # CRC verification. Final files restore the true count and verify CRC.
  a=work/('synthetic-'+name+'.prefix.wv');b=work/('synthetic-'+name+'.prefix.wvc')
  first[20:24]=second[20:24]=(frames+1).to_bytes(4,'little');a.write_bytes(first);b.write_bytes(second)
  expected=[]
  for corrected in [0,1]:
   raw=work/('synthetic-'+name+f'.prefix-{corrected}.i32');run([reference,'prefix',a,b,raw,frames,corrected]);data=raw.read_bytes()
   values=struct.unpack('<'+'i'*(len(data)//4),data);crc=0xffffffff
   for value in values:crc=(crc*3+value)&0xffffffff
   target=second if corrected else first;target[20:24]=frames.to_bytes(4,'little');target[28:32]=crc.to_bytes(4,'little');expected.append(data)
  wv=work/('synthetic-'+name+'.wv');wvc=Path(str(wv)+'c');wv.write_bytes(first);wvc.write_bytes(second)
  for corrected in [0,1]:
   raw=work/('synthetic-'+name+f'.full-{corrected}.i32');run([reference,'decode',wv,raw,corrected])
   if raw.read_bytes()!=expected[corrected]:raise RuntimeError('Synthetic reference full decode mismatch: '+name)
  target=work/('synthetic-'+name+'.f32');bounds=json.loads(run([oracle,wv,wvc,target]));pcm=native_float(expected[1],32,False)
  if target.read_bytes()!=pcm:raise RuntimeError('Synthetic corrected prediction differs: '+name)
  if not core_only:
   target.unlink()
   run([out/('lamp-cli.exe' if WINDOWS else 'lamp-cli'),'--decode',wv,target])
   if target.read_bytes()!=pcm:raise RuntimeError('Synthetic automatic correction differs: '+name)
  checks.append({'name':name,'frames':frames,'bounds_rejections':bounds['contract_rejections'],'wv_sha256':digest(wv),'wvc_sha256':digest(wvc),'pcm_sha256':hashlib.sha256(pcm).hexdigest(),'result':'full reference CRC and corrected PCM exact'})
  print(name+': full reference CRC and corrected PCM exact',flush=True)
 return checks

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--bin',type=Path,default=ROOT/'build/wvc-check')
 parser.add_argument('--reference',type=Path,default=ROOT/'build/reference'/('wavpack-hybrid-reference.exe' if WINDOWS else 'wavpack-hybrid-reference'))
 parser.add_argument('--core-only',action='store_true')
 parser.add_argument('--playback',action='store_true',help='silent native Windows WASAPI lifecycle (probe build required)')
 args=parser.parse_args();out=args.bin.resolve();reference=args.reference.resolve()
 if not reference.exists():
  spec=importlib.util.spec_from_file_location('wv_reference',ROOT/'tests/build-wavpack-reference.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);reference=module.build()
 oracle=out/('wavpack-pair-oracle.exe' if WINDOWS else 'wavpack-pair-oracle')
 work=ROOT/'tests/generated/wvc';work.mkdir(parents=True,exist_ok=True)
 specs=[]
 for channels in range(1,9):specs.append((f'layout-{channels}',channels,16,9999,32|2048,641,False))
 for bits in [8,12,16,20,24,32]:
  for channels in [1,2]:
   for shape in [-1000,-500,0,500,1000,9999]:specs.append((f'int-{bits}-{channels}-{shape}',channels,bits,shape,0,641,False))
 for flags in [512|32,2048|32,4096|32,65536|32,65536|16|32]:specs.append((f'flags-{flags}',2,24,-500,flags,1025,False))
 for channels in [1,2,6,8]:
  for shape in [0,-500,9999]:specs.append((f'float-{channels}-{shape}',channels,32,shape,32|2048,641,True))
 for frames in [1,2,3,17,127,128,129,3000]:specs.append((f'tail-{frames}',2,16,-500,32,frames,False))
 specs.append(('float-special',2,32,-500,32,257,True))
 checks=[];coverage=set();lossy_changed=False
 for number,(name,channels,bits,shape,flags,frames,floating) in enumerate(specs):
  rng=random.Random(1901+number);raw=[]
  for i in range(frames*channels):
   if floating:
    if name=='float-special':raw.append([0,0x80000000,0x7f800000,0xff800000,0x7fc12345,1,0x807fffff,0x3f800000,0xbf800000][i%9])
    else:raw.append(struct.unpack('<I',struct.pack('<f',rng.uniform(-.95,.95) if i//channels%31 else 0.))[0])
   else:
    value=rng.randrange(-(1<<(bits-1)),1<<(bits-1))
    if i//channels%29<4:value=0
    value<<=(bits+7)//8*8-bits
    raw.append(value&0xffffffff)
  source=struct.pack('<'+'I'*len(raw),*raw)
  input_path=work/(name+'.i32');wv=work/(name+'.wv');wvc=work/(name+'.wvc');original=work/(name+'.reference.i32');pcm=work/(name+'.paired.f32')
  input_path.write_bytes(source)
  run([reference,'encode',input_path,wv,wvc,channels,bits,48000,flags,shape,2500,128,int(floating)])
  ref=json.loads(run([reference,'decode',wv,original,1]))
  if original.read_bytes()!=source:raise RuntimeError(f'Official corrected PCM differs from input: {name}')
  result=json.loads(run([oracle,wv,wvc,pcm]))
  expected=stereo_view(native_float(source,bits,floating),channels,DEFAULT_MASKS[channels-1])
  if pcm.read_bytes()!=expected:
   actual=pcm.read_bytes();first=next((i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b),min(len(actual),len(expected)))
   raise RuntimeError(f'Paired PCM differs: {name}, byte {first}, {len(actual)} vs {len(expected)}')
  if not args.core_only:
   exported=work/(name+'.auto.f32');exported.unlink(missing_ok=True)
   run([out/('lamp-cli.exe' if WINDOWS else 'lamp-cli'),'--decode',wv,exported])
   if exported.read_bytes()!=expected:raise RuntimeError(f'Companion PCM differs: {name}')
  if number==0:
   lossy=work/'lossy-reference.i32';run([reference,'decode',wv,lossy,0]);lossy_changed=lossy.read_bytes()!=source
  for _,block in blocks(wv.read_bytes()):
   f=int.from_bytes(block[24:28],'little')
   if f&32:coverage.add('cross prediction')
   if f&16:coverage.add('joint stereo')
   if f&64:coverage.add('noise shaping')
   if f&0x20000000:coverage.add('new shaping')
   for ident,payload in metadata(block):
    if ident==2:
     coverage.update('term '+str((v&31)-5) for v in payload)
  for _,block in blocks(wvc.read_bytes()):
   for ident,payload in metadata(block):
    if ident==7:coverage.add('shaping metadata '+str(len(payload)))
    if ident==12:coverage.add('extra bitstream')
  checks.append({'name':name,'channels':channels,'bits':bits,'float':floating,'shape':shape,'frames':frames,'packets':result['packets'],'bounds_rejections':result['contract_rejections'],'wv_sha256':digest(wv),'wvc_sha256':digest(wvc),'pcm_sha256':hashlib.sha256(expected).hexdigest(),'result':'passed'})
  print(name+': corrected PCM exact',flush=True)
 if not lossy_changed:raise RuntimeError('No reference fixture demonstrated actual lossy information restored by the correction stream')
 synthetic=synthetic_vectors(work,reference,oracle,out,args.core_only)
 coverage.update(['legacy two-byte shaping metadata','corrected cross term -3'])
 # Pairing and parser corruption must reject without crossing guarded input
 # or output boundaries. Header identity, metadata sizes and CRC are covered.
 valid=work/'layout-2.wv';valid_corr=work/'layout-2.wvc';base=valid_corr.read_bytes();mutations=[]
 for offset in [0,4,8,10,16,20,24,28,32,33]:
  d=bytearray(base);d[offset]^=0xff;mutations.append((f'flip-{offset}',bytes(d)))
 mutations += [('short-'+str(n),base[:n]) for n in [1,31,32,len(base)-1]]
 rejected=[]
 for name,data in mutations:
  path=work/('bad-'+name+'.wvc');path.write_bytes(data)
  result=run([oracle,valid,path,work/'bad.f32'],expected=3 if len(data)<32 else 1)
  rejected.append(name)
 discovery=[];seeks=[];queue_check=None;rate_check=None;playback=None
 if not args.core_only:
  cli=out/('lamp-cli.exe' if WINDOWS else 'lamp-cli')
  def export(path,label,*options):
   target=work/(label+'.export.f32');target.unlink(missing_ok=True);run([cli,'--decode',*options,path,target]);return target.read_bytes()
  expected=(work/'layout-2.paired.f32').read_bytes();main=valid.read_bytes()
  root=work/'discovery';root.mkdir(exist_ok=True)
  absent=root/'absent.wv';absent.write_bytes(main);Path(str(absent)+'c').unlink(missing_ok=True)
  lossy=root/'absent.reference.i32';run([reference,'decode',absent,lossy,0]);lossy_pcm=native_float(lossy.read_bytes(),16,False)
  if export(absent,'absent')!=lossy_pcm:raise RuntimeError('Missing companion did not retain the reference lossy decode')
  discovery.append({'case':'missing companion','result':'reference lossy PCM retained'})
  for name in ['Unicode-\u00b5-\u7d44.WV','magic-without-extension']:
   path=root/name;path.write_bytes(main);Path(str(path)+'c').write_bytes(base)
   if export(path,'path-'+str(len(discovery)))!=expected:raise RuntimeError('Companion pathname handling failed')
   discovery.append({'case':name,'result':'corrected PCM exact'})
  malformed={'empty':b'','garbage':b'bad','wrong':(work/'layout-1.wvc').read_bytes(),'truncated':base[:-1]}
  first=next(blocks(base))[1];malformed['missing-frame']=base[len(first):];malformed['extra-frame']=base+first
  damaged=bytearray(base);damaged[28]^=1;malformed['bad-crc']=bytes(damaged)
  oversized=bytearray(base);oversized[4:8]=b'\xff'*4;malformed['oversized-block']=bytes(oversized)
  for name,data in malformed.items():
   path=root/(name+'.wv');path.write_bytes(main);Path(str(path)+'c').write_bytes(data);run([cli,'--check',path],expected=2);discovery.append({'case':name+' companion','result':'rejected'})
  path=root/'directory.wv';path.write_bytes(main);Path(str(path)+'c').mkdir(exist_ok=True);run([cli,'--check',path],expected=2);discovery.append({'case':'directory companion','result':'rejected'})
  lossless=root/'lossless.wv';noise_companion=Path(str(lossless)+'c')
  run([reference,'lossless',work/'layout-2.i32',lossless,noise_companion,2,16,48000,0,0,2500,128,0]);noise_companion.write_bytes(b'not a correction stream')
  if export(lossless,'lossless')!=expected:raise RuntimeError('Unrelated companion changed lossless playback')
  discovery.append({'case':'ordinary lossless with unrelated companion','result':'ignored companion, original PCM exact'})
  for name,times in [('tail-3000',[1,2,3,4,6,10,20,32,61]),('layout-8',[1,2,5,10,13])]:
   full=(work/(name+'.paired.f32')).read_bytes()
   for milliseconds in times:
    data=export(work/(name+'.wv'),f'seek-{name}-{milliseconds}','--start',f'0.{milliseconds:03}')
    if data!=full[milliseconds*48*8:]:raise RuntimeError(f'Corrected seek mismatch: {name} at {milliseconds} ms')
    seeks.append({'file':name,'milliseconds':milliseconds,'result':'exact'})
  queued=work/'queue.export.f32';queued.unlink(missing_ok=True)
  run([cli,'--decode',valid,absent,work/'layout-8.wv',queued])
  if queued.read_bytes()!=expected+lossy_pcm+(work/'layout-8.paired.f32').read_bytes():raise RuntimeError('Corrected/lossy/corrected queue PCM mismatch')
  queue_check='Corrected/lossy/corrected queue exact; companion state released between entries'
  # The resampler has its own independent oracle. Here a source WAV with the
  # already verified PCM isolates companion ownership from the conversion.
  wave=root/'same-pcm.wav';body=b'fmt '+struct.pack('<IHHIIHH',16,3,2,48000,48000*8,8,32)+b'data'+struct.pack('<I',len(expected))+expected;wave.write_bytes(b'RIFF'+struct.pack('<I',len(body)+4)+b'WAVE'+body)
  if export(valid,'resampled-wv','--rate','44100')!=export(wave,'resampled-wave','--rate','44100'):raise RuntimeError('Corrected resampler input differs from identical verified WAV PCM')
  rate_check='Corrected 48 kHz input at 44.1 kHz equals identical verified WAV PCM through the existing resampler'
  if args.playback:
   if not WINDOWS:raise RuntimeError('--playback is a native Windows test')
   silent=work/'lifecycle.i32';silent.write_bytes(bytes(30*48000*2*4));path=work/'lifecycle.wv'
   run([reference,'encode',silent,path,Path(str(path)+'c'),2,16,48000,32,9999,2500,6000,0])
   message=run([out/'engine-probe.exe',path])
   if 'Exclusive output: 48000 Hz session lifecycle passed.' not in message or 'Default-device callback: paused and active restart passed' not in message:raise RuntimeError('Build the probe with --probe-exclusive --probe-default-device')
   playback='Silent native exclusive WASAPI: pause/resume, stop/reopen, seek/paused seek, cancelled open, synthetic paused/active default-output restart and pending-command preservation'
  print(f'Companion discovery/error cases: {len(discovery)}; exact seeks: {len(seeks)}; queue and resampler checks passed',flush=True)
 report={'result':'passed','platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Paired-frame reconstruction only' if args.core_only else 'Paired-frame reconstruction, automatic native .wvc discovery, seeks, ownership and queue/resampler behavior; source stereo/surround decoding is emitted as stereo. Mac native execution and Matroska correction side data are not established by this report.','reference':'WavPack 5.9.0 BSD, test-only encoder/decoder','reference_sha256':digest(reference),'lossy_difference_demonstrated':lossy_changed,'checks':checks,'coverage':sorted(coverage),'rejections':rejected,'discovery':discovery,'seeks':seeks,'queue_check':queue_check,'rate_check':rate_check,'native_playback':playback,'oracle_sha256':digest(oracle),'sources':{name:digest(ROOT/name) for name in ['src/wavpack.s','src/wavpack_block.inc','src/wavpack_correction.inc','src/wavpack_file.inc','src/decoder.s','src/win/platform.s','src/linux/platform.s','src/mac/platform.s','tests/wavpack-hybrid-reference.c','tests/wavpack-pair-oracle.c','tests/verify-wavpack-correction.py']}}
 report['synthetic_reference_vectors']=synthetic
 (out/'wavpack-correction-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 print(f'Passed {len(checks)} corrected files and {len(rejected)} malformed pairs; '+', '.join(sorted(coverage)),flush=True)

if __name__=='__main__':main()
