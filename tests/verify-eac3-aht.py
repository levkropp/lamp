#!/usr/bin/env python3
"""AHT whole-stream PCM, normative VQ vectors, GAQ, containers and reset seeks.

ATSC A/52:2018 Table E4.4 and ETSI E.3.4 contain a row omitted by stock
FFmpeg's VQ4 table. LAMP uses all normative rows. The independent model's
full-channel output is checked against FFmpeg with that sole table deviation
emulated, and assembly PCM is checked against normative model output.
Prepared binary references are hash checked for testing on another machine.
"""
import array
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import ac3_model
import eac3_model as model
import eac3_vectors as vectors
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg,
    ffmpeg_version, lamp_cli, main_guard, out_dir, play, playback_requested, run,
    scratch, stereo_view, write_report)
spec=importlib.util.spec_from_file_location('verify_eac3',Path(__file__).with_name('verify-eac3.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
EXCEPTION='Stock FFmpeg omits normative VQ4 row zero; compatibility comparator emulates only that omission'


def model_pcm(data, compatibility=False):
    channels,decoder=model.decode(data,ffmpeg_vq4=compatibility)
    order=base.ac3.CHANNEL_MAP[(decoder.acmod,decoder.lfe)]
    count=len(channels)
    samples=array.array('f',[0.0])*(len(channels[0])*count)
    for ch,values in enumerate(channels):
        samples[order[ch]::count]=array.array('f',values)
    mask=base.ac3.MASKS[decoder.acmod]|(8 if decoder.lfe else 0)
    return stereo_view(samples.tobytes(),count,mask),decoder.used


def check_pcm(actual,expected,label):
    peak,snr=base.ac3.compare(actual,expected)
    amplitude=max(map(abs,base.ac3.floats(expected)),default=0.0)
    if peak>1e-6*max(1.0,amplitude) or snr<130:
        raise Failure(f'{label}: peak {peak:.3g}, SNR {snr:.1f} dB')
    return dict(snr_db=None if math.isinf(snr) else round(snr,1),peak_error=peak)


def prepare(work):
    fixtures,checks,used=[],[],set()
    def add(name,seed,**options):
        path=work/name
        data,coverage=vectors.stream(seed,ahte=1,ahtinu=1,**options)
        path.write_bytes(data);used.update(coverage)
        used.update(base.model_check(path,checks,ffmpeg_vq4=True))
        files={name:data}
        for suffix,compat in [('.model.f32',False),('.compat.f32',True)]:
            pcm,coverage=model_pcm(data,compat);used.update(coverage)
            files[name+suffix]=pcm
        for filename,payload in files.items():(work/filename).write_bytes(payload)
        fixtures.append(dict(name=name,files={k:hashlib.sha256(v).hexdigest() for k,v in files.items()}))
        print('Prepared '+name,flush=True)
    for mode in range(4):
        add(f'gaq-{mode}.ec3',8200+mode,frames=256 if mode==0 else 16,acmod=2,lfe=1,coupling=0,
            gaqmod=mode,aht_vq_cycle=True,short=0.4)
    for acmod in range(8):
        for lfe in (0,1):
            add(f'layout-{acmod}-{lfe}.ec3',8250+acmod*2+lfe,frames=4,acmod=acmod,lfe=lfe,
                coupling=0 if acmod<2 else 1,cplstre=0,short=0.3,aht_vq_cycle=True)
    add('partial.ec3',8290,frames=6,acmod=7,lfe=1,aht_channels=[0,1,3,6],
        coupling=1,cplstre=0,short=0.3)
    add('lut.ec3',8291,frames=6,acmod=7,lfe=1,expstre=0,frmchexpstr=0,
        coupling=1,cplstre=0)
    add('spx.ec3',8292,frames=6,acmod=7,lfe=1,spxinu=1,spxstre=0,
        spxbegf=4,spxendf=7,spxstrtf=0,coupling=1,cplstre=0)
    add('clamped-groups.ec3',8293,frames=4,acmod=2,lfe=1,coupling=0,gaqmod=3,gaqgroup=31)
    add('converted.ec3',8294,frames=4,acmod=0,lfe=1,typ=2,coupling=0)
    for rate in (1,2):
        add(f'rate-{rate}.ec3',8294+rate,frames=4,acmod=7,lfe=1,fscod=rate,coupling=1,cplstre=0)
    # FFmpeg's MP4 muxer groups short sync frames into six-block samples.
    # Each 1/2/3-block sequence must finish before another six-block frame.
    add('transitions.ec3',8297,frames=15,acmod=2,lfe=1,blocks=[6,1,2,3,6],
        coupling=0,expstre=0,frmchexpstr=0,short=0.3)
    # All coded bins have HEBAP 19, so AHT's unconditional zero-bit noise
    # cannot make continuous PCM depend on the primer's LFG position.
    add('seek.ec3',8298,frames=48,acmod=2,lfe=1,coupling=0,chbwcod=0,
        csnroffst=63,snroffststr=0,bamode=0,drc=0,dither=0,short=0,metadata=0)
    add('noisy.ec3',8299,frames=12,acmod=2,lfe=1,coupling=0,drc=0,dither=0,short=0,metadata=0)
    for index in (3,7):
        frames=list(model.frames((work/'noisy.ec3').read_bytes()))
        name=f'noise-primer-{index}.ec3';data=b''.join(frames[index-1:]);path=work/name;path.write_bytes(data)
        used.update(base.model_check(path,checks,ffmpeg_vq4=True))
        files={name:data}
        for suffix,compat in [('.model.f32',False),('.compat.f32',True)]:
            files[name+suffix]=model_pcm(data,compat)[0]
        for filename,payload in files.items():(work/filename).write_bytes(payload)
        fixtures.append(dict(name=name,files={k:hashlib.sha256(v).hexdigest() for k,v in files.items()}))
    required={f'hebap {i}' for i in range(20)}|{f'GAQ mode {i}' for i in range(4)}| \
        {f'GAQ gain {i}' for i in range(3)}|{'AHT dither','GAQ small','GAQ clamped group',
            'GAQ large gain 1 negative','GAQ large gain 1 positive','GAQ large gain 2 negative',
            'GAQ large gain 2 positive','SPX active 1','coupling','short blocks','LUT exponents'}| \
        {f'AHT VQ {bap} index {i}' for bap in range(1,8) for i in range(1<<model.AHT_BITS[bap])}| \
        {f'AHT channel {ch}' for ch in range(7)}
    missing=required-used
    if missing:raise Failure('missing AHT coverage: '+', '.join(sorted(missing)))
    # Verify that exact seeking actually excludes all zero-bit AHT bins.
    _,seek_coverage=model_pcm((work/'seek.ec3').read_bytes())
    if 'AHT dither' in seek_coverage:raise Failure('exact seek fixture has AHT noise')
    manifest=dict(fixtures=fixtures,checks=checks,coverage=sorted(used),
        reference_exception=EXCEPTION,model_environment=dict(python=sys.version,ffmpeg=ffmpeg_version()))
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


def main():
    work=scratch('eac3-aht')
    if '--wine-only' in sys.argv:return windows_checks(work)
    manifest=json.loads((work/'manifest.json').read_text()) if '--prepared' in sys.argv else prepare(work)
    if '--prepare-only' in sys.argv:return
    library=build_lamp()
    build_oracles(out_dir(),{'seek-oracle':'seek-oracle.c','eac3-cap-oracle':'eac3-cap-oracle.c'},library)
    checks=copy.deepcopy(manifest['checks'])
    for fixture in manifest['fixtures']:
        for name,sha in fixture['files'].items():
            if hashlib.sha256((work/name).read_bytes()).hexdigest()!=sha:raise Failure('fixture changed: '+name)
        path=work/fixture['name'];h=model.header(path.read_bytes())
        pcm=Path(str(path)+'.f32');stats=decode_f32(path,pcm)
        checks.append(dict(test=path.name,result='matched normative model',stats=stats,
            **check_pcm(pcm,Path(str(path)+'.model.f32'),path.name)))
        reference=Path(str(path)+'.ffmpeg.f32')
        base.ac3.reference(path,reference,h['acmod'],h['lfe'])
        checks.append(dict(test='compat '+path.name,result='matched stock FFmpeg',
            **check_pcm(reference,Path(str(path)+'.compat.f32'),'stock FFmpeg '+path.name)))
        print('Verified '+path.name,flush=True)
    for raw in ('transitions.ec3','seek.ec3','spx.ec3'):
        for suffix,flags in [('mka',[]),('mp4',[]),('frag.mp4',['-movflags','frag_keyframe+empty_moov+delay_moov']),
                             ('ts',['-f','mpegts','-mpegts_flags','system_b'])]:
            path=work/(raw[:-4]+'.'+suffix)
            ffmpeg('-i',work/raw,'-c','copy',*flags,path)
            pcm=Path(str(path)+'.f32');decode_f32(path,pcm)
            if pcm.read_bytes()!=Path(str(work/raw)+'.f32').read_bytes():raise Failure(path.name+' container PCM')
            checks.append(dict(test=path.name,result='exact raw AHT PCM'))
    pcm=Path(str(work/'seek.ec3')+'.f32')
    for name in ('seek.ec3','seek.mka','seek.mp4','seek.frag.mp4','seek.ts'):
        line=run([exe('seek-oracle'),work/name,pcm,'0']).splitlines()[-1]
        checks.append(dict(test=name+' seeks',result=line))
    for index in (3,7):
        expected=Path(str(work/f'noise-primer-{index}.ec3')+'.f32').read_bytes()[(1536+480)*8:]
        ms=index*32+10;output=Path(str(work/'noisy.ec3')+f'.start-{ms}.f32');output.unlink(missing_ok=True)
        run([lamp_cli(),'--decode','--start',f'{ms/1000:.3f}',work/'noisy.ec3',output])
        if output.read_bytes()!=expected:raise Failure('AHT noise after reset/primer seek')
        checks.append(dict(test=f'noisy.ec3 --start {ms} ms',result='exact reset/primer PCM'))
    line=run([exe('eac3-cap-oracle'),work/'seek.ec3']).splitlines()[-1]
    checks.append(dict(test='AHT packet capacity',result=line))
    raw=(work/'transitions.ec3').read_bytes();damaged=bytearray(raw);damaged[100]^=255
    path=work/'bad-crc.ec3';path.write_bytes(damaged);pcm=Path(str(path)+'.f32');decode_f32(path,pcm)
    expected=Path(str(path)+'.model.f32');expected.write_bytes(model_pcm(damaged)[0])
    checks.append(dict(test=path.name,result='normative concealment',**check_pcm(pcm,expected,path.name)))
    path=work/'truncated.ec3';path.write_bytes(raw[:-7]);pcm=Path(str(path)+'.f32');decode_f32(path,pcm)
    last=model.header(list(model.frames(raw))[-1])['blocks']*256*8
    if pcm.read_bytes()!=Path(str(work/'transitions.ec3')+'.f32').read_bytes()[:-last]:raise Failure('AHT truncated tail')
    checks.append(dict(test=path.name,result='exact; incomplete last frame dropped'))
    if playback_requested(sys.argv[1:]):checks.append(dict(test='AHT playback',result='played',stats=play(work/'spx.ec3')))
    write_report('eac3-aht',dict(result='passed',checks=checks,coverage=manifest['coverage'],
        reference_exception=EXCEPTION,fixture_model_environment=manifest['model_environment'],
        scope='Six-block AHT, VQ, scalar/escape GAQ, FBW/coupling/LFE and spectral extension',
        limitations=['ECPL experimental normalization has separate validation; dependent/additional substreams remain unsupported',
            'AHT zero-bit bins always dither; noisy seeks restart the shared LFG']))
    print(f'Passed {len(checks)} AHT checks.',flush=True)


def windows_checks(work):
    report=json.loads((out_dir()/'eac3-aht-verification.json').read_text())
    if report['result']!='passed':raise Failure('native AHT suite must pass before Wine')
    run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
    env=dict(os.environ,WINEDEBUG=os.environ.get('WINEDEBUG','-all'));checks=[]
    for path in sorted(work.iterdir()):
        reference=Path(str(path)+'.f32')
        if path.suffix not in ('.ec3','.mka','.mp4','.ts') or not reference.exists():continue
        starts=(None,17,60,150) if path.name.startswith('seek.') else (None,106,234) if path.name=='noisy.ec3' else (None,)
        for start in starts:
            output=work/'windows.f32';output.unlink(missing_ok=True)
            command=['wine',str(ROOT/'bin/lamp-cli.exe'),'--decode']
            if start is not None:command+=['--start',f'{start/1000:.3f}']
            command += [str(path),str(output)]
            with tempfile.TemporaryFile() as log:
                result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=120)
                if result.returncode:
                    log.seek(0);raise Failure(f'Wine AHT {path.name}: exit {result.returncode}: {log.read()[-1024:]}')
            if start is None:expected=reference.read_bytes()
            elif path.name=='noisy.ec3':expected=Path(str(path)+f'.start-{start}.f32').read_bytes()
            else:expected=reference.read_bytes()[start*48*8:]
            if output.read_bytes()!=expected:raise Failure('Windows AHT '+path.name+' PCM differs')
            checks.append(dict(test=path.name+('' if start is None else f' --start {start} ms'),result='exact PCM'))
    write_report('eac3-aht-wine',dict(result='passed',checks=checks,scope='Shipping PE vs Linux AHT PCM and starts'))
    print(f'Passed {len(checks)} Windows AHT checks.',flush=True)


if __name__=='__main__':main_guard(main)
