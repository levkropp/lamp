#!/usr/bin/env python3
"""Native queue window callbacks, lifecycle and bounded virtual rows under Wine."""
import hashlib,json,os,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,Failure,main_guard,out_dir,run,write_report
import importlib.util

def main():
    spec=importlib.util.spec_from_file_location('windows_build',ROOT/'tools/build-windows.py')
    builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
    run([sys.executable,ROOT/'tools/build-windows.py','--tests'],capture=False)
    out_dir().mkdir(parents=True,exist_ok=True)
    probe=out_dir()/'ui-queue-view-probe.obj'
    run([builder.tool('llvm-mc'),'-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1',
         '-I',ROOT/'src','-I',ROOT/'src/win',ROOT/'tests/ui-queue-view-probe.s','-o',probe])
    objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in
             {'ui','engine-probe','ui-preview','ui-list','ui-driver'}]
    libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
    target=ROOT/'bin/ui-queue-view-oracle.exe'
    run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-Wall','-Wextra','-Werror','-municode','-DUNICODE','-D_UNICODE',
         '-I',ROOT/'tests',ROOT/'tests/ui-queue-view-oracle.c',probe,*objects,*libs,'-lm','-o',target])
    result=run(['wine',target],timeout=120)
    checked=json.loads(result.splitlines()[-1])
    if checked['result']!='passed':raise Failure(result)
    sources=['src/win/ui.s','src/win/ui_queue.inc','src/win/ui_queue_view.inc','src/win/ui_menu.inc',
             'src/win/ui_draw.inc','src/win/kernel32.def','tests/ui-queue-view-oracle.c',
             'tests/ui-queue-view-probe.s','tests/verify-queue-view.py']
    write_report('queue-view',dict(result='passed',checks=[checked],
        sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
        oracle_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
        scope='Shipping UI source with test-only aliases: guarded Unicode callback buffers, filename search, stale/pending list selection rejection, pause and track preservation, real native virtual list control with 65,536 rows, replacement, reopen and Escape through the shipping message loop. Wine; native Windows remains unverified.'))
    print('Queue view oracle:',checked,flush=True)

if __name__=='__main__':main_guard(main)
