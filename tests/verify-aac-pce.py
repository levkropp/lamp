#!/usr/bin/env python3
"""AAC PCE layouts: real encoders, tagged/reordered elements and containers."""
import array
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,Failure,build_lamp,build_oracles,decode_f32,exe,ffmpeg,main_guard,out_dir,run,scratch,write_report
import aac_pce_vectors as pce
import latm_vectors as latm
import sbr_vectors

SPEAKERS={'mono':[2],'stereo':[0,1],'3.0':[0,1,2],'4.0':[0,1,2,8],
          'quad':[0,1,4,5],'5.0':[0,1,2,4,5],'5.0(side)':[0,1,2,9,10],
          '5.1':[0,1,2,3,4,5],'5.1(side)':[0,1,2,3,9,10],
          '6.1':[0,1,2,3,8,9,10],'7.1':[0,1,2,3,4,5,9,10],
          '7.1(wide)':[0,1,2,3,4,5,6,7]}
R2=math.sqrt(.5);S3=math.sqrt(.75);C6=math.sqrt(.375)
WEIGHTS=[(1,0),(0,1),(R2,R2),(R2,R2),(S3,.5),(.5,S3),(R2,0),(0,R2),(C6,C6),(S3,.5),(.5,S3)]
SOURCES=['src/aac.s','src/aac_pce.inc','src/aac_sbr.inc','src/latm.s','tests/aac_pce_vectors.py',
         'tests/aac-pce-packet-oracle.c','tests/aac-pce-latm-oracle.c','tests/verify-aac-pce.py',
         'tests/verify-robustness.py']
SEEKS=('side-six-shuffled.m4a','side-six-shuffled.mka','side-six-shuffled.ts',
       'side-six-shuffled.aac','back-six-shuffled-v0.loas','eight-single-shuffled-v1.loas')
GUARDS=('stereo-tags-shuffled.packets','eight-single-shuffled.packets',
        'he-eight-single-shuffled.packets','ps-mono-ordered.packets','ps-back-mono-ordered.packets')


def negative_vectors(work):
    """Known syntax errors, unsupported topologies and midstream changes."""
    groups=([(1,15)],[],[],[])
    raw=sbr_vectors.raw_blocks((work/'core-stereo-tags-0.aac').read_bytes())
    good=pce.blocks([raw],groups,repeat=1)
    result=[]
    def save(name,data,error):
        path=work/name;path.write_bytes(data)
        result.append(dict(file=name,error=error,sha256=hashlib.sha256(data).hexdigest()))
    def packet(layout,**options):
        bits=pce.Bits();bits.put(5,3);pce.pce(bits,layout,**options);bits.put(7,3);return bits.data()
    for name,layout,options,error in (
        ('empty',([],[],[],[]),{},100),
        ('duplicate-single',([(0,0),(0,0)],[],[],[]),{},100),
        ('duplicate-pair',([(1,15),(1,15)],[],[],[]),{},100),
        ('rate-mismatch',groups,{'rate':4},100),
        ('main-profile',groups,{'object_type':0},101),
        ('coupling',groups,{'coupling':[(0,0)]},101),
        ('nine-channels',([(0,0),(1,0)],[(1,1)],[(0,1),(1,2)],[(3,0)]),{},101),
        ('six-front',([(1,0),(1,1),(1,2)],[],[],[]),{},101),
        ('four-back',([(1,0)],[],[(1,1),(1,2)],[]),{},101),
        ('lone-side',([(1,0)],[(0,0)],[],[]),{},101),
        ('four-side',([(1,0)],[(1,1),(1,2)],[],[]),{},101),
        ('two-lfs',([(1,0)],[],[],[(3,0),(3,1)]),{},101),
        ('unpaired-front-runs',([(0,0),(1,0),(0,1)],[],[],[]),{},101)):
        save('reject-'+name+'.aac',pce.adts_stream([packet(layout,**options)]*2),error)
        config=pce.asc(layout,**options)
        # Keep the ASC's rate correct while mismatching only the PCE's rate.
        if name=='rate-mismatch':config=bytes([0x11,0x80])+config[2:]
        save('reject-'+name+'.loas',latm.stream(good,(int.from_bytes(config,'big'),len(config)*8),version=1),error)
    for name,ids in (('unknown-tag',[14]),('duplicate-element',[15,15]),('missing-element',[])):
        bits=pce.Bits();bits.put(5,3);pce.pce(bits,groups)
        value,width=sbr_vectors.element(raw[0])
        for tag in ids:bits.put((value&((1<<(width-7))-1))|((16|tag)<<(width-7)),width)
        bits.put(7,3)
        save('reject-'+name+'.aac',pce.adts_stream([bits.data()]*2),100)
    changed=pce.blocks([raw],groups,repeat=1,tag=1)
    save('reject-program-change.aac',pce.adts_stream(good[:3]+changed[3:]),101)
    config=pce.asc(groups,comment=bytes(range(255)))
    save('reject-short-asc.loas',latm.stream(good,(int.from_bytes(config,'big'),len(config)*8),
         version=1,asc_length=len(config)*8-1),100)
    save('reject-large-asc.loas',latm.stream(good,(int.from_bytes(config,'big'),len(config)*8),
         version=1,asc_fill=4096),100)
    return result


