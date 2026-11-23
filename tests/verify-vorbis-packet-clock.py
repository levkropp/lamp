#!/usr/bin/env python3
"""Verify packet sample boundaries/PCM independently of a container timeline."""
import argparse,hashlib,importlib.util,json,platform,struct,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c,vorbis_reference

def run(args):
 p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=120,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if p.returncode:raise RuntimeError(f'{args[0]} ({p.returncode}): {p.stdout[-1000:]} {p.stderr[-2000:]}')
 return p.stdout

class Bits:
 def __init__(self):self.bits=[]
 def put(self,value,n):self.bits.extend((value>>i)&1 for i in range(n))
 def data(self):return bytes(sum(b<<j for j,b in enumerate(self.bits[i:i+8])) for i in range(0,len(self.bits),8))

def silent_extreme(channels):
 # Original Floor1 silence with 64/8192 windows: no copied setup tables.
 ident=bytearray(30);ident[:7]=b'\x01vorbis';ident[11]=channels;struct.pack_into('<I',ident,12,48000);ident[28]=0xd6;ident[29]=1
 comment=b'\x03vorbis'+struct.pack('<II',0,0)+b'\x01';s=Bits()
 for v,n in [(0,8),(0x564342,24),(1,16),(1,24),(0,1),(0,1),(0,5),(0,4),(0,6),(0,16),
             (0,6),(1,16),(0,5),(0,2),(6,4),(0,6),(0,16),(0,24),(0,24),(0,24),(0,6),(0,8),(0,3),(0,1),
             (0,6),(0,16),(0,1),(0,1),(0,2),(0,8),(0,8),(0,8),(1,6)]:s.put(v,n)
 for mode in [0,1]:
  for v,n in [(mode,1),(0,16),(0,16),(0,8)]:s.put(v,n)
 s.put(1,1);packets=[bytes(ident),comment,b'\x05vorbis'+s.data()]
 sizes=[0,0,1,1,0,1,0,0,1,1,1,0,1,0]
 for i,mode in enumerate(sizes):
  b=Bits();b.put(0,1);b.put(mode,1)
  if mode:b.put(sizes[i-1] if i else 0,1);b.put(sizes[i+1] if i+1<len(sizes) else 0,1)
  for c in range(channels):b.put(0,1)
  packets.append(b.data())
 return packets

def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/mkv-clock-check' if WINDOWS else 'build/mkv-clock-check'));p.add_argument('--fixtures',type=Path);args=p.parse_args();out=args.bin.resolve();work=out/'vorbis-packet-clock';work.mkdir(parents=True,exist_ok=True)
 v,o,includes=vorbis_reference();names=('mdct','smallft','block','envelope','window','lsp','lpc','analysis','synthesis','psy','info','floor1','floor0','res0','mapping0','registry','codebook','sharedbook','lookup','bitrate')
 refs=compile_c(work/'reference',[v/f'lib/{n}.c' for n in names]+[o/f'src/{n}.c' for n in ['bitwise','framing']],defines=['_CRT_SECURE_NO_WARNINGS'],includes=includes,compile_only=True)
 shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if x.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack','-lm']
 oracle=out/('vorbis-packet-clock-oracle'+('.exe' if WINDOWS else ''));compile_c(oracle,[ROOT/'tests/vorbis-packet-clock-oracle.c'],objects=[*objects,*refs],libraries=libraries,includes=includes)
 if args.fixtures:
  files=sorted(args.fixtures.resolve().glob('*.packets'))
 else:
  spec=importlib.util.spec_from_file_location('m',ROOT/'tests/verify-matroska.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);files=[]
  def save(name,packets):
   path=work/(name+'.packets');path.write_bytes(struct.pack('<I',len(packets))+b''.join(struct.pack('<I',len(x))+x for x in packets));files.append(path)
  for rate in [8000,16000,22050,32000,44100,48000,96000,192000]:
   for ch in [1,2]:
    for quality in [0,8]:
     name=f'{rate}-{ch}-q{quality}';path=work/(name+'.mka');source=f'aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.7*sin(2*PI*3000*t)\\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s={rate}:d=0.43'
     run(['ffmpeg','-v','error','-y','-f','lavfi','-i',source,'-ac',ch,'-c:a','libvorbis','-q:a',quality,path]);t=m.parse(path);private=t['private'];assert private[0]==2;at=1;sizes=[]
     for _ in range(2):
      size=0
      while private[at]==255:size+=255;at+=1
      size+=private[at];at+=1;sizes.append(size)
     sizes.append(len(private)-at-sum(sizes));headers=[]
     for size in sizes:headers.append(private[at:at+size]);at+=size
     save(name,headers+t['frames'])
  for ch in [1,2]:save(f'extreme-64-8192-{ch}',silent_extreme(ch))
 checks=[]
 for path in files:
  result=json.loads(run([oracle,path]).strip().splitlines()[-1]);checks.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),**result});print(path.name+': '+str(result['window_transitions'])+' window transitions',flush=True)
 report={'result':'passed','platform':platform.platform(),'reference':'Pinned unmodified Xiph libvorbis1.3.7 packet synthesis, granulepos=-1 (no container trim)','scope':'Mono/stereo, eight rates, two qualities, transient windows, 64/8192 extreme windows; independent blocksize counts and PCM at every packet boundary, six cold suffix/reset runs, capacity and truncated-prefix guards. Does not establish all Vorbis profiles, atomic failure recovery or native device playback.','checks':checks,'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['src/vorbis.s','src/vorbis_decode.inc','tests/vorbis-packet-clock-oracle.c','tests/verify-vorbis-packet-clock.py','tests/verify-matroska.py','tests/reference/vorbis-reference-hashes.json']},'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest()}
 (out/'vorbis-packet-clock-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'packet streams.')
if __name__=='__main__':main()
