#!/usr/bin/env python3
"""Encoded enhanced coupling: literal-model PCM, boundaries, seeks and guards.

No production decoder dependency; the separate DSP suite uses direct cosine
IMDCT/DFT math. Full-stream interoperability normalization remains unverified.
Prepare on any host, then run hash-checked fixtures on x86 Linux or Windows.
"""
import array
import hashlib
import importlib.util
import json
import math
import os
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import ac3_model as ac3
import eac3_model as conventional
import eac3_ecpl_model as model
import eac3_vectors as vectors
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, decode_f32, exe,
    ffmpeg, ffmpeg_version, main_guard, out_dir, play, playback_requested, run, scratch,
    stereo_view, write_report, lamp_cli)
spec=importlib.util.spec_from_file_location('verify_ac3',Path(__file__).with_name('verify-ac3.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
SOURCES=('ac3_model.py','eac3_model.py','eac3_ecpl_model.py','ac3_vectors.py',
         'eac3_vectors.py','generate-eac3-ecpl-tables.py')


def pcm(data, zero_neighbors=False):
    channels, decoder=model.decode(data,zero_neighbors)
    count=len(channels)
    interleaved=array.array('f',[0])* (len(channels[0])*count)
    for ch,position in enumerate(base.CHANNEL_MAP[(decoder.acmod,decoder.lfe)]):
        interleaved[position::count]=array.array('f',channels[ch])
    mask=base.MASKS[decoder.acmod] | (8 if decoder.lfe else 0)
    return stereo_view(interleaved.tobytes(),count,mask),decoder


def set_bits(data, position, width, value):
    for i in range(width):
        at=position+i; mask=1<<(7-at%8)
        data[at//8]=(data[at//8]&~mask) | (((value>>(width-1-i))&1)*mask)


class Positions(ac3.Reader):
    def __init__(self,data):
        super().__init__(data,40); self.block=0; self.fields={}
    def mark(self,event,*context):
        if event=='block':self.block=context[0]
    def get(self,n,label=None,*context):
        if label=='ecplbegf':self.fields[self.block]=(self.pos,n)
        return super().get(n,label,*context)


def prepare(work):
    fixtures, coverage=[],set()
    def add(name,data,valid=True,**metadata):
        expected,decoder=pcm(data)
        if valid and 'block error' in decoder.used:raise Failure(name+': model parse failed')
        if not valid and name != 'bad-crc.ec3' and 'block error' not in decoder.used:raise Failure(name+': damaged model did not conceal')
        files={name:data,name+'.model.f32':expected}
        for filename,contents in files.items():(work/filename).write_bytes(contents)
        fixtures.append(dict(name=name,valid=valid,**metadata,
            files={k:hashlib.sha256(v).hexdigest() for k,v in files.items()}))
        coverage.update(decoder.used)
        print('Prepared '+name,flush=True)
    for code in range(16):
        data,_=vectors.stream(8800+code,frames=4,blocks=[1,2,3,6],acmod=2+code%6,
            lfe=code%2,fscod=code%3,typ=2 if code%3==0 else 0,ecplinu=1,
            coupling=1,cplstre=0,ecplbegf=code,ecplendf=15,ecpl_cycle=True,
            ecplbndstrce=code%2,ecplbndstrc=code%3==0,ecplangleintrp=code%2,
            ecpltrans=code%2,ecplparam1e=code%2,ecplparam2e=(code//2)%2,
            ecpl_channels=[2] if code%4==0 and code%6 else list(range(1,6)),
            short=.3,metadata=.5)
        add(f'begin-{code:02}.ec3',data)
    for name,options in (
        ('transitions.ec3',dict(ecplinu=[1,0,1,0,1,1],cplstre=1)),
        ('frame-transitions.ec3',dict(frames=8,ecpl_frames=[1,0,1,1,0,1],blocks=[1,2,3,6])),
        ('spx.ec3',dict(spxinu=1,spxbegf=4,spxendf=7,spxstrtf=0,spxcoe=1,
                      spxbndstrce=0)),
        ('aht.ec3',dict(ahte=1,ahtinu=1,cplstre=0,frmchexpstr=0,expstre=0)),
        ('aht-spx.ec3',dict(ahte=1,ahtinu=1,cplstre=0,frmchexpstr=0,expstre=0,
            spxinu=1,spxbegf=4,spxendf=7,spxstrtf=0,spxcoe=1,spxbndstrce=0)),
        ('single-band.ec3',dict(ecplbegf=15,ecplendf=15,ecplbndstrce=1,ecplbndstrc=1)),
        ('all-ranges.ec3',dict(ecplbegf=list(range(16)),ecplendf=15,frames=16)),
        ('seek.ec3',dict(frames=50,blocks=[1,1,1,3,6],dither=0,drc=0,
            blkswe=0,csnroffst=32,ecpl_signal=True,ecplchaos=0,ecpltrans=0,ecplamp=1,ecplparam1e=1,ecplparam2e=1)),
        ('noisy.ec3',dict(frames=12,blocks=1,ecpltrans=1,ecplchaos=7,ecplamp=1)),
    ):
        config=dict(frames=6,acmod=7,lfe=1,ecplinu=1,coupling=1,cplstre=0,ecplbegf=0,
                    ecplendf=15,ecpl_cycle=True,ecplparam1e=1,ecplparam2e=1)
        config.update(options)
        data,_=vectors.stream(8840+len(fixtures),**config)
        add(name,data)
    # Deliberately removing a valid next-frame carrier must change PCM.
    full=(work/'seek.ec3.model.f32').read_bytes()
    zero,_=pcm((work/'seek.ec3').read_bytes(),True)
    changes=sum(a!=b for a,b in zip(full,zero))
    if changes==0:raise Failure('zero-next negative control did not change PCM')
    frames=list(conventional.frames((work/'transitions.ec3').read_bytes()))
    # Every block failure has a valid CRC, including the next frame's block
    # zero. The whole-stream model sees that future block before synthesis.
    reader=Positions(frames[1]); decoder=model.Decoder(); decoder.frame(frames[0])
    decoder.decode_frame(reader,conventional.header(frames[1]),strict=True)
    for block in (0,2,4,5):
        if block not in reader.fields:continue
        damaged=bytearray(frames[1]);set_bits(damaged,*reader.fields[block],15)
        # This fixture has end 22; begin 20 is still valid. Force end 7 by
        # changing the following ecplendf to zero as well.
        start,width=reader.fields[block];set_bits(damaged,start+width,4,0)
        add(f'bad-block-{block}.ec3',frames[0]+vectors.recrc(damaged)+b''.join(frames[2:]),False)
    damaged=bytearray((work/'frame-transitions.ec3').read_bytes());damaged[4096+100]^=255
    add('bad-crc.ec3',damaged,False)
    add('truncated.ec3',(work/'frame-transitions.ec3').read_bytes()[:-7])
    required={f'ECPL begin {i}' for i in range(16)}|{f'ECPL amplitude {i}' for i in range(32)}| \
        {f'ECPL angle {i}' for i in range(64)}|{f'ECPL chaos {i}' for i in range(8)}| \
        {f'ECPL interpolation {i}' for i in range(2)}|{f'ECPL transient {i}' for i in range(2)}| \
        {'ECPL amplitude present 0','ECPL phase present 0','partial coupling','LUT exponents','per-block exponents'}
    if required-coverage:raise Failure('missing ECPL coverage: '+str(sorted(required-coverage)))
    manifest=dict(fixtures=fixtures,coverage=sorted(coverage),zero_next_changed_bytes=changes,
        specification_sha256=model.gen.base.SHA256,model_environment=dict(python=sys.version),
        model_sources={name:hashlib.sha256((ROOT/'tests'/name).read_bytes()).hexdigest() for name in SOURCES})
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


def validate(manifest,work):
    for name,digest in manifest['model_sources'].items():
        if hashlib.sha256((ROOT/'tests'/name).read_bytes()).hexdigest()!=digest:raise Failure('model source changed: '+name)
    for fixture in manifest['fixtures']:
        for name,digest in fixture['files'].items():
            if hashlib.sha256((work/name).read_bytes()).hexdigest()!=digest:raise Failure('fixture changed: '+name)


def main():
    work=scratch('eac3-ecpl')
    if '--wine-only' in sys.argv:return windows_checks(work)
    manifest=json.loads((work/'manifest.json').read_text()) if '--prepared' in sys.argv else prepare(work)
    validate(manifest,work)
    if '--prepare-only' in sys.argv:return
    library=build_lamp()
    build_oracles(out_dir(),{'seek-oracle':'seek-oracle.c','eac3-ecpl-packet-oracle':'eac3-ecpl-packet-oracle.c'},library)
    checks=[]
    for fixture in manifest['fixtures']:
        path=work/fixture['name']; output=Path(str(path)+'.f32')
        stats=decode_f32(path,output)
        expected=Path(str(path)+'.model.f32')
        peak,snr=base.compare(output,expected)
        if peak>1e-6*max(1,max(map(abs,base.floats(expected)))) or snr<130:raise Failure(path.name+f': model peak {peak}, SNR {snr}')
        checks.append(dict(test=path.name,result='matched literal full-stream model',
            byte_exact=output.read_bytes()==expected.read_bytes(),peak_error=peak,snr_db=None if math.isinf(snr) else snr,stats=stats))
        print('Verified '+path.name,flush=True)
    for raw in ('seek.ec3','frame-transitions.ec3','aht-spx.ec3'):
        for suffix,flags in [('mka',[]),('mp4',[]),('frag.mp4',['-movflags','frag_keyframe+empty_moov+delay_moov']),('ts',['-f','mpegts','-mpegts_flags','system_b'])]:
            path=work/(raw[:-4]+'.'+suffix);ffmpeg('-i',work/raw,'-c','copy',*flags,path)
            output=Path(str(path)+'.f32');decode_f32(path,output)
            if output.read_bytes()!=Path(str(work/raw)+'.f32').read_bytes():raise Failure(path.name+': container PCM differs')
            checks.append(dict(test=path.name,result='exact raw PCM'))
    for name in ('seek.ec3','seek.mka','seek.mp4','seek.frag.mp4','seek.ts'):
        result=json.loads(run([exe('seek-oracle'),work/name,work/'seek.ec3.f32','0']).splitlines()[-1])
        checks.append(dict(test=name+' seeks',result=result))
    for name in ('seek.ec3','noisy.ec3','aht-spx.ec3','bad-crc.ec3','bad-block-0.ec3'):
        result=json.loads(run([exe('eac3-ecpl-packet-oracle'),work/name]).splitlines()[-1])
        checks.append(dict(test=name+' guarded packets',result=result))
    # Noise is reset with the codec; compare to a fresh two-packet primer.
    frames=list(conventional.frames((work/'noisy.ec3').read_bytes()))
    for index in (3,7):
        path=work/f'primer-{index}.ec3';path.write_bytes(b''.join(frames[index-2:]))
        expected,_=pcm(path.read_bytes()); output=Path(str(path)+'.f32');decode_f32(path,output)
        model_path=Path(str(path)+'.model.f32');model_path.write_bytes(expected)
        peak,snr=base.compare(output,model_path)
        if snr<130:raise Failure('fresh ECPL primer model mismatch')
        ms=(index*256+48)//48; start=ms*48
        target=work/f'noisy.start-{ms}.f32';target.unlink(missing_ok=True)
        run([lamp_cli(),'--decode','--start',f'{ms/1000:.3f}',work/'noisy.ec3',target])
        if target.read_bytes()!=output.read_bytes()[(start-(index-2)*256)*8:]:raise Failure('noisy two-packet primer mismatch')
        checks.append(dict(test=f'noisy.ec3 --start {ms} ms',result='exact fresh two-packet primer PCM'))
    if playback_requested(sys.argv[1:]):checks.append(dict(test='ECPL playback',result='played',stats=play(work/'frame-transitions.ec3')))
    write_report('eac3-ecpl',dict(result='passed',checks=checks,coverage=manifest['coverage'],
        model_environment=manifest['model_environment'],specification_sha256=manifest['specification_sha256'],
        model_source_sha256=manifest['model_sources'],fixture_hashes={f['name']:f['files'] for f in manifest['fixtures']},
        packet_oracle_source_sha256=hashlib.sha256((ROOT/'tests/eac3-ecpl-packet-oracle.c').read_bytes()).hexdigest(),
        run_environment=dict(platform=platform.platform(),machine=platform.machine(),python=sys.version,ffmpeg=ffmpeg_version()),
        zero_next_changed_bytes=manifest['zero_next_changed_bytes'],
        scope='Literal ATSC E.3.5.5 model, ECPL independent/converted substream 0',
        limitations=['Encoded-stream interoperability normalization has no independent encoder/decoder validation',
                    'Non-normative ECPL random values are deterministic; noise seeks reset their history']))
    print(f'Passed {len(checks)} ECPL stream checks.',flush=True)


def windows_checks(work):
    manifest=json.loads((work/'manifest.json').read_text());validate(manifest,work)
    report=json.loads((out_dir()/'eac3-ecpl-verification.json').read_text())
    if report['result']!='passed':raise Failure('native ECPL suite must pass first')
    run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
    checks=[];env=dict(os.environ,WINEDEBUG=os.environ.get('WINEDEBUG','-all'))
    names=sorted({c['test'].split()[0] for c in report['checks']})
    for name in names:
        path=work/name;reference=Path(str(path)+'.f32')
        if not path.is_file() or not reference.is_file():continue
        starts=(None,17,60,150) if name.startswith('seek.') else (None,17,38) if name=='noisy.ec3' else (None,)
        for ms in starts:
            output=work/'windows.f32';output.unlink(missing_ok=True)
            args=['wine',str(ROOT/'bin/lamp-cli.exe'),'--decode']
            if ms is not None:args+=['--start',f'{ms/1000:.3f}']
            args += [str(path),str(output)]
            with tempfile.TemporaryFile() as log:
                result=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=120)
                if result.returncode:
                    log.seek(0);raise Failure(f'Wine {name}: exit {result.returncode}: {log.read()[-1024:]}')
            expected=(work/f'noisy.start-{ms}.f32').read_bytes() if name=='noisy.ec3' and ms is not None else reference.read_bytes()[(ms or 0)*48*8:]
            if output.read_bytes()!=expected:raise Failure(f'Wine {name} --start {ms}: PCM differs')
            checks.append(dict(test=name+(f' --start {ms} ms' if ms is not None else ''),result='exact Linux PCM'))
    objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
    libraries=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
    oracle=ROOT/'bin/eac3-ecpl-packet-oracle.exe'
    run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-ffp-contract=off','-municode','-I',ROOT/'tests',ROOT/'tests/eac3-ecpl-packet-oracle.c',*objects,*libraries,'-lm','-o',oracle],timeout=120)
    for name in ('seek.ec3','noisy.ec3','aht-spx.ec3','bad-crc.ec3','bad-block-0.ec3'):
        with tempfile.TemporaryFile() as log:
            result=subprocess.run(['wine',str(oracle),str(work/name)],stdout=log,stderr=subprocess.STDOUT,env=env,timeout=120)
            log.seek(0);output=log.read().decode('utf-8','replace')
        if result.returncode:raise Failure(f'Wine packet oracle {name}: {result.returncode}: {output[-1024:]}')
        checks.append(dict(test=name+' guarded packets',result=json.loads(output.splitlines()[-1])))
    write_report('eac3-ecpl-wine',dict(result='passed',checks=checks,wine_version=run(['wine','--version']),
        model_source_sha256=manifest['model_sources'],fixture_hashes=report['fixture_hashes'],
        packet_oracle_source_sha256=hashlib.sha256((ROOT/'tests/eac3-ecpl-packet-oracle.c').read_bytes()).hexdigest(),
        scope='Shipping PE vs native enhanced coupling PCM/starts and guarded packets'))
    print(f'Passed {len(checks)} Windows ECPL checks.',flush=True)


if __name__=='__main__':main_guard(main)
