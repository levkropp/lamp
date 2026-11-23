#!/usr/bin/env python3
"""Independent per-sample timeline, clock rounding, gaps and overlap checks."""
import argparse,hashlib,json,platform,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c

def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/mkv-clock-check' if WINDOWS else 'build/mkv-clock-check'));args=p.parse_args();out=args.bin.resolve();suffix='.exe' if WINDOWS else '';obj=out/('track-time-probe.obj' if WINDOWS else 'track-time-probe.o')
 if not WINDOWS:subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'tests/track-time-probe.s')],check=True)
 elif not obj.exists():raise RuntimeError('Assemble tests/track-time-probe.s into the output directory first')
 oracle=out/('track-time-oracle'+suffix);compile_c(oracle,[ROOT/'tests/track-time-oracle.c'],objects=[out/'obj'/('track_time.obj' if WINDOWS else 'track_time.o'),obj],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=120,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(result.stdout+result.stderr)
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update(platform=platform.platform(),scope='Per-sample source/media mapping, gaps, overlap/negative clipping, cut intersections, repeated seeks, exact gap seeks, sparse giant gaps, signed/scaled clocks, cancellation and allocator failures. This component does not establish Matroska demux or device playback.',sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track_time.s','tests/track-time-oracle.c','tests/track-time-probe.s','tests/verify-track-time.py']},oracle_sha256=hashlib.sha256(oracle.read_bytes()).hexdigest());(out/'track-time-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
