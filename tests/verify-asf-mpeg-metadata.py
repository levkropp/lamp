"""ASF MPEG byte-layout reuse: native ID3/Xing/trims and metadata-only objects."""
import argparse,hashlib,importlib.util,json,platform,shutil,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS
def module(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/'tests'/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
w=module('asf_metadata_writer','verify-asf.py');f=module('asf_metadata_helpers','verify-flv-gathered.py');p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/('bin/asf-gathered-check' if WINDOWS else 'build/asf-gathered-check'));p.add_argument('--fixtures',type=Path);args=p.parse_args();out=args.bin.resolve();work=out/'asf-mpeg-metadata';work.mkdir(exist_ok=True);cli=out/('lamp-cli.exe' if WINDOWS else 'lamp-cli');sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
def decode(path):
 target=work/'decoded.f32';target.unlink(missing_ok=True);f.run([cli,'--decode',path,target]);return target.read_bytes()
def mux(objects):
 fmt=struct.pack('<HHIIHHH',0x55,1,44100,16000,1,0,0);packets=[]
 for i,(data,ms) in enumerate(objects):
  for off in range(0,len(data),901):packets.append(w.packet([w.payload(data[off:off+901],i,off,len(data),time=ms,replic=8 if off==0 else 0)],physical=2048))
 return w.asf([w.stream(fmt)],packets,minimum=2048,preroll=3100)
if args.fixtures:
 origin=args.fixtures.resolve();manifest=json.loads((origin/'fixtures.json').read_text())
 if origin!=work:
  for name in manifest['files']:shutil.copyfile(origin/name,work/name)
else:
 manifest={'files':[],'cases':[]};path=work/'native-xing.mp3';f.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=337:sample_rate=44100:duration=0.65','-ac','1','-c:a','libmp3lame','-q:a','2','-write_xing','1','-metadata','title=ASF clock metadata',path]);raw=path.read_bytes();pcm=decode(path);assert raw[:3]==b'ID3';tagbytes=10+sum((raw[6+i]&127)<<(21-i*7) for i in range(4));assert 10<=tagbytes<len(raw)
 cases=[('whole',[(raw,3100)],pcm),('leading',[(raw,3125)],bytes(1103*8)+pcm),('negative',[(raw,3080)],pcm[882*8:]),('metadata-only-prefix',[(raw[:tagbytes],0xffffffff),(raw[tagbytes:],3100)],pcm)]
 for kind,tail in [('id3v1',b'TAG'+bytes(125)),('ape',b'APETAGEX'+struct.pack('<4I',2000,32,0,0)+bytes(8))]:cases.append((kind+'-tail',[(raw,3100),(tail,0xffffffff)],pcm))
 for label,objects,reference in cases:
  name=label+'.asf';ref=name+'.f32';(work/name).write_bytes(mux(objects));(work/ref).write_bytes(reference);manifest['files'] += [name,ref];manifest['cases'].append(dict(file=name,reference=ref,frames=len(reference)//8))
 manifest['hashes']={name:sha(work/name) for name in manifest['files']};manifest['generator_sha256']={str(path.relative_to(ROOT)).replace('\\','/'):sha(path) for path in [Path(__file__),ROOT/'tests/verify-asf.py']};manifest['native_reference_binary_sha256']=sha(cli)
for name,digest in manifest['hashes'].items():assert sha(work/name)==digest
for name,digest in manifest['generator_sha256'].items():assert sha(ROOT/name)==digest
(work/'fixtures.json').write_bytes((json.dumps(manifest,indent=2)+'\n').encode());checks=[]
for case in manifest['cases']:
 assert decode(work/case['file'])==(work/case['reference']).read_bytes(),case['file'];checks.append({**case,'result':'exact native metadata/trim PCM with independent presentation placement'})
report=dict(result='passed',platform=platform.platform(),scope='ID3v2 and Xing/encoder-trim reuse, source-order fragments, leading/negative media time, metadata-only prefix and ID3v1/APE tails. Codec DSP is independently covered elsewhere.',checks=checks,fixture_hashes=manifest['hashes'],native_reference_binary_sha256=manifest['native_reference_binary_sha256'],sources={name:sha(ROOT/name) for name in ['src/asf.s','src/asf_views.inc','src/decoder.s','src/track.s','src/track_time.s','src/mp3.s','tests/verify-asf-mpeg-metadata.py','tests/verify-asf.py','tests/verify-flv-gathered.py']},binaries={cli.name:sha(cli)});(out/'asf-mpeg-metadata-verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode());print('Passed six ASF MPEG metadata, trim, and clock cases.')
