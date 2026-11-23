#!/usr/bin/env python3
"""Differential Speex packet foundations; this does not establish PCM playback."""
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
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,default=ROOT/('bin/speex-check' if WINDOWS else 'build/speex-check'));args=parser.parse_args();out=args.bin.resolve();out.mkdir(parents=True,exist_ok=True)
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference);source,includes,sources=reference.prepare()
 if WINDOWS:objects=[out/'obj'/f'{name}.obj' for name in ['speex_packet','speex_lsp']]
 else:
  objects=[]
  for name in ['speex_packet','speex_lsp']:
   obj=out/(name+'.o');subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src'/f'{name}.s')],check=True);objects.append(obj)
 oracle=out/('speex-packet-oracle.exe' if WINDOWS else 'speex-packet-oracle')
 compile_c(oracle,[ROOT/'tests/speex-packet-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT='],includes=includes,libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=180,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex oracle failed ({result.returncode}):\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}')
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'MSB bit access, bounded Speex headers, canonical NB/WB/UWB packet structure and exact float NB30/NB18/high12 LSP codebook reconstruction. Official C encodes and fully decodes test packets to establish frame counts and bit positions; PCM synthesis and file playback are checked by separate suites. Mutation acceptance is structural only. Native macOS execution is unverified.','reference':'Speex 1.2.1 floating-point, test-only','archive_url':reference.URL,'archive_sha256':reference.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['src/speex_packet.s','src/speex_packet.inc','src/speex_lsp.s','src/speex_lsp_tables.inc','src/lamp.inc','tests/speex-packet-oracle.c','tests/build-speex-reference.py','tests/generate-speex-tables.py','tests/verify-speex-packet.py']}})
 target=out/'speex-packet-verification.json';target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
