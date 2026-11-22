#!/usr/bin/env python3
"""Whole Speex NB coded/DTX frame assembly versus pinned official decoder."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,default=ROOT/('bin/speex-check' if WINDOWS else 'build/speex-check'));args=parser.parse_args();out=args.bin.resolve();out.mkdir(parents=True,exist_ok=True)
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference);source,includes,sources=reference.prepare()
 names=['speex_packet','speex_lsp','speex_filters','speex_excitation','speex_nb'];objects=[]
 if WINDOWS:objects=[out/'obj'/f'{name}.obj' for name in names]
 else:
  for name in names:
   obj=out/(name+'.o');subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src'/f'{name}.s')],check=True);objects.append(obj)
 oracle=out/('speex-nb-oracle.exe' if WINDOWS else 'speex-nb-oracle')
 compile_c(oracle,[ROOT/'tests/speex-nb-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT='],includes=[*includes,ROOT/'tests'],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=180,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex NB oracle failed ({result.returncode}):\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}')
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Connected mono narrowband coded/DTX/lost/recovery frame synthesis. Wideband synthesis, stereo reconstruction, containers, seek and player integration are not established. Native Mac execution is unverified.','reference':'Unmodified Speex 1.2.1 floating-point, test-only','archive_url':reference.URL,'archive_sha256':reference.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in [*[f'src/{n}.s' for n in names],'src/speex_nb.inc','src/speex_nb_math.inc','src/speex_nb_tables.inc','src/speex_packet.inc','src/speex_lsp_tables.inc','src/speex_excitation.inc','src/speex_excitation_tables.inc','src/lamp.inc','tests/speex-nb-oracle.c','tests/build-speex-reference.py','tests/generate-speex-nb-tables.py','tests/verify-speex-nb.py']}})
 (out/'speex-nb-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