def structural_checks(work,command,rejections,checks):
    def oracle(name,*args,timeout=300):
        return json.loads(run([*command(name),*args],timeout=timeout).splitlines()[-1])
    for case in rejections:
        result=oracle('chain-oracle','reject',work/case['file'])
        if result['decode_error']!=case['error']:raise Failure(case['file']+': '+str(result))
        checks.append(dict(test=case['file'],**result))
    for name in SEEKS:
        path=work/name
        result=oracle('seek-oracle',path,Path(str(path)+'.lamp.f32'),'0')
        checks.append(dict(test=name+' exact seeks',**result));print(name,'exact seeks',result['checks'],flush=True)
    for name in ('side-six-shuffled.aac','eight-single-shuffled-v1.loas'):
        for mode in ('cancel-open','cancel-read'):
            checks.append(dict(test=name+' '+mode,**oracle('chain-oracle',mode,work/name)))
    for name in GUARDS:
        result=oracle('aac-pce-packet-oracle',work/name)
        if result['result']!='passed':raise Failure(str(result))
        checks.append(dict(test=name,**result));print(name,result,flush=True)
    for name in ('stereo-tags-shuffled-v0.loas','eight-single-shuffled-v1.loas','ps-mono-ordered.loas'):
        result=oracle('aac-pce-latm-oracle',work/name)
        checks.append(dict(test=name+' protected parser',**result));print(name,result,flush=True)


