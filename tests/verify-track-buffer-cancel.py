"""Isolated counterfactual for cancellation of already buffered packet PCM."""
import argparse,hashlib,json,os,shutil,struct,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/('bin/asf-gathered-check' if WINDOWS else 'build/asf-gathered-check'));args=p.parse_args();out=args.bin.resolve();work=out/'buffer-cancel-controls';work.mkdir(exist_ok=True);ext='.exe' if WINDOWS else '';shared={x.stem for x in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in (out/'obj').glob('*.obj' if WINDOWS else '*.o') if x.stem in shared];libs=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
text=(ROOT/'src/track.s').read_text();copy='    mov eax, [rip + track_used]\n    cmp eax, [rip + track_available]\n    jb .Ltk_read_copy\n';anchor='    # Cancellation also stops already decoded PCM, before copying it out.\n';point='.Ltk_read_not_cancelled:\n'+copy
assert text.count(point)==text.count(anchor)==1;legacy=text.replace(point,'.Ltk_read_not_cancelled:\n').replace(anchor,copy+'    # Test-only previous behavior: check cancellation after buffered PCM.\n');source=work/'track-previous-buffer-cancel.s';source.write_bytes(legacy.encode());obj=source.with_suffix('.obj' if WINDOWS else '.o')
native=shutil.which('llvm-mc') if WINDOWS else None
if native:subprocess.run([native,'-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',ROOT/'src',source,'-o',obj],check=True)
elif WINDOWS:
 def wsl(path):return '/mnt/'+path.drive[0].lower()+str(path)[2:].replace('\\','/')
 llvm=ROOT/'build/toolchain/root/usr/lib/llvm-18/bin/llvm-mc';lib=ROOT/'build/toolchain/root/usr/lib/x86_64-linux-gnu'
 subprocess.run(['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+wsl(lib),wsl(llvm),'-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',wsl(ROOT/'src'),wsl(source),'-o',wsl(obj)],check=True)
else:subprocess.run(['as','--64','-I',ROOT/'src','-o',obj,source],check=True)
executables={}
for name in ['current','previous']:
 binary=work/(name+ext);compile_c(binary,[ROOT/'tests/track-buffer-cancel-oracle.c'],objects=[obj if name=='previous' and x.stem=='track' else x for x in objects],libraries=libs);executables[name]=binary
# Both files contain one ordinary, continuous packet track. First reading a
# single frame leaves the rest decoded, so the next read must honor cancel.
raw=struct.pack('<hh',1234,-4321)*8192;payload=b'\x3f'+raw;n=len(payload);tag=b'\x08'+n.to_bytes(3,'big')+bytes(7)+payload+(11+n).to_bytes(4,'big');flv=work/'continuous-pcm.flv';flv.write_bytes(b'FLV\1\4'+(9).to_bytes(4,'big')+bytes(4)+tag);fixtures=[out/'asf-gathered/pcm_s16le-44100-2-continuous.asf',flv];checks=[]
failure_line=next(i for i,line in enumerate((ROOT/'tests/track-buffer-cancel-oracle.c').read_text().splitlines(),1) if 'CHECK(!decoder_read(out.pcm,1)' in line)
for fixture in fixtures:
 for name,binary in executables.items():
  result=subprocess.run([str(binary),str(fixture)],capture_output=True,text=True,timeout=30,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
  if name=='current':assert result.returncode==0,(fixture,result.stdout,result.stderr)
  else:assert result.returncode==1 and f'buffered cancel line{failure_line} error0' in result.stderr,(fixture,result.returncode,result.stdout,result.stderr)
  checks.append(dict(file=fixture.name,variant=name,exit_code=result.returncode,stdout=result.stdout.strip(),stderr=result.stderr.strip(),binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest()))
report=dict(result='passed',scope='Only the track_read cancellation placement differs in a test-only object. Previous code returns buffered audio after cancellation; current code aborts before copying, preserves output guards and reopens cleanly. No control object enters shipping binaries.',checks=checks,sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track.s','src/decoder.s','src/asf.s','src/asf_views.inc','tests/track-buffer-cancel-oracle.c','tests/verify-track-buffer-cancel.py']},counterfactual_source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),counterfactual_object_sha256=hashlib.sha256(obj.read_bytes()).hexdigest());(out/'track-buffer-cancel-verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode());print('Previous buffered cancellation fails; current cancellation and reopen pass for ASF and FLV.')
