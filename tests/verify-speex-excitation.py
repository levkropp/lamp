#!/usr/bin/env python3
"""Pinned reference versus Speex pitch, innovation and seeded noise kernels."""
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
 pitch_args='float*a,float*b,int c,int d,float e,const void*f,int g,int*h,float*i,SpeexBits*j,char*k,int l,int m,float n,int o'
 wrappers={
 'ltp':(['pitch_unquant_3tap','forced_pitch_unquant'],'\n'.join('void '+name+'('+pitch_args+'){test_speex_pitch('+str(forced)+',spxref_'+name+',a,b,c,d,e,f,g,h,i,j,k,l,m,n,o);}' for forced,name in enumerate(['pitch_unquant_3tap','forced_pitch_unquant']))),
 'cb_search':(['split_cb_shape_sign_unquant','noise_codebook_unquant'],'\n'.join('void '+name+'(float*a,const void*b,int c,SpeexBits*d,char*e,uint32_t*f){test_speex_innovation('+str(noise)+',spxref_'+name+',a,b,c,d,e,f);}' for noise,name in enumerate(['split_cb_shape_sign_unquant','noise_codebook_unquant'])))}
 for name,(symbols,body) in wrappers.items():
  path=out/('excitation-reference-'+name+'.c');path.write_text('#include "speex-excitation-test.h"\n'+''.join(f'#define {s} spxref_{s}\n' for s in symbols)+'#include '+json.dumps((source/'libspeex'/f'{name}.c').as_posix())+'\n'+''.join(f'#undef {s}\n' for s in symbols)+body+'\n',encoding='utf-8',newline='\n');sources=[path if p.name==name+'.c' else p for p in sources]
 names=['speex_packet','speex_excitation']
 if WINDOWS:objects=[out/'obj'/f'{name}.obj' for name in names]
 else:
  objects=[]
  for name in names:
   obj=out/(name+'.o');subprocess.run(['as','--64','-I',str(ROOT/'src'),'-o',str(obj),str(ROOT/'src'/f'{name}.s')],check=True);objects.append(obj)
 oracle=out/('speex-excitation-oracle.exe' if WINDOWS else 'speex-excitation-oracle')
 compile_c(oracle,[ROOT/'tests/speex-excitation-oracle.c',*sources],objects=objects,defines=['FLOATING_POINT','EXPORT='],includes=[*includes,ROOT/'tests'],libraries=[] if WINDOWS else ['-no-pie','-Wl,-z,noexecstack'])
 result=subprocess.run([str(oracle)],capture_output=True,text=True,timeout=180,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
 if result.returncode:raise RuntimeError(f'Speex excitation oracle failed ({result.returncode}):\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}')
 report=json.loads(result.stdout.strip().splitlines()[-1]);report.update({'platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'scope':'Pitch/gain decode for three books and forced recursion; eight additive split innovation books; seeded float noise. Real reference NB/WB/UWB codec calls including loss/recovery are mirrored through assembly. Complete Speex frame synthesis, comb/QMF/stereo/container/seek/player integration are not established. Native Mac execution is unverified.','reference':'Speex 1.2.1 floating-point, test-only wrappers of unmodified C source','archive_url':reference.URL,'archive_sha256':reference.SHA256,'oracle_sha256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['src/speex_packet.s','src/speex_packet.inc','src/speex_excitation.s','src/speex_excitation.inc','src/speex_excitation_tables.inc','src/lamp.inc','tests/speex-excitation-test.h','tests/speex-excitation-oracle.c','tests/build-speex-reference.py','tests/generate-speex-excitation-tables.py','tests/verify-speex-excitation.py']},'reference_wrappers':{name:hashlib.sha256((out/f'excitation-reference-{name}.c').read_bytes()).hexdigest() for name in wrappers}})
 target=out/'speex-excitation-verification.json';target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
