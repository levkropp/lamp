#!/usr/bin/env python3
"""ECPL DSP vs direct primary-specification math; not bitstream conformance.

Reference C uses direct 512-sample IMDCT/DFT, independent of the player's
DCT-IV/FFT. Prepared inputs and references are SHA-256 checked on any host.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, compile_c, exe, main_guard,
                       out_dir, run, scratch, write_report)

EDGES = [13,19,25,31,37,49,61,73,85,97,109,121,133,145,157,169,181,193,205,217,229,241,253]
NORMALIZATION = ('Literal ATSC E.3.5.5.1: windowed IMDCT steps 1-5, overlap without '
                 'factor 2, DFT divided by 512; unit-amplitude zero-phase identity gain is 0.5')


def prepare(work):
    rng = random.Random(85262026)
    rows, checks = [], []

    def add(name, edges=EDGES, flags=0, amp=None, angle=None, chaos=None, spectra=None,
            noise=None, count=None):
        bands=len(edges)-1
        a=amp if amp is not None else [rng.randrange(32) for _ in range(bands)]
        p=angle if angle is not None else [rng.randrange(64) for _ in range(bands)]
        h=chaos if chaos is not None else [rng.randrange(8) for _ in range(bands)]
        if spectra is None:
            spectra=[[rng.uniform(-.02,.02) if left<=k<right else 0 for k in range(256)]
                     for left,right in [(13,253),(edges[0],edges[-1]),(25,193)]]
        if noise is None:
            noise=[rng.uniform(-1,1) for _ in range(256)]
            if flags&2:
                for left,right in zip(edges,edges[1:]):
                    noise[left:right]=[rng.uniform(-1,1)]*(right-left)
        coordinates=struct.pack('<II23i22B22B22B2x', bands if count is None else count, flags,
            *(list(edges)+[0]*(23-len(edges))), *(a+[0]*(22-len(a))),
            *(p+[0]*(22-len(p))), *(h+[0]*(22-len(h))))
        initial=[rng.uniform(-.2,.2) for _ in range(256)]
        rows.append(struct.pack('<768f',*(v for block in spectra for v in block)) + coordinates +
                    struct.pack('<256f',*noise)+struct.pack('<256f',*initial))
        checks.append(dict(test=name, bands=bands, flags=flags))

    zero=[0.0]*256
    add('zero carrier',spectra=[zero,zero,zero])
    add('literal half-gain identity',amp=[0]*22,angle=[0]*22,chaos=[0]*22)
    for block in range(3):
        for bin in (13,25,37,61,121,252):
            spectra=[zero.copy() for _ in range(3)]; spectra[block][bin]=.01
            add(f'isolated block {block} bin {bin}',spectra=spectra,amp=[0]*22,angle=[0]*22,chaos=[0]*22)
    for flags in range(8):
        add(f'flags {flags}',flags=flags)
        add(f'single band flags {flags}',edges=[13,253],flags=flags)
        add(f'merged bands flags {flags}',edges=[13,37,61,121,253],flags=flags)
    for amp in range(32):
        add(f'amplitude {amp}',edges=[13,253],amp=[amp],angle=[0],chaos=[0])
    for phase in range(64):
        add(f'phase {phase}',edges=[13,253],amp=[0],angle=[phase],chaos=[0])
    for chaos in range(8):
        for transient in (0,2):
            add(f'chaos {chaos} transient {bool(transient)}',edges=[13,61,253],flags=transient|4,
                amp=[0,0],angle=[31,32],chaos=[chaos,chaos])
    for angles in ([31,32],[32,31],[0,32],[32,0],[63,1],[1,63]):
        for edges in ([13,19,253],[13,241,253],[13,14,253],[13,252,253],[13,14,15],[13,20,27]):
            add(f'interpolation {angles} edges {edges}',edges=edges,flags=4,
                amp=[0,0],angle=angles,chaos=[0,0])
    for i in range(32):
        selected=[EDGES[0]]+[v for v in EDGES[1:-1] if rng.getrandbits(1)]+[EDGES[-1]]
        add(f'random merged {i}',edges=selected,flags=rng.randrange(8))
    for code in (-1,0,23,0xffffffff):
        add(f'invalid band count {code}',edges=[13,253],count=code&0xffffffff)
    for flags in (8,0xffffffff): add(f'invalid flags {flags}',edges=[13,253],flags=flags)
    for edges in ([12,253],[13,13],[13,254],[13,0],[13,253,200]):
        add(f'invalid edges {edges}',edges=edges,spectra=[zero,zero,zero])
    for field,options in [('amp',dict(amp=[32])),('angle',dict(angle=[64])),('chaos',dict(chaos=[8]))]:
        add('invalid '+field,edges=[13,253],**options)
    input=work/'cases.bin'; expected=work/'reference.bin'
    input.write_bytes(struct.pack('<I',len(rows))+b''.join(rows))
    reference=compile_c(work/'direct-reference',[ROOT/'tests/eac3-ecpl-oracle.c'],defines=['ECPL_REFERENCE'],fp='strict')
    run([reference,input,expected],timeout=120)
    manifest=dict(checks=checks,normalization=NORMALIZATION,
        files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (input,expected)},
        reference='Direct C cosine sums and DFT, ATSC A/52:2018 E.3.5.5',
        reference_source_sha256=hashlib.sha256((ROOT/'tests/eac3-ecpl-oracle.c').read_bytes()).hexdigest(),
        specification_sha256='4580b631f5ac1aafdd31034f28d5fc9c29bce72a3d3f6367e3d9746906e0ffa1',
        model_environment=dict(python=sys.version,architecture=os.uname().machine if hasattr(os,'uname') else 'Windows'))
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


def main():
    work=scratch('eac3-ecpl-dsp')
    manifest=json.loads((work/'manifest.json').read_text()) if '--prepared' in sys.argv or '--wine-only' in sys.argv else prepare(work)
    if '--prepare-only' in sys.argv: return
    if hashlib.sha256((ROOT/'tests/eac3-ecpl-oracle.c').read_bytes()).hexdigest()!=manifest['reference_source_sha256']:
        raise Failure('direct reference source changed; prepare the fixtures again')
    for name,digest in manifest['files'].items():
        if hashlib.sha256((work/name).read_bytes()).hexdigest()!=digest: raise Failure('changed '+name)
    if '--wine-only' in sys.argv: return windows_checks(work,manifest)
    library=build_lamp()
    compile_c(exe('eac3-ecpl-oracle'),[ROOT/'tests/eac3-ecpl-oracle.c'],objects=[library],fp='strict')
    result=json.loads(run([exe('eac3-ecpl-oracle'),work/'cases.bin',work/'reference.bin'],timeout=120))
    if result['cases']!=len(manifest['checks']): raise Failure('incomplete cases')
    report=dict(result='passed',checks=copy.deepcopy(manifest['checks']),metrics=result,
        normalization=manifest['normalization'],reference=manifest['reference'],
        reference_source_sha256=manifest['reference_source_sha256'],specification_sha256=manifest['specification_sha256'],
        reference_environment=manifest['model_environment'],fixture_hashes=manifest['files'],
        scope='ECPL carrier and channel DSP only; guarded inputs/outputs; all numeric codes and interpolation boundaries',
        limitations=['This kernel suite does not validate bitstream parsing or cross-frame lookahead',
                     'Random arrays are supplied by the test; decoder RNG lifetime is not tested'])
    write_report('eac3-ecpl-dsp',report)
    print(f"Passed {result['cases']} enhanced-coupling DSP cases: {result}",flush=True)


def windows_checks(work,manifest):
    # The test executable links the shipping COFF ac3 object with CRT test
    # helpers only. LAMP itself keeps its existing imports and no C runtime.
    run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
    out=ROOT/'bin'
    # Link all shared/platform objects to satisfy the decoder's existing graph.
    objects=sorted((out/'obj').glob('*.obj'))
    objects=[p for p in objects if p.stem not in {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
    # platform.obj exports start; the CRT also defines startup, with another
    # name. The oracle uses wmain and never calls the player's start.
    libraries=sorted((out/'obj').glob('*.lib'))
    libraries=[p for p in libraries if p.name!='lamp-test.lib']
    oracle=out/'eac3-ecpl-oracle.exe'
    run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-ffp-contract=off',
         '-municode','-I',ROOT/'tests',ROOT/'tests/eac3-ecpl-oracle.c',*objects,*libraries,'-lm','-o',oracle],timeout=120)
    env=dict(os.environ,WINEDEBUG=os.environ.get('WINEDEBUG','-all'))
    with tempfile.TemporaryFile() as log:
        result=subprocess.run(['wine',str(oracle),str(work/'cases.bin'),str(work/'reference.bin')],
                              stdout=log,stderr=subprocess.STDOUT,env=env,timeout=120)
        log.seek(0); text=log.read().decode('utf-8','replace')
    if result.returncode: raise Failure(f'Wine oracle exited {result.returncode}: {text[-2000:]}')
    metrics=json.loads(text.splitlines()[-1])
    if metrics['cases']!=len(manifest['checks']): raise Failure('incomplete Wine cases')
    write_report('eac3-ecpl-dsp-wine',dict(result='passed',metrics=metrics,
        checks=manifest['checks'],normalization=manifest['normalization'],fixture_hashes=manifest['files'],
        reference_source_sha256=manifest['reference_source_sha256'],specification_sha256=manifest['specification_sha256'],
        scope='Shipping COFF ECPL DSP vs direct C reference under Wine; not bitstream acceptance'))
    print(f"Passed {metrics['cases']} Windows enhanced-coupling DSP cases.",flush=True)


if __name__=='__main__': main_guard(main)
