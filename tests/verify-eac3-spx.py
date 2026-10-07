#!/usr/bin/env python3
"""E-AC-3 spectral extension: whole-stream PCM against two independent paths.

Default prepares model-written fixtures, checks their full-channel PCM with
FFmpeg, then verifies the assembly decoder, containers, seeks and playback.
--prepare-only/--prepared permit expensive Python generation on another host;
the latter checks every fixture's SHA-256 before testing it. --wine-only uses
a completed native report to compare shipping PE PCM and start positions.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import ac3_model
import eac3_model as model
import eac3_vectors as vectors
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg,
                       ffmpeg_version, main_guard, out_dir, play, playback_requested,
                       run, scratch, write_report)

spec=importlib.util.spec_from_file_location('verify_eac3',Path(__file__).with_name('verify-eac3.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)


def prepare(work):
    checks, used, fixtures = [], set(), []
    def add(name, seed, **options):
        path=work/name
        data,coverage=vectors.stream(seed,**options)
        path.write_bytes(data)
        used.update(coverage)
        used.update(base.model_check(path,checks))
        fixtures.append({'name':name,'sha256':hashlib.sha256(data).hexdigest()})
        print('Prepared '+name,flush=True)
    for code in range(32):
        mode=code%8
        begin=code%8
        sub=begin+2 if begin<6 else 2*begin-3
        ends=[i for i in range(8) if (i+5 if i<3 else 2*i+3)>sub]
        add(f'fields-{code:02}.ec3',8100+code,frames=4,acmod=mode,lfe=(code//8)%2,
            blocks=[1,2,3,6],spxinu=1,spxbegf=begin,spxendf=ends[code%len(ends)],
            spxstrtf=min(code%4,sub-1),spxblnd=code,spxattencode=1,spxattencod=code,
            coupling=0 if mode<2 else 0.8,
            spx_channels=list(range(1,ac3_model.CHANNELS[mode]+1)) if code%2 else [1],
            short=0.3,spxbndstrce=code%2,spxbndstrc=code%3==0,spxcoe=code%2)
    add('transitions.ec3',8190,frames=6,acmod=7,lfe=1,spxinu=[1,0,1,1,0,1],
        spxbegf=4,spxendf=7,spxstrtf=0,cplstre=1,coupling=1,short=0.4)
    add('lut.ec3',8191,frames=32,acmod=7,lfe=1,expstre=0,frmchexpstr=list(range(32)),
        spxinu=1,spxbegf=4,spxendf=7,spxstrtf=0,spxbndstrce=0,coupling=1)
    add('wide-wrap.ec3',8192,frames=4,acmod=2,spxinu=1,spxbegf=0,spxendf=7,
        spxstrtf=1,spxbndstrce=1,spxbndstrc=1,spxcoe=1,coupling=0,spxattencod=31,
        spxattencode=1)
    add('converted.ec3',8193,frames=4,acmod=0,lfe=1,typ=2,spxinu=1,
        spxbegf=4,spxendf=7,spxstrtf=2,coupling=0,short=0.4)
    add('noisy.ec3',8196,frames=12,acmod=7,lfe=1,spxinu=1,spxbegf=4,spxendf=7,
        spxstrtf=0,spxbndstrce=0,spxcoe=1,spxblnd=0,spxcoexp=2,spxcomant=3,
        mstrspxco=0,dither=0,drc=0,short=0,cplstre=0,coupling=1,metadata=0)
    for rate in (1,2):
        add(f'rate-{rate}.ec3',8194+rate,frames=4,acmod=7,lfe=1,fscod=rate,
            spxinu=1,spxbegf=7,spxendf=7,spxstrtf=3,coupling=1,spxcoe=1)
    # Nonzero translated signal, zero noise ratio in every band: the final
    # band is wide enough that its midpoint/end lies below blend 31/32.
    # The LFG still advances; continuous and independently primed seeks agree.
    add('seek.ec3',8197,frames=48,acmod=7,lfe=1,blocks=[1,2,3,6],
        spxinu=1,spxbegf=4,spxendf=7,spxstrtf=0,spxbndstrce=1,spxbndstrc=1,
        spxblnd=31,spxcoe=1,spxcoexp=2,spxcomant=3,mstrspxco=0,dither=0,
        short=0,drc=0,coupling=1,metadata=0)
    # CRC-valid invalid SPX strategy fields must conceal, without indexing
    # coefficient or band arrays outside their fixed bounds.
    for name,beg,end,copycode in [('bad-range.ec3',7,0,0),('bad-copy.ec3',0,7,3)]:
        h=dict(acmod=2,lfe=0,bsid=16,bytes=1024,fscod=0,blocks=6,typ=0,shift=0)
        writer=vectors.Writer(random.Random(8198),dict(acmod=2,lfe=0,bsid=16,
            metadata=0,addbsi=0,expstre=1,snroffststr=0,spxinu=1,spxbegf=beg,
            spxendf=end,spxstrtf=copycode),20,True)
        try:model.Decoder().decode_frame(writer,h,strict=True)
        except ac3_model.DecodeError as error:
            if str(error)!='invalid SPX range':raise
        else:raise Failure('invalid SPX strategy accepted by model')
        # Give FFmpeg a valid packet to establish its output format before
        # the damaged block. A solely invalid first packet has rate 0 in
        # FFmpeg 5.1 and cannot reach its PCM export path.
        path=work/name;path.write_bytes((work/'fields-02.ec3').read_bytes()+vectors.assemble(h,writer.bits))
        fixtures.append({'name':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    required={f'SPX attenuation {n}' for n in range(32)}|{f'SPX blend {n}' for n in range(32)}| \
             {f'SPX exponent {n}' for n in range(16)}|{f'SPX mantissa {n}' for n in range(4)}| \
             {f'SPX master {n}' for n in range(4)}|{'SPX all channels','SPX partial channels',
             'SPX active 0','SPX active 1','SPX explicit bands','SPX default/reused bands',
             'SPX coordinate reuse','LUT exponents','per-block exponents','short blocks','coupling'}
    missing=required-used
    if missing:raise Failure('missing SPX coverage: '+', '.join(sorted(missing)))
    manifest=dict(fixtures=fixtures,checks=checks,coverage=sorted(used),
                  model_environment=dict(python=sys.version,ffmpeg=ffmpeg_version()))
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


def main():
    work=scratch('eac3-spx')
    if '--wine-only' in sys.argv:
        return windows_checks(work)
    manifest=json.loads((work/'manifest.json').read_text()) if '--prepared' in sys.argv else prepare(work)
    if '--prepare-only' in sys.argv:return
    library=build_lamp()
    build_oracles(out_dir(),{'seek-oracle':'seek-oracle.c','eac3-cap-oracle':'eac3-cap-oracle.c'},library)
    checks=copy.deepcopy(manifest['checks'])
    for fixture in manifest['fixtures']:
        path=work/fixture['name']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=fixture['sha256']:
            raise Failure('prepared fixture changed: '+path.name)
        base.against(path,checks)
    pcm=Path(str(work/'seek.ec3')+'.f32')
    if not max(map(abs,base.ac3.floats(pcm))):raise Failure('seek fixture is silent')
    for raw in ('transitions.ec3','seek.ec3'):
        for suffix,flags in [('mka',[]),('mp4',[]),('frag.mp4',['-movflags','frag_keyframe+empty_moov+delay_moov']),
                             ('ts',['-f','mpegts','-mpegts_flags','system_b'])]:
            path=work/(raw[:-4]+'.'+suffix)
            ffmpeg('-i',work/raw,'-c','copy',*flags,path)
            out=Path(str(path)+'.f32');decode_f32(path,out)
            if out.read_bytes()!=Path(str(work/raw)+'.f32').read_bytes():raise Failure(path.name+' container PCM')
            checks.append({'test':path.name,'result':'exact','comparator':'raw SPX PCM'})
    for name in ('seek.ec3','seek.mka','seek.mp4','seek.frag.mp4','seek.ts'):
        line=run([exe('seek-oracle'),work/name,pcm,'0']).splitlines()[-1]
        checks.append({'test':name+' seeks','result':line})
    # Noisy seeks are compared to a fresh reference starting at the exact
    # primer frame, rather than to a different continuous LFG position.
    frames=list(model.frames((work/'noisy.ec3').read_bytes()))
    from lamp_test import lamp_cli
    for index in (3,7):
        chunk=work/f'noise-primer-{index}.ec3';chunk.write_bytes(b''.join(frames[index-1:]))
        expected=base.against(chunk,checks).read_bytes()[(1536+480)*8:]
        ms=index*32+10
        output=Path(str(work/'noisy.ec3')+f'.start-{ms}.f32')
        output.unlink(missing_ok=True)
        run([lamp_cli(),'--decode','--start',f'{ms/1000:.3f}',work/'noisy.ec3',output])
        if output.read_bytes()!=expected:raise Failure('SPX noise after reset/primer seek')
        checks.append({'test':f'noisy.ec3 --start {ms} ms','result':'exact reset/primer PCM',
                       'comparator':f'FFmpeg-checked fresh decode from primer frame {index-1}'})
    line=run([exe('eac3-cap-oracle'),work/'seek.ec3']).splitlines()[-1]
    checks.append({'test':'SPX packet capacity','result':line})
    raw=(work/'transitions.ec3').read_bytes()
    damaged=bytearray(raw);damaged[100]^=0xff
    path=work/'bad-crc.ec3';path.write_bytes(damaged);base.against(path,checks,crc=True)
    path=work/'truncated.ec3';path.write_bytes(raw[:-7]);decode_f32(path,Path(str(path)+'.f32'))
    expected=Path(str(work/'transitions.ec3')+'.f32').read_bytes()[:-6*256*8]
    if Path(str(path)+'.f32').read_bytes()!=expected:raise Failure('truncated SPX final frame')
    checks.append({'test':path.name,'result':'exact','note':'last incomplete sync frame dropped'})
    if playback_requested(sys.argv[1:]):checks.append({'test':'SPX playback','result':'played','stats':play(work/'transitions.ec3')})
    write_report('eac3-spx',dict(result='passed',checks=checks,coverage=manifest['coverage'],
        fixture_model_environment=manifest['model_environment'],
        scope='Spectral extension in conventional independent/converted E-AC-3 substream 0',
        limitations=['enhanced coupling, dependent/additional substreams and reduced rates remain unsupported',
                     'noisy SPX seeks restart the shared LFG; exact seeks use nonzero signal with zero noise blend']))
    print(f'Passed {len(checks)} E-AC-3 SPX checks.',flush=True)


def windows_checks(work):
    report=json.loads((out_dir()/'eac3-spx-verification.json').read_text())
    if report['result']!='passed':raise Failure('native SPX suite must pass before Wine')
    run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
    env=dict(os.environ,WINEDEBUG=os.environ.get('WINEDEBUG','-all'))
    checks=[]
    names=sorted({c['test'].split()[0] for c in report['checks']})
    for name in names:
        path=work/name
        if path.suffix not in ('.ec3','.mka','.mp4','.ts') or not path.is_file():continue
        reference=Path(str(path)+'.f32')
        if not reference.exists():continue
        starts=(None,17,60,150) if name.startswith('seek.') else (None,106,234) if name=='noisy.ec3' else (None,)
        for start in starts:
            output=work/'windows.f32';output.unlink(missing_ok=True)
            command=['wine',str(ROOT/'bin/lamp-cli.exe'),'--decode']
            if start is not None:command+=['--start',f'{start/1000:.3f}']
            command += [str(path),str(output)]
            with tempfile.TemporaryFile() as log:
                result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=120)
                if result.returncode:
                    log.seek(0);raise Failure(f'Wine SPX {name}: exit {result.returncode}: {log.read()[-1024:]}')
            if start is None:expected=reference.read_bytes()
            elif name=='noisy.ec3':expected=Path(str(path)+f'.start-{start}.f32').read_bytes()
            else:expected=reference.read_bytes()[start*48*8:]
            if output.read_bytes()!=expected:raise Failure('Windows SPX '+name+' PCM differs')
            checks.append({'test':name+('' if start is None else f' --start {start} ms'),'result':'exact PCM'})
    write_report('eac3-spx-wine',dict(result='passed',checks=checks,
        scope='Shipping Windows CLI under Wine vs Linux SPX PCM and millisecond starts'))
    print(f'Passed {len(checks)} Windows SPX checks.',flush=True)


if __name__=='__main__':main_guard(main)
