#!/usr/bin/env python3
"""Ogg/Speex timing, exact cached seeks and independent whole-file PCM."""
import argparse
from datetime import datetime,timezone
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
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/('bin/speex-check' if WINDOWS else 'build/speex-check'));args=p.parse_args();out=args.bin.resolve();out.mkdir(parents=True,exist_ok=True)
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);source,includes,sources=ref.prepare();names=['ogg','speex','speex_packet','speex_lsp','speex_filters','speex_excitation','speex_nb','speex_qmf','speex_decoder','speex_stereo'];objects=[]
 if WINDOWS:objects=[out/'obj'/f'{name}.obj' for name in names]
 else:
  for name in names:
   obj=out/(name+'.o');subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src'/f'{name}.s')],check=True);objects.append(obj)
 oracle=out/('speex-file-oracle.exe' if WINDOWS else 'speex-file-oracle');compile_c(oracle,[ROOT/'tests/speex-file-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT=','MAX_CHARS_PER_FRAME=16384'],includes=[*includes,ROOT/'tests'],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=240,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex file oracle failed ({result.returncode}):\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}')
 paths=[*[f'src/{n}.s' for n in names],*[f'src/{n}.inc' for n in ['speex_packet','speex_excitation','speex_nb','speex_nb_math','speex_decoder','speex_qmf','speex_stereo','speex_lsp_tables','speex_excitation_tables','speex_nb_tables','speex_high_tables','speex_stereo_tables']],'src/lamp.inc','tests/build-speex-reference.py','tests/speex-file-oracle.c','tests/verify-speex-files.py']
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Ogg/Speex mapped-stream bridge: headers, packet grouping, origin/priming/tail timing, stereo float output, lazy exact-history cache and seeks. This component report alone does not establish chain/player integration or native Mac execution.','reference':'Unmodified Speex 1.2.1 encoder and float decoder, test-only','archive_url':ref.URL,'archive_sha256':ref.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{x:hashlib.sha256((ROOT/x).read_bytes()).hexdigest() for x in paths}});(out/'speex-file-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
