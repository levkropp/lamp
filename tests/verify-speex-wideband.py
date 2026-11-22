#!/usr/bin/env python3
"""Speex wideband/ultra-wideband synthesis versus pinned official decoder."""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,default=ROOT/('bin/speex-check' if WINDOWS else 'build/speex-check'));args=parser.parse_args();out=args.bin.resolve();out.mkdir(parents=True,exist_ok=True)
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);source,includes,sources=ref.prepare()
 coeff=re.findall(r'static const float h0\[64\]\s*=\s*\{([^}]+)\}',(source/'libspeex/sb_celp.c').read_text())[0];(out/'speex-qmf-reference.h').write_text('static const float oracle_h0[64]={'+coeff+'};\n',encoding='utf-8',newline='\n')
 names=['speex_packet','speex_lsp','speex_filters','speex_excitation','speex_nb','speex_qmf','speex_decoder','speex_stereo'];objects=[]
 if WINDOWS:objects=[out/'obj'/f'{name}.obj' for name in names]
 else:
  for name in names:
   obj=out/(name+'.o');subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src'/f'{name}.s')],check=True);objects.append(obj)
 oracle=out/('speex-wideband-oracle.exe' if WINDOWS else 'speex-wideband-oracle');compile_c(oracle,[ROOT/'tests/speex-wideband-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT='],includes=[*includes,ROOT/'tests',out],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=180,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex wideband oracle failed ({result.returncode}):\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}')
 paths=[*[f'src/{n}.s' for n in names],*[f'src/{n}.inc' for n in ['speex_decoder','speex_qmf','speex_stereo','speex_high_tables','speex_stereo_tables','speex_nb','speex_nb_math','speex_nb_tables','speex_packet','speex_lsp_tables','speex_excitation','speex_excitation_tables']],'src/lamp.inc','tests/speex-wideband-oracle.c','tests/build-speex-reference.py','tests/generate-speex-high-tables.py','tests/verify-speex-wideband.py']
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Connected mono NB/WB/UWB frame synthesis and histories. This suite does not establish stereo output, file/container mapping, trim, seek or player integration; native Mac execution is unverified.','reference':'Unmodified Speex 1.2.1 floating-point, test-only','archive_url':ref.URL,'archive_sha256':ref.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}})
 (out/'speex-wideband-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
