#!/usr/bin/env python3
"""Reference-checked Speex LPC/filter components, including real codec calls."""
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
 # Rename definitions only in two wrapper translation units. The included
 # official source remains byte-for-byte unchanged. Codec callers still use
 # original names, which mirror each actual call through the assembly kernel.
 wrappers={
  'lsp':('lsp_to_lpc lsp_interpolate'.split(),'''
void lsp_to_lpc(const float*f,float*a,int n,char*s){test_speex_lpc(spxref_lsp_to_lpc,f,a,n,s);}
void lsp_interpolate(float*a,float*b,float*c,int n,int sub,int total,float margin){test_speex_interpolate(spxref_lsp_interpolate,a,b,c,n,sub,total,margin);}
'''),
  'filters':('bw_lpc iir_mem16 highpass'.split(),'''
void bw_lpc(float g,const float*a,float*b,int n){test_speex_bw(spxref_bw_lpc,g,a,b,n);}
void iir_mem16(const float*a,const float*b,float*c,int n,int o,float*m,char*s){test_speex_iir(spxref_iir_mem16,a,b,c,n,o,m,s);}
void highpass(const float*a,float*b,int n,int id,float*m){test_speex_highpass(spxref_highpass,a,b,n,id,m);}
''')}
 for name,(symbols,body) in wrappers.items():
  path=out/('reference-'+name+'.c');path.write_text('#include "speex-filter-test.h"\n'+''.join(f'#define {s} spxref_{s}\n' for s in symbols)+'#include '+json.dumps((source/'libspeex'/f'{name}.c').as_posix())+'\n'+''.join(f'#undef {s}\n' for s in symbols)+body,encoding='utf-8',newline='\n')
  sources=[path if p.name==name+'.c' else p for p in sources]
 if WINDOWS:objects=[out/'obj/speex_filters.obj']
 else:
  obj=out/'speex_filters.o';subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src/speex_filters.s')],check=True);objects=[obj]
 oracle=out/('speex-filter-oracle.exe' if WINDOWS else 'speex-filter-oracle')
 compile_c(oracle,[ROOT/'tests/speex-filter-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT='],includes=[*includes,ROOT/'tests'],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=180,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex filter oracle failed ({result.returncode}):\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}')
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Exact floating-point Speex interpolation/margins, approximate-cosine LSP-to-LPC, bandwidth expansion, stateful IIR and all five high-pass filters. Real NB/WB/UWB reference encoder/decoder calls, including DTX, PLC/recovery, enhancement toggles and resets, are mirrored through assembly and compared. Pitch/innovation/QMF/complete LAMP Speex playback remain unimplemented. Native Mac execution is unverified.','reference':'Speex 1.2.1 floating-point C, test-only interception of original unmodified source','archive_url':reference.URL,'archive_sha256':reference.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['src/speex_filters.s','src/lamp.inc','tests/speex-filter-test.h','tests/speex-filter-oracle.c','tests/build-speex-reference.py','tests/verify-speex-filters.py']},'reference_wrappers':{name:hashlib.sha256((out/f'reference-{name}.c').read_bytes()).hexdigest() for name in wrappers}})
 target=out/'speex-filter-verification.json';target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
