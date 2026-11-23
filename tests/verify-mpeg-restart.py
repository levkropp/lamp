"""Test-only counterfactual MPEG reservoir and native-reopen controls."""
import argparse,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT as root,compile_c,WINDOWS
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,default=root/('bin/flv-gathered-check' if WINDOWS else 'build/flv-gathered-check'));args=parser.parse_args();out=args.bin.resolve();work=out/'controls';work.mkdir(exist_ok=True);ext='.exe' if WINDOWS else '';objects=list((out/'obj').glob('*.obj' if WINDOWS else '*.o'));shared={x.stem for x in (root/'src').glob('*.s')}|{'platform','linux_platform'};objects=[x for x in objects if x.stem in shared];libs=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
def assemble(name,text):
 source=work/(name+'.s');source.write_text(text,encoding='utf-8');obj=work/(name+('.obj' if WINDOWS else '.o'))
 native=shutil.which('llvm-mc') if WINDOWS else None
 if native:subprocess.run([native,'-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',root/'src',source,'-o',obj],check=True)
 elif WINDOWS:
  def wsl(p):return '/mnt/'+p.drive[0].lower()+str(p)[2:].replace('\\','/')
  llvm=root/'build/toolchain/root/usr/lib/llvm-18/bin/llvm-mc';env=root/'build/toolchain/root/usr/lib/x86_64-linux-gnu'
  subprocess.run(['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+wsl(env),wsl(llvm),'-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',wsl(root/'src'),wsl(source),'-o',wsl(obj)],check=True)
 else:subprocess.run(['as','--64','-I',root/'src','-o',obj,source],check=True)
 return obj
mp=(root/'src/mp3.s').read_text();tk=(root/'src/track.s').read_text()
needle='    cmp eax, [rip + mp_main_missing]\n    cmovb eax, [rip + mp_main_missing]  # only real unused bytes are restart history\n';assert mp.count(needle)==1;unknown=assemble('mp3-unknown-prefix',mp.replace(needle,''))
needle='    mov edx, [rax + TK_BYTES]\n    mov rcx, [rax + TK_POINTER]\n    call mpa_reservoir_bytes\n    add esi, eax\n';assert tk.count(needle)==1;old_history=assemble('track-byte-history',tk.replace(needle,'    add esi, [rax + TK_BYTES]\n'))
needle='    call mp3_close\n    mov dword ptr [rip + mp_track_tolerant], 0\n    mov rcx, rsi\n';assert mp.count(needle)==1;native=assemble('mp3-native-tolerance',mp.replace(needle,'    call mp3_close\n    mov rcx, rsi\n'))
def build(name,file,replacements):
 binary=work/(name+ext);compile_c(binary,[root/'tests'/file],objects=[replacements.get(x.stem,x) for x in objects],libraries=libs);return binary
def invoke(binary,args,success):
 p=subprocess.run([str(binary),*[str(x) for x in args]],capture_output=True,text=True,timeout=90,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}));assert (p.returncode==0)==success,(binary,p.returncode,p.stdout,p.stderr);return {'exit_code':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip(),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
fixture=out/'flv-gathered/mpeg-48000-2-vbr-continuous.flv';ref=fixture.with_name(fixture.name+'.f32');args=[fixture,ref,0,48000,2]
bad=build('unknown-prefix-control','matroska-timing-oracle.c',{'mp3':unknown,'track':old_history});fixed=build('known-prefix-control','matroska-timing-oracle.c',{'track':old_history});results={'unknown_prefix':invoke(bad,args,False),'known_prefix':invoke(fixed,args,True)}
data=(out/'flv-gathered/mpeg-44100-2-cbr-continuous.flv').read_bytes();at=int.from_bytes(data[5:9],'big')+4;raw=b''
while at+11<=len(data):
 n=int.from_bytes(data[at+1:at+4],'big')
 if data[at]==8:raw+=data[at+12:at+11+n]
 at+=15+n
assert raw[:2]==b'\xff\xfb';corrupt=bytearray(raw);corrupt[4]=255;corrupt[5]|=128;path=work/'missing-reservoir.mp3';path.write_bytes(corrupt);args=[out/'flv-gathered/mpeg-44100-2-cbr-continuous.flv',path]
legacy=build('native-tolerance-control','mpeg-reopen-oracle.c',{'mp3':native});current=build('native-reset','mpeg-reopen-oracle.c',{});results.update(native_legacy=invoke(legacy,args,False),native_current=invoke(current,args,True))
report={'result':'passed','scope':'Test-only counterfactual objects: unknown prefix retention reproduces a VBR seek failure with the prior history cutoff; correcting only prefix provenance passes. Omitting only the native-open tolerance reset reproduces acceptance of missing reservoir after packet seek/close. No control object is linked into shipping binaries.','results':results,'sources':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in ['src/mp3.s','src/track.s','tests/mpeg-reopen-oracle.c','tests/matroska-timing-oracle.c','tests/verify-mpeg-restart.py']},'fixtures':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [fixture,ref,path]}}
(out/'flv-gathered-negative-controls.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(results,indent=2))
