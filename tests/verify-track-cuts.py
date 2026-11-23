#!/usr/bin/env python3
"""Sparse presentation maps against an independent per-sample visibility mask."""
import argparse,hashlib,json,platform,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',type=Path,default=ROOT/('bin/mkv-timing-check' if WINDOWS else 'build/mkv-timing-check'));args=p.parse_args();out=args.bin.resolve();suffix='.exe' if WINDOWS else '';objects=[out/'obj'/('track_cuts.obj' if WINDOWS else 'track_cuts.o'),out/('track-cuts-probe.obj' if WINDOWS else 'track-cuts-probe.o')]
 if not WINDOWS:subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(objects[1]),str(ROOT/'tests/track-cuts-probe.s')],check=True)
 elif not objects[1].exists():raise RuntimeError('Assemble tests/track-cuts-probe.s into the output directory first')
 oracle=out/('track-cuts-oracle'+suffix);compile_c(oracle,[ROOT/'tests/track-cuts-oracle.c'],objects=objects,libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=120,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(result.stdout+result.stderr)
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update(platform=platform.platform(),scope='Independent sample-mask comparisons of raw/presented mapping, packet spans, global trim intersections, whole/adjacent deletions, zero output, allocation failures and resource caps. This component alone does not establish container or playback timing.',oracle_sha256=hashlib.sha256(oracle.read_bytes()).hexdigest(),sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track_cuts.s','tests/track-cuts-probe.s','tests/track-cuts-oracle.c','tests/verify-track-cuts.py']});(out/'track-cuts-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
