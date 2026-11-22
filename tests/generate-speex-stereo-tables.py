#!/usr/bin/env python3
"""Mathematical Speex stereo balance lookup, avoiding runtime libm."""
import argparse
import math
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parent.parent
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');args=p.parse_args();values=[math.exp(sign*.25*q) for sign in (1,-1) for q in range(32)];lines=['# Generated mathematical float32 balances, exp(+/- .25 * q), q=0..31.','# tests/generate-speex-stereo-tables.py; BSD stereo.c reference in notices.','.p2align 4','spxs_balance:'];lines+=['    .long '+', '.join('0x%08x'%struct.unpack('<I',struct.pack('<f',v))[0] for v in values[i:i+4]) for i in range(0,64,4)];text='\n'.join(lines)+'\n';path=ROOT/'src/speex_stereo_tables.inc'
 if args.check:
  if not path.exists() or path.read_text()!=text:raise RuntimeError('Speex stereo gain tables need regeneration')
  print('Speex stereo mathematical balances match.')
 else:path.write_text(text,encoding='utf-8',newline='\n');print(path)
if __name__=='__main__':main()
