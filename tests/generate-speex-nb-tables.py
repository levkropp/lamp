#!/usr/bin/env python3
"""Speex NB float gains: exp(q/3.5) and quantized voicing, q integer.

These mathematical lookup values avoid a runtime libm dependency. Decoder
tests compare every gain choice and resulting PCM with pinned Speex 1.2.1.
"""
import argparse
import math
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parent.parent
def bits(value):return struct.unpack('<I',struct.pack('<f',value))[0]
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
 lines=['# Generated mathematical float32 lookups; tests/generate-speex-nb-tables.py.','# Speex NB global gain = float(exp(q / 3.5)), q = 0..31.','.p2align 4','spxn_ol_gain:']
 lines+=['    .long '+', '.join('0x%08x'%bits(math.exp(q/3.5)) for q in range(i,i+4)) for i in range(0,32,4)]
 lines+=['# Quantized voicing = float(0.066667 * q), q = 0..15.','spxn_ol_coef:']
 lines+=['    .long '+', '.join('0x%08x'%bits(.066667*q) for q in range(i,i+4)) for i in range(0,16,4)]
 text='\n'.join(lines)+'\n';target=ROOT/'src/speex_nb_tables.inc'
 if args.check:
  if not target.exists() or target.read_text()!=text:raise RuntimeError('Speex NB gain tables need regeneration')
  print('Speex NB mathematical gain tables match.')
 else:target.write_text(text,encoding='utf-8',newline='\n');print(target)
if __name__=='__main__':main()