def mutation_checks(work,command,checks,wine=False):
    spec=importlib.util.spec_from_file_location('pce_mutation',ROOT/'tests/verify-robustness.py')
    mutation=importlib.util.module_from_spec(spec);spec.loader.exec_module(mutation)
    rng=random.Random(20261015)
    for name in ('side-six-shuffled.aac','eight-single-shuffled-v1.loas','side-six-shuffled.ts','he-eight-single-shuffled.aac'):
        data=(work/name).read_bytes();counts={0:0,2:0};path=work/('mutation'+Path(name).suffix)
        for n in range(200):
            altered=mutation.mutate(data,rng)
            start=['--start',f'{rng.uniform(0,.3):.3f}'] if n%4==3 else []
            if wine and n%10:continue
            if wine and (n//10)%4==3:start=['--start',f'{(n*173%300)/1000:.3f}']
            path.write_bytes(altered)
            with tempfile.TemporaryFile() as log:
                result=subprocess.run([str(a) for a in [*command,'--check',*start,path]],
                    stdout=log,stderr=subprocess.STDOUT,timeout=30,
                    preexec_fn=mutation.limit_memory if not wine and mutation.resource else None)
                if result.returncode not in counts:
                    kept=work/f'crash-{name}-{n}.bin';kept.write_bytes(altered)
                    log.seek(0);raise Failure(f'{kept.name}: exit {result.returncode}: {log.read()[-1000:]}')
            counts[result.returncode]+=1
        checks.append(dict(test=name+' mutations',result='no crash or hang',mutations=sum(counts.values()),
                           decoded=counts[0],rejected_or_damaged=counts[2]))
        print(name,'mutations',counts,flush=True)


def reference(path,frames=None,known_layout=None):
    stream=json.loads(run(['ffprobe','-v','error','-select_streams','a:0','-show_entries','stream=channel_layout,channels','-of','json',path]))['streams'][0]
    layout=stream.get('channel_layout') or known_layout
    if layout not in SPEAKERS:raise Failure('Unmapped reference layout '+repr(layout))
    if stream['channels']!=len(SPEAKERS[layout]):raise Failure('Reference channel count differs from declared layout')
    target=Path(str(path)+'.reference.f32')
    ffmpeg('-cpuflags','0','-i',path,'-f','f32le',target)
    source=array.array('f',target.read_bytes());speakers=SPEAKERS[layout];channels=len(speakers)
    result=array.array('f')
    if channels==1:
        for value in source:result.extend((value,value))
    elif layout=='stereo':result=source
    else:
        weights=[WEIGHTS[b] for b in speakers]
        scale=(1 if channels<=4 else 2)/max(sum(w[0] for w in weights),sum(w[1] for w in weights))
        for at in range(0,len(source),channels):
            result.extend(sum(source[at+i]*w[side]*scale for i,w in enumerate(weights)) for side in (0,1))
    if frames is not None:
        if len(result)<frames*2:raise Failure('Reference shorter than presentation')
        result=result[:frames*2]
    target.write_bytes(result.tobytes())
    return target,layout


def compare(ours,reference):
    a=array.array('f',Path(ours).read_bytes());b=array.array('f',Path(reference).read_bytes())
    if len(a)!=len(b):raise Failure(f'{Path(ours).name}: {len(a)//2} != {len(b)//2} reference frames')
    error=sum((x-y)**2 for x,y in zip(a,b));power=sum(y*y for y in b)
    snr=999 if error==0 else 10*math.log10(power/error)
    peak=max((abs(x-y) for x,y in zip(a,b)),default=0)
    if peak>1e-6 and snr<120:raise Failure(f'{Path(ours).name}: peak={peak}, SNR={snr}')
    return dict(frames=len(a)//2,peak=peak,snr_db=snr)


def wine_checks():
    work=scratch('aac-pce');manifest=json.loads((work/'cases.json').read_text())
    prior=json.loads((out_dir()/'aac-pce-verification.json').read_text())
    sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in SOURCES}
    if prior['result']!='passed' or prior['sources']!=sources:raise Failure('Matching full native suite must pass first')
    for name,digest in manifest['hashes'].items():
        if hashlib.sha256((work/name).read_bytes()).hexdigest()!=digest:raise Failure('Fixture changed: '+name)
    run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
    objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in
             {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
    libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
    for name in ('chain-oracle','seek-oracle','aac-pce-packet-oracle','aac-pce-latm-oracle'):
        run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-municode',
             '-I',ROOT/'tests',ROOT/'tests'/(name+'.c'),*objects,*libs,'-lm','-o',ROOT/'bin'/(name+'.exe')])
    command=lambda name:['wine',ROOT/'bin'/(name+'.exe')]
    checks=[]
    for case in manifest['files']:
        output=work/(case['file']+'.wine.f32');output.unlink(missing_ok=True)
        run([*command('lamp-cli'),'--decode',work/case['file'],output],timeout=120)
        if hashlib.sha256(output.read_bytes()).hexdigest()!=case['pcm_sha256']:raise Failure('Windows PCM differs: '+case['file'])
        checks.append(dict(test=case['file'],result='byte-exact native PCM',frames=output.stat().st_size//8))
        print(case['file'],'Windows PCM exact',flush=True)
    structural_checks(work,command,manifest['rejections'],checks)
    mutation_checks(work,command('lamp-cli'),checks,wine=True)
    write_report('aac-pce-wine',dict(result='passed',checks=checks,sources=sources,
        cli_sha256=hashlib.sha256((ROOT/'bin/lamp-cli.exe').read_bytes()).hexdigest(),
        scope='Shipping Windows COFF objects under Wine; native Windows remains unverified.'))
    print('Passed',len(checks),'Windows AAC PCE checks',flush=True)


def main():
    if '--wine-only' in sys.argv:wine_checks();return
    spec=importlib.util.spec_from_file_location('aac_reference',ROOT/'tests/verify-aac.py')
    aac_reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(aac_reference)
    library=build_lamp()
    build_oracles(out_dir(),{'seek-oracle':'seek-oracle.c','chain-oracle':'chain-oracle.c'},library)
    work=scratch('aac-pce');checks=[];cases=[]
    def check(path,equivalent=None,**details):
        target=Path(str(path)+'.lamp.f32');decode_f32(path,target)
        if equivalent:
            ref,layout=equivalent,'stereo'
            if target.read_bytes()!=equivalent.read_bytes():raise Failure('Equivalent stream changed PCM: '+path.name)
        else:
            ref,layout=reference(path,13440 if path.suffix=='.m4a' and path.name.startswith('encoder-') else None,
                                 details.get('reference_layout') or details.get('encoder_layout'))
        metrics=compare(target,ref)
        row=dict(test=path.name,result='byte-exact equivalent PCM' if equivalent else 'matched FFmpeg',layout=layout,**metrics,**details)
        if equivalent:row['equivalent']=equivalent.name
        checks.append(row);cases.append(dict(file=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                           pcm=target.name,pcm_sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        print(path.name,layout,f'{metrics["snr_db"]:.1f} dB',flush=True)
        return target
    layouts=[] if '--written-only' in sys.argv else list(SPEAKERS)
    for n,layout in enumerate(layouts):
        channels=len(SPEAKERS[layout]);path=work/('encoder-'+layout.replace('(','-').replace(')','')+'.m4a')
        source='|'.join(f'0.04*sin(2*PI*{317+113*c}*t)' for c in range(channels))
        ffmpeg('-f','lavfi','-i',f'aevalsrc={source}:s=48000:d=0.28:c={layout}','-c:a','aac','-aac_pce','1',
               '-aac_pns','0','-b:a',str(64000*channels),'-flags','+bitexact',path)
        data=path.read_bytes();at=aac_reference.audio_specific_config(data)
        description=pce.describe_lc_asc(data[at:at+64])
        side_channels=sum(2 if kind==1 else 1 for kind,tag in description['groups'][1])
        if side_channels not in (0,2):
            # FFmpeg 5.1.9's forced-PCE encoder labels the input LFE as an
            # unpaired side SCE. Its decoder publishes no speaker layout.
            # Do not reinterpret a side speaker as LFE by its channel count.
            result=json.loads(run([exe('chain-oracle'),'reject',path]).splitlines()[-1])
            if result.get('decode_error')!=101:raise Failure('Unpositioned encoder side channel did not reject: '+str(result))
            checks.append(dict(test=path.name,result='unsupported side channel group',pce=description,encoder_layout=layout))
            continue
        check(path,kind='encoder PCE in AudioSpecificConfig',encoder_layout=layout)
        if layout in ('mono','stereo','5.1(side)','7.1'):
            for suffix,options in (('.aac',[]),('.mka',[]),('.loas',['-f','latm']),('.ts',['-mpegts_flags','latm'])):
                child=path.with_suffix(suffix)
                ffmpeg('-i',path,'-c:a','copy',*options,child)
                check(child,kind='container remux')
    groups_list=[('stereo-tags',([(1,15)],[],[],[])),
                 ('split-stereo',([(0,15),(0,0)],[],[],[])),
                 ('side-six',([(0,14),(1,15)],[(1,0)],[],[(3,15)])),
                 ('back-six',([(0,14),(1,15)],[],[(1,0)],[(3,15)])),
                 ('eight-single',([(0,15),(0,14),(0,13)],[(0,12),(0,11)],[(0,10),(0,9)],[(3,15)])),
                 ('seven',([(0,14),(1,15)],[(1,0)],[(0,0)],[(3,15)])),
                 ('wide-eight',([(0,14),(1,15),(1,0)],[],[(1,1)],[(3,15)]))]
    for label,groups in groups_list:
        cores=[]
        for n,(kind,tag) in enumerate(sum((list(g) for g in groups),[])):
            path=work/f'core-{label}-{n}.aac';channels=2 if kind==1 else 1
            source='|'.join(f'0.04*sin(2*PI*{271+n*157+c*83}*t)' for c in range(channels))
            ffmpeg('-f','lavfi','-i',f'aevalsrc={source}:s=48000:d=0.28','-ac',str(channels),'-c:a','aac','-aac_pns','0',
                   '-b:a',str(64000*channels),'-flags','+bitexact',path)
            cores.append(sbr_vectors.raw_blocks(path.read_bytes()))
        outputs=[]
        for shuffled in (False,True):
            packets=pce.blocks(cores,groups,reordered=shuffled,repeat=3,comment=bytes(range(255)),mixdowns=True,assoc=(0,15))
            config=pce.asc(groups,comment=bytes(range(255)),mixdowns=True,assoc=(0,15))
            stem=label+('-shuffled' if shuffled else '-ordered')
            path=work/(stem+'.aac');path.write_bytes(pce.adts_stream(packets));outputs.append(check(path,kind='tagged PCE elements'))
            (work/(stem+'.packets')).write_bytes(pce.packet_file(config,packets))
            for version in (0,1):
                path=work/(stem+f'-v{version}.loas')
                path.write_bytes(latm.stream(packets,(int.from_bytes(config,'big'),len(config)*8),version=version,interval=3))
                output=check(path,kind='written LATM with 255-byte PCE comment')
                if output.read_bytes()!=outputs[-1].read_bytes():raise Failure('LATM changed PCM '+path.name)
            if label=='side-six' and shuffled:
                source=work/(stem+'.aac')
                for suffix,options in (('.m4a',[]),('.mka',[]),('.ts',['-mpegts_flags','latm'])):
                    path=work/(stem+suffix)
                    ffmpeg('-i',source,'-c:a','copy',*options,path)
                    output=check(path,kind='valid six-channel PCE container remux')
                    if output.read_bytes()!=outputs[-1].read_bytes():raise Failure('Container remux changed PCM '+path.name)
        if outputs[0].read_bytes()!=outputs[1].read_bytes():raise Failure('Element permutation changed PCM '+label)
        checks.append(dict(test=label+' reordering',result='byte-exact PCM under per-frame element permutation'))
        if label=='stereo-tags':
            path=work/'leading-data-changing-comments.aac'
            path.write_bytes(pce.adts_stream(pce.blocks(cores,groups,repeat=1,leading=True,vary_comments=True)))
            output=check(path,equivalent=outputs[0],kind='leading data/fill before PCE and changing PCE comments')
            if output.read_bytes()!=outputs[0].read_bytes():raise Failure('Leading data or comments changed PCM')
    for label,groups,ps in (('he-split-stereo',([(0,15),(0,0)],[],[],[]),False),
                            ('he-side-six',groups_list[2][1],False),
                            ('he-eight-single',groups_list[4][1],False),
                            ('ps-mono',([(0,15)],[],[],[]),True),
                            ('ps-back-mono',([],[],[(0,15)],[]),True)):
        cores=[]
        for n,(kind,tag) in enumerate(sum((list(g) for g in groups),[])):
            core=work/f'core-{label}-{n}.aac';channels=2 if kind==1 else 1
            # Random SBR headers may cross over anywhere in the core band.
            # As in verify-heaac, use a full-band core so extreme HF limiter
            # gains do not magnify rounding noise from empty tonal bands.
            source=f'anoisesrc=r=24000:d=0.28:a=0.06:seed={331+n*137}'
            ffmpeg('-f','lavfi','-i',source,'-ac',str(channels),'-c:a','aac','-aac_pns','0',
                   '-b:a',str(96000*channels),'-cutoff','12000','-flags','+bitexact',core)
            raw=sbr_vectors.raw_blocks(core.read_bytes())
            if kind!=3:
                data,_=sbr_vectors.stream([raw],2 if kind==1 else 1,6,80+n,len(raw),steady=True,ps=ps)
                raw=sbr_vectors.raw_blocks(data)
            cores.append(raw)
        outputs=[]
        for shuffled in ((False,) if ps else (False,True)):
            stem=label+('-shuffled' if shuffled else '-ordered')
            packets=pce.blocks(cores,groups,rate=6,reordered=shuffled,repeat=3)
            config=pce.asc(groups,rate=6,sbr=True,ps=ps)
            path=work/(stem+'.aac');path.write_bytes(pce.adts_stream(packets,6))
            outputs.append(check(path,kind='tagged SBR/PS with stable element histories',reference_layout='stereo' if ps else None))
            (work/(stem+'.packets')).write_bytes(pce.packet_file(config,packets))
            path=work/(stem+'.loas');path.write_bytes(latm.stream(packets,(int.from_bytes(config,'big'),len(config)*8),version=1,interval=3))
            output=check(path,kind='explicit SBR/PS PCE in LATM ASC',reference_layout='stereo' if ps else None)
            if output.read_bytes()!=outputs[-1].read_bytes():raise Failure('Explicit PCE signalling changed HE-AAC PCM')
        if len(outputs)>1 and outputs[0].read_bytes()!=outputs[1].read_bytes():raise Failure('SBR element permutation changed PCM '+label)
        checks.append(dict(test=label+' identity',result='SBR/PS PCM retained through PCE signalling and element order'))
    rejections=negative_vectors(work)
    build_oracles(out_dir(),{n:n+'.c' for n in ('aac-pce-packet-oracle','aac-pce-latm-oracle')},library)
    structural_checks(work,lambda name:[exe(name)],rejections,checks)
    mutation_checks(work,[exe('lamp-cli')],checks)
    hashes={}
    for case in cases:hashes.update({case['file']:case['sha256'],case['pcm']:case['pcm_sha256']})
    hashes.update({c['file']:c['sha256'] for c in rejections})
    hashes.update({name:hashlib.sha256((work/name).read_bytes()).hexdigest() for name in GUARDS})
    subset='--written-only' in sys.argv
    if not subset:(work/'cases.json').write_text(json.dumps(dict(files=cases,rejections=rejections,hashes=hashes),indent=2)+'\n')
    write_report('aac-pce-written' if subset else 'aac-pce',dict(result='passed',checks=checks,
        cli_sha256=hashlib.sha256(exe('lamp-cli').read_bytes()).hexdigest(),
        ffmpeg=run(['ffmpeg','-version']).splitlines()[0],
        sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in SOURCES}))
    print('Passed',len(checks),'AAC PCE checks',flush=True)

if __name__=='__main__':main_guard(main)
