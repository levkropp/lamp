#!/usr/bin/env python3
"""Link the guarded paired-frame test to the assembly decoder objects."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,compile_c,WINDOWS

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,default=ROOT/'build/wvc-check');args=parser.parse_args();out=args.bin.resolve()
 if WINDOWS:
  objects=[out/'obj'/f'{p.stem}.obj' for p in (ROOT/'src').glob('*.s')]+[out/'obj/platform.obj']
  libraries=list((out/'obj').glob('*.lib'));name='wavpack-pair-oracle.exe'
 else:
  objects=[p for p in (out/'obj').glob('*.o') if not p.name.startswith('linux_') or p.name=='linux_platform.o'];libraries=['-no-pie','-Wl,-z,noexecstack'];name='wavpack-pair-oracle'
 compile_c(out/name,[ROOT/'tests/wavpack-pair-oracle.c'],objects=objects,libraries=libraries)
 print(out/name)
if __name__=='__main__':main()
