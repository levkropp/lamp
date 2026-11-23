#!/usr/bin/env python3
"""Bounded submitted-PCM clock model, integer boundaries and concurrent reads."""
import hashlib,json,subprocess,sys
from pathlib import Path
from lamp_test import ROOT,WINDOWS,compile_c,out_dir
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    out=out_dir();binary=out/('audio-clock-oracle'+('.exe' if WINDOWS else ''));obj=out/'obj'/('audio_clock.obj' if WINDOWS else 'audio_clock.o')
    compile_c(binary,[ROOT/'tests/audio-clock-oracle.c'],objects=[obj],libraries=[] if WINDOWS else ['-pthread'])
    p=subprocess.run([str(binary)],capture_output=True,timeout=60,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}));assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
    result=json.loads(p.stdout);files=[ROOT/'src/audio_clock.s',ROOT/'src/audio_clock.inc',ROOT/'tests/audio-clock-oracle.c',Path(__file__)]
    result.update(platform=sys.platform,scope='Submitted-frame map and explicit already-mapped clock publication; CPU-only, no audio/GPU endpoint',sources={p.relative_to(ROOT).as_posix():sha(p) for p in files},artifacts={p.relative_to(out).as_posix():sha(p) for p in [binary,obj]})
    path=out/'audio-clock-verification.json';path.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
