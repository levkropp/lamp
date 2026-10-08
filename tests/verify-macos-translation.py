#!/usr/bin/env python3
"""Native semantic checks for ARM64 translation used by the current decoders."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from arm64_lamp import Source,Translator


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary-directory',type=Path,default=ROOT/'build/macos')
    args=p.parse_args();out=args.binary_directory.resolve()
    if sys.platform!='darwin' or platform.machine()!='arm64':p.error('native Apple Silicon required')
    source=ROOT/'tests/mac-translation-probe.s'
    unit=Source([str(ROOT/'src')],{});unit.run(str(source))
    assembly=out/'translation-probe.s'
    assembly.write_text(Translator(unit,str(source)).run()+'''
.include "mac.inc"
FN _mac_translation_probe
    ENTER
    mov x3, x0
    mov x2, x1
    GOT x9, _lamp_stack_top
    ldr x28, [x9]
    sub x28, x28, #32
    XCALL mac_translation_probe
    LEAVE
    ret
''')
    init=out/'translation-init.c'
    init.write_text('extern int lamp_init(void); __attribute__((constructor)) static void init(void) {if (!lamp_init()) __builtin_trap();}\n')
    target=out/'translation-oracle'
    subprocess.run(['xcrun','clang','-arch','arm64','-O2','-ffp-contract=off',
                    '-I',str(ROOT/'tests'),'-I',str(ROOT/'src/mac'),str(assembly),
                    str(ROOT/'tests/mac-translation-oracle.c'),str(init),
                    str(out/'liblamp-test.dylib'),'-o',str(target)],check=True)
    result=subprocess.run([target],capture_output=True,text=True,check=True,timeout=30)
    report=json.loads(result.stdout)
    report.update(platform=platform.platform(),oracle_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                  scope='Packed multiply/add wrap, 32/64-bit nearest/truncated double conversion including NaN/overflow, '
                        'borrow arithmetic and flags, LOOP flag preservation, exact GNU data layout')
    (out/'macos-translation-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
