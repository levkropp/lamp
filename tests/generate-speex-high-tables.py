#!/usr/bin/env python3
"""Pinned BSD Speex synthesis coefficients and mathematical high-band gains."""
import argparse
import importlib.util
import math
from pathlib import Path
import re
import struct
ROOT=Path(__file__).resolve().parent.parent
def f32(v):return struct.unpack('<f',struct.pack('<f',v))[0]
def words(values):return ['    .long '+', '.join('0x%08x'%struct.unpack('<I',struct.pack('<f',v))[0] for v in values[i:i+4]) for i in range(0,len(values),4)]
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
 spec=importlib.util.spec_from_file_location('speex_reference',ROOT/'tests/build-speex-reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);source,_,_=ref.prepare();text=(source/'libspeex/sb_celp.c').read_text()
 h0=re.findall(r'static const float h0\[64\]\s*=\s*\{([^}]+)\}',text)[0];h0=[float(x.strip().rstrip('f')) for x in h0.split(',') if x.strip()]
 gc=re.findall(r'static const spx_word16_t gc_quant_bound\[16\]\s*=\s*\{([^}]+)\}',text)[-1];gc=[float(x.strip()) for x in gc.split(',') if x.strip()];assert len(h0)==64 and len(gc)==16
 lines=['# Generated from pinned BSD Speex 1.2.1 sb_celp.c; see THIRD_PARTY_NOTICES.','# tests/generate-speex-high-tables.py. No reference C is runtime-linked.','.p2align 4','spxh_qmf_h0:',*words(h0),'# float(exp(.125f * (q - 10))), q=0..31.','spxh_fold_gain:',*words([math.exp(.125*(q-10)) for q in range(32)]),'# float(.87360 * float(gc_quant_bound[q])), q=0..15.','spxh_code_gain:',*words([.87360*f32(x) for x in gc])]
 result='\n'.join(lines)+'\n';path=ROOT/'src/speex_high_tables.inc'
 if args.check:
  if not path.exists() or path.read_text()!=result:raise RuntimeError('Speex high-band tables need regeneration')
  print('Speex QMF coefficients and high-band gains match pinned reference.')
 else:path.write_text(result,encoding='utf-8',newline='\n');print(path)
if __name__=='__main__':main()
