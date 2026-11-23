#!/usr/bin/env python3
"""CPU-only fake-client verification of the same assembly audio render function."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
from lamp_test import ROOT,WINDOWS,compile_c
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',required=True,type=Path);args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();work=out/'player-clock';work.mkdir(exist_ok=True);obj=work/'player-clock-probe.obj';source=ROOT/'tests/player-clock-probe.s';assembler=shutil.which('llvm-mc')
    def path(p):
        s=str(p.absolute());return s if assembler else '/mnt/'+s[0].lower()+s[2:].replace('\\','/')
    options=['-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',path(ROOT/'src'),'-I',path(ROOT/'src/win'),path(source),'-o',path(obj)]
    lib=ROOT/'build/toolchain/root/usr/lib';command=[assembler,*options] if assembler else ['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+path(lib/'x86_64-linux-gnu'),path(lib/'llvm-18/bin/llvm-mc'),*options]
    subprocess.run(command,check=True,capture_output=True,timeout=30)
    objects=[out/'obj'/(p.stem+'.obj') for p in sorted((ROOT/'src').glob('*.s'))]+[out/'obj'/(n+'.obj') for n in ['platform','output_notifications','output_format','output_exclusive','video','video_stream','video_present','video_window','video_cli']]+[obj]
    binary=work/'player-clock-oracle.exe';compile_c(binary,[ROOT/'tests/player-clock-oracle.c'],objects=objects,libraries=list((out/'obj').glob('*.lib')))
    p=subprocess.run([str(binary)],capture_output=True,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW);assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
    report=json.loads(p.stdout);report.update(sources={p.relative_to(ROOT).as_posix():sha(p) for p in [source,ROOT/'src/win/player.s',ROOT/'src/win/player_clock.inc',ROOT/'src/audio_clock.s',ROOT/'src/audio_clock.inc',ROOT/'tests/player-clock-oracle.c',Path(__file__)]},artifacts={p.relative_to(out).as_posix():sha(p) for p in [binary,*objects]})
    (out/'player-clock-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['result','checks','render_iterations','fingerprint','scope']}))
if __name__=='__main__':main()
