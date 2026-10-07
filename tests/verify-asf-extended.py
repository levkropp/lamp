#!/usr/bin/env python3
"""Embedded ASF Stream Properties: independent envelopes, exact audio/seeks,
guarded variable lists, quotas, metadata and actual FFmpeg demuxing.
--prepare-only pins fixtures; --wine-only repeats a matching native run;
--baseline-cli verifies the published pre-embedded-stream binary.
"""
import array
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import (ROOT,Failure,build_lamp,build_oracles,exe,ffmpeg,
                       ffmpeg_version,lamp_cli,main_guard,out_dir,run,scratch,stereo_view,write_report)

def module(name,filename):
    spec=importlib.util.spec_from_file_location(name,ROOT/'tests'/filename)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

spread=module('asf_spread','verify-asf-spread.py');writer=spread.writer;metadata=spread.metadata
chapters=spread.chapters
EXTENDED=writer.guid('14e6a5cb-c672-4332-8399-a96952065b5a')
PRIVATE=writer.guid('782f9c87-e21e-483c-9212-c84f2d1b9257')

def digest(data):return hashlib.sha256(data).hexdigest()

def name(text,language=0):
    text=text.encode('utf-16-le') if isinstance(text,str) else text
    return struct.pack('<HH',language,len(text))+text

def system(info=b'',size=0,key=PRIVATE):
    return key+struct.pack('<HI',size,len(info))+info

def extended(child=b'',ident=1,names=(),systems=(),name_count=None,system_count=None,tail=b''):
    fixed=struct.pack('<QQ8IHHQHH',0,0,192000,1000,0,192000,1000,0,0,2,ident,0,0,
                      len(names) if name_count is None else name_count,len(systems) if system_count is None else system_count)
    return writer.obj(EXTENDED,fixed+b''.join(names)+b''.join(systems)+child+tail)

def children(data):
    end=struct.unpack_from('<Q',data,16)[0];pos=30;result=[]
    while pos<end:
        size=struct.unpack_from('<Q',data,pos+16)[0];result.append(data[pos:pos+size]);pos+=size
    if pos!=end:raise Failure('Fixture header does not terminate')
    return end,result

def header(data,objects):
    end,_=children(data);body=b''.join(objects)
    result=bytearray(writer.HEADER+struct.pack('<QI',30+len(body),len(objects))+b'\x01\x02'+body+data[end:])
    pos=30
    for child in objects:
        if child[:16]==writer.FILE:struct.pack_into('<Q',result,pos+40,len(result))
        pos+=len(child)
    return bytes(result)

def embedded(data,*,names=(),systems=(),top=False,depth=1):
    _,objects=children(data);result=[]
    for child in objects:
        if child[:16]!=writer.STREAM:result.append(child);continue
        ident=struct.unpack_from('<H',child,72)[0]&127
        current=extended(child,ident,names,systems)
        if not top:
            for _ in range(depth):current=metadata.extension([current])
        result.append(current)
    return header(data,result)

def writer_hash():
    return digest(Path(__file__).read_bytes().split(b'def main():')[0]+
                  Path(spread.__file__).read_bytes().split(b'def main():')[0]+
                  Path(writer.__file__).read_bytes().split(b'def main():')[0]+
                  Path(metadata.__file__).read_bytes().split(b'def main():')[0]+
                  Path(chapters.__file__).read_bytes().split(b'def main():')[0])

def prepare(work):
    base=ROOT/'tests/generated/asf-spread';base.mkdir(parents=True,exist_ok=True)
    if not (base/'manifest.json').exists():spread.prepare(base)
    original=json.loads((base/'manifest.json').read_text())
    if original['writer_sha256']!=spread.writer_hash():raise Failure('Prepare ASF spreading fixtures again')
    for file,sha in original['hashes'].items():
        if digest((base/file).read_bytes())!=sha:raise Failure('Spreading fixture changed: '+file)
    cases=[];rejects=[];objects=[]
    names=[name('Main 漢字 🎵'),name('Other language',65535)]
    systems=[system(b'private description'),system(bytes(range(256)))]
    def add(label,data,reference,*,comparator=True,guards=False,note='',choice=None,count=None,selected=None):
        (work/label).write_bytes(data)
        raw=reference['raw'];(work/raw).write_bytes((base/raw).read_bytes())
        case=dict(reference,name=label,ffmpeg=comparator,note=note,guards=guards)
        for key,value in [('choice',choice),('count',count),('selected',selected)]:
            if value is not None:case[key]=value
        if comparator:
            ref=work/(label+'.ffmpeg.f32');decoder=['-c:a','mp2float'] if label.startswith('mp2') else []
            ffmpeg(*decoder,'-i',work/label,'-map',f'0:a:{case["selected"]-1}','-af','asetpts=N','-f','f32le',ref)
            ref.write_bytes(stereo_view(ref.read_bytes(),case['channels'],0))
        cases.append(case)
    for case in original['files']:
        data=embedded((base/case['name']).read_bytes(),names=names,systems=systems)
        add(case['name'],data,case,comparator=case['ffmpeg'],guards=case['name'] in ('aac.asf','legacy-zero-length.asf','multitrack-2.asf'),
            note='Stream Properties embedded after two counted names and two opaque payload-extension descriptions')
    base_case=next(c for c in original['files'] if c['name']=='legacy-zero-length.asf')
    data=(base/base_case['name']).read_bytes();_,parts=children(data);child=next(p for p in parts if p[:16]==writer.STREAM)
    def variant(label,extra,*,note='',top=False,depth=1,comparator=True,guards=False):
        current=extra
        if not top:
            for _ in range(depth):current=metadata.extension([current])
        replaced=[current if p[:16]==writer.STREAM else p for p in parts]
        add(label,header(data,replaced),base_case,comparator=comparator,guards=guards,note=note)
    variant('no-lists.asf',extended(child),guards=True)
    variant('top-level-wrapper.asf',extended(child,names=names),top=True,guards=True,note='Also accept an explicitly bounded top-level wrapper')
    variant('depth-four.asf',extended(child,names=names),depth=4,guards=True)
    variant('max-name.asf',extended(child,names=[name(b'A\0'*32767)]),guards=True)
    variant('large-info.asf',extended(child,systems=[system(bytes(70000))]),guards=True,
            note='Opaque system info uses a DWORD length, beyond WORD capacity')
    variant('empty-names.asf',extended(child,names=[name(''),name('')]),guards=True)
    variant('empty-system-info.asf',extended(child,systems=[system(),system()]),guards=True)
    # Extension descriptions also occur without an embedded stream, beside
    # the ordinary Stream Properties; they add no audio catalog entry.
    ordinary=(base/'span-one.asf').read_bytes();ordinary_case=next(c for c in original['files'] if c['name']=='span-one.asf')
    _,ordinary_parts=children(ordinary)
    add('standalone-plus-extension.asf',header(ordinary,[*ordinary_parts,metadata.extension([extended(names=names,systems=systems)])]),
        ordinary_case,guards=True)
    fmt,pcm=writer.wave_parts((base/base_case['raw']).read_bytes())
    for label,specs,replic in [('fixed-payload-extensions.asf',[system(b'first',3),system(b'second',2)],13),
                               ('variable-payload-extension.asf',[system(b'first',0),system(b'variable',65535)],10)]:
        packets=[writer.packet([writer.payload(pcm[i:i+128],k&255,replic=replic)]) for k,i in enumerate(range(0,len(pcm),128))]
        envelope=writer.asf([],packets,extra=[metadata.extension([extended(writer.stream(fmt),systems=specs)])])
        add(label,envelope,base_case,guards=True)
    # Placeholder formats establish 127 ordinals without claiming WMA decode.
    unavailable=bytearray(fmt);struct.pack_into('<H',unavailable,0,0xdead)
    catalog=[extended(writer.stream(bytes(unavailable),ident),ident) for ident in range(1,127)]
    catalog.append(extended(writer.stream(fmt,127),127,names=names))
    pkt=[writer.packet([writer.payload(pcm[i:i+128],k&255,stream=127)]) for k,i in enumerate(range(0,len(pcm),128))]
    high=writer.asf([],pkt,extra=[metadata.extension(catalog)])
    for choice in (0,127):add(f'catalog-127-{choice}.asf',high,base_case,comparator=False,choice=choice,count=127,selected=127)
    nochild=extended(names=[name('')]*65535)
    # A per-header quota, rather than one quota reset for each wrapper.
    quota_header=[metadata.extension([nochild,extended(names=[name('')])])]+parts
    add('quota-exact.asf',header(data,quota_header),base_case,comparator=False,note='65,536 list entries across two wrappers')
    unknown=writer.obj(bytes(16),b'')
    _,minimal=children(embedded(data))
    add('object-quota-exact.asf',header(data,[*minimal,*([unknown]*4091)]),base_case,comparator=False,
        note='Embedded Stream Properties consumes an object-budget entry: exactly 4,096 total')
    for label,record in [('basic',extended(child)),('lists',extended(child,names=names,systems=systems)),
                         ('max-name',extended(child,names=[name(b'A\0'*32767)])),
                         ('large-info',extended(child,systems=[system(bytes(70000))])),
                         ('many-names',extended(child,names=[name('')]*65535))]:
        file=label+'.object';(work/file).write_bytes(record);objects.append(file)
    def reject(label,record=None,*,envelope=None,error=100,choice=0):
        if envelope is None:
            envelope=header(data,[metadata.extension([record]) if p[:16]==writer.STREAM else p for p in parts])
        (work/label).write_bytes(envelope);rejects.append(dict(name=label,error=error,choice=choice))
    for label,record in [('short-fixed',writer.obj(EXTENDED,bytes(63))),('zero-id',extended(child,ident=0)),
        ('large-id',extended(child,ident=128)),('mismatched-id',extended(child,ident=2)),
        ('short-name',extended(child,names=[b'\0\0\x04\0AB'])),('odd-name',extended(child,names=[name(b'ABC')])),
        ('short-name-prefix',extended(child,names=[b'\0\0\0'])),
        ('name-count',extended(child,names=names,name_count=3)),
        ('short-system-prefix',extended(child,systems=[bytes(21)])),
        ('system-info-overrun',extended(child,systems=[PRIVATE+struct.pack('<HI',0,0xffffffff)])),
        ('system-count',extended(child,systems=systems,system_count=3)),
        ('bad-child-guid',extended(bytes(16)+child[16:])),('short-child',extended(child[:-1])),
        ('extra-child-byte',extended(child,tail=b'X')),('two-children',extended(child+child))]:
        reject(label+'.asf',record)
    reject('duplicate-stream-id.asf',envelope=header(data,[*parts,metadata.extension([extended(child)])]))
    reject('depth-five.asf',envelope=embedded(data,depth=5))
    reject('quota-exceeded.asf',envelope=header(data,[metadata.extension([nochild,extended(names=[name('')]*2)])]+parts),error=101)
    reject('single-quota-exceeded.asf',extended(child,names=[name('')]*65535,systems=[system(),system()]),error=101)
    reject('object-quota-exceeded.asf',envelope=header(data,[*minimal,*([unknown]*4092)]),error=101)
    reject('unavailable-embedded-track.asf',envelope=high,error=101,choice=1)
    # Sparse blueprint: a large unsigned DWORD opaque-info length stays
    # inside its Header Extension, with the embedded format after 4 GiB.
    gap=0xfffffd00;file_properties=bytearray(next(p for p in parts if p[:16]==writer.FILE))
    unknown_padding=writer.obj(bytes(16),bytes(1024));record_size=88+22+gap+len(child)
    ext_prefix=extended(ident=1,systems=[system()])[:88]
    ext_prefix=bytearray(ext_prefix);struct.pack_into('<Q',ext_prefix,16,record_size)
    extension_prefix=writer.EXT+struct.pack('<Q',46+record_size)+writer.NONE+struct.pack('<HI',6,record_size)
    prefix_length=30+len(file_properties)+len(unknown_padding)+len(extension_prefix)+88+22
    suffix=child+data[struct.unpack_from('<Q',data,16)[0]:]
    logical=prefix_length+gap+len(suffix);header_end=prefix_length+gap+len(child)
    struct.pack_into('<Q',file_properties,40,logical)
    prefix=writer.HEADER+struct.pack('<QI',header_end,3)+b'\x01\x02'+file_properties+unknown_padding+extension_prefix+ext_prefix
    prefix+=PRIVATE+struct.pack('<HI',0,gap)
    (work/'sparse-prefix.bin').write_bytes(prefix);(work/'sparse-suffix.bin').write_bytes(suffix)
    plan=dict(prefix='sparse-prefix.bin',suffix='sparse-suffix.bin',gap_bytes=gap,logical_bytes=logical,
              embedded_properties_offset=prefix_length+gap,raw=base_case['raw'],reference_case=base_case['name'])
    (work/'sparse-plan.json').write_text(json.dumps(plan,indent=2)+'\n')
    names_to_hash={c['name'] for c in cases}|{c['raw'] for c in cases}|{c['name']+'.ffmpeg.f32' for c in cases if c['ffmpeg']}|{c['name'] for c in rejects}|set(objects)|{'sparse-prefix.bin','sparse-suffix.bin','sparse-plan.json'}
    manifest=dict(files=cases,rejections=rejects,objects=objects,fixture_ffmpeg=ffmpeg_version(),writer_sha256=writer_hash(),
                  hashes={file:digest((work/file).read_bytes()) for file in sorted(names_to_hash)})
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Prepared {len(cases)} streams, {len(rejects)} rejected envelopes and {len(objects)} protected objects.',flush=True)

def main():
    work=scratch('asf-extended')
    if '--prepare-only' in sys.argv:prepare(work);return
    if not (work/'manifest.json').exists():prepare(work)
    manifest=json.loads((work/'manifest.json').read_text())
    if manifest['writer_sha256']!=writer_hash():raise Failure('Fixture writer changed; prepare again')
    for file,sha in manifest['hashes'].items():
        if digest((work/file).read_bytes())!=sha:raise Failure('Fixture changed: '+file)
    names={'asf-extended-oracle':'asf-extended-oracle.c','asf-seek-oracle':'asf-seek-oracle.c',
           'seek-oracle':'seek-oracle.c','chain-oracle':'chain-oracle.c','track-catalog-oracle':'track-catalog-oracle.c',
           'asf-boundary-oracle':'asf-boundary-oracle.c','asf-spread-oracle':'asf-spread-oracle.c'}
    wine='--wine-only' in sys.argv;env=dict(os.environ,WINEDEBUG='err+all') if wine else None
    if wine:
        prior=json.loads((out_dir()/'asf-extended-verification.json').read_text())
        if prior['result']!='passed' or prior['fixture_hashes']!=manifest['hashes']:raise Failure('Matching native run must pass first')
        run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
        objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
        libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
        for name_,source in names.items():run(['x86_64-w64-mingw32-gcc','-O2','-std=c11','-municode','-I',ROOT/'tests',ROOT/'tests'/source,*objects,*libs,'-lm','-o',ROOT/'bin'/(name_+'.exe')])
        cli=['wine',ROOT/'bin/lamp-cli.exe'];command=lambda name_:['wine',ROOT/'bin'/(name_+'.exe')]
    else:
        library=build_lamp();build_oracles(out_dir(),names,library)
        cli=[lamp_cli()];command=lambda name_:[exe(name_)]
    checks=[]
    def oracle(name_,*args,timeout=180):return json.loads(run([*command(name_),*args],env=env,timeout=timeout).splitlines()[-1])
    for case in manifest['files']:
        path=work/case['name'];ours=work/(path.name+'.'+('wine' if wine else 'native')+'.f32');reference=work/(path.name+'.reference.f32')
        ours.unlink(missing_ok=True);options=['--track',case['choice']] if case['choice'] else []
        run([*cli,*options,'--decode',path,ours],env=env,timeout=180);pcm=ours.read_bytes();stats=None
        if not wine:
            raw=work/'raw-output.f32';raw.unlink(missing_ok=True);run([*cli,'--decode',work/case['raw'],raw],timeout=180)
            if pcm!=raw.read_bytes():raise Failure(path.name+': raw stream differs')
            if case['ffmpeg']:
                other=(work/(path.name+'.ffmpeg.f32')).read_bytes()
                if len(pcm)!=len(other):raise Failure(path.name+': FFmpeg length differs')
                a,b=array.array('f',pcm),array.array('f',other);noise=sum((x-y)**2 for x,y in zip(a,b));signal=sum(y*y for y in b) or 1
                snr=999 if not noise else 10*math.log10(signal/noise);peak=max(abs(x-y) for x,y in zip(a,b))
                if path.name.startswith('adpcm_ima_wav'):
                    if peak>127/32768:raise Failure(path.name+': IMA peak differs')
                elif snr<(75 if path.name.startswith('aac') else 95):raise Failure(path.name+': FFmpeg SNR differs: '+str(snr))
                stats=dict(snr_db=snr,peak_error=peak)
            reference.write_bytes(pcm)
        if pcm!=reference.read_bytes():raise Failure(path.name+': verified native PCM differs')
        catalog=oracle('track-catalog-oracle',path,case['choice'],case['count'],case['selected'])
        cold=oracle('asf-seek-oracle',path,work/case['raw'],case['choice'])
        continuous=None if case['choice'] else oracle('seek-oracle',path,reference,0)
        guards=oracle('asf-boundary-oracle',path) if case['guards'] else None
        checks.append(dict(test=path.name,result='exact',frames=len(pcm)//8,pcm_sha256=digest(pcm),catalog=catalog,
                           cold_seeks=cold,continuous_seeks=continuous,protected_input=guards,ffmpeg=stats,note=case['note']))
        print(path.name+': PCM, catalog and seeks passed',flush=True)
    for case in manifest['rejections']:
        proof=oracle('chain-oracle','reject',work/case['name'],case['choice'])
        if proof['decode_error']!=case['error']:raise Failure(case['name']+': wrong error '+str(proof))
        checks.append(dict(test=case['name'],result=proof))
    plan=json.loads((work/'sparse-plan.json').read_text());sparse=work/'large-embedded-info.asf'
    prefix=(work/plan['prefix']).read_bytes();suffix=(work/plan['suffix']).read_bytes()
    with sparse.open('wb') as file:
        file.write(prefix);file.seek(len(prefix)+plan['gap_bytes']);file.write(suffix)
    if sparse.stat().st_size!=plan['logical_bytes'] or sparse.stat().st_blocks*512>1024*1024:
        raise Failure('Large embedded fixture is not the intended sparse file')
    sparse_output=work/'sparse-output.f32';sparse_output.unlink(missing_ok=True)
    run([*cli,'--decode',sparse,sparse_output],env=env,timeout=180)
    if sparse_output.read_bytes()!=(work/(plan['reference_case']+'.reference.f32')).read_bytes():raise Failure('Sparse embedded PCM differs')
    sparse_seeks=oracle('asf-seek-oracle',sparse,work/plan['raw'],0)
    checks.append(dict(test='unsigned DWORD info skip with embedded format after 4 GiB',result='exact',
                       logical_bytes=sparse.stat().st_size,allocated_bytes=sparse.stat().st_blocks*512,
                       embedded_properties_offset=plan['embedded_properties_offset'],info_length=plan['gap_bytes'],
                       cold_seeks=sparse_seeks,pcm_sha256=digest(sparse_output.read_bytes())))
    sparse.unlink()
    for file in manifest['objects']:
        proof=oracle('asf-extended-oracle',work/file,120 if wine else 1200,timeout=300)
        checks.append(dict(test=file+' protected lists and mutations',result=proof))
    for file in ('legacy-zero-length.asf','aac.asf'):
        checks.append(dict(test=file+' guarded full-envelope mutations',result=oracle('asf-spread-oracle','mutate',work/file,120 if wine else 1200)))
        for mode in ('cancel-open','cancel-read'):checks.append(dict(test=file+' '+mode,result=oracle('chain-oracle',mode,work/file)))
    path=work/'metadata-chapters.asf'
    if '\n'.join(run([*cli,'--tags',path],env=env).splitlines())!='title=Spread 漢字\nartist=LAMP Test':raise Failure('Embedded stream changed tags')
    if '\n'.join(run([*cli,'--chapters',path],env=env).splitlines())!='00:00:00.000 Start\n00:00:00.125 Part':raise Failure('Embedded stream changed chapters')
    checks.append(dict(test='embedded stream tags and chapters',result='exact'))
    robustness=module('robustness','verify-robustness.py');rng=random.Random(9731);mutation=work/'mutated-decoder.asf'
    for file in ('legacy-zero-length.asf','aac.asf','fixed-payload-extensions.asf'):
        data=(work/file).read_bytes();decoded=rejected=seeks=0
        for i in range(50 if wine else 500):
            mutation.write_bytes(robustness.mutate(data,rng));seek=['--start',f'{rng.random()*0.4:.6f}'] if i%4==0 else []
            args=[str(a) for a in [*cli,'--check',*seek,mutation]]
            if wine:result=robustness.wine_run(args,env=env,timeout=30)
            else:result=subprocess.run(args,env=env,timeout=30,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,preexec_fn=robustness.limit_memory if robustness.resource else None)
            if result.returncode not in (0,2):raise Failure(file+f': mutation {i} exited {result.returncode}: '+str(result.stdout[-1024:]))
            decoded+=result.returncode==0;rejected+=result.returncode==2;seeks+=bool(seek)
        checks.append(dict(test=file+' full decoder mutations',result='no crash, hang or runaway allocation',mutations=decoded+rejected,
                           decoded=decoded,rejected=rejected,seeks=seeks,seed=9731,address_space_limit_bytes=None if wine or not robustness.resource else robustness.LIMIT))
        print(file+': full decoder mutations passed',flush=True)
    if '--baseline-cli' in sys.argv:
        baseline=Path(sys.argv[sys.argv.index('--baseline-cli')+1]).resolve();published_path=ROOT/'reports/asf-spread-verification.json'
        published=json.loads(published_path.read_text())
        if digest(baseline.read_bytes())!=published['cli_sha256']:raise Failure('Baseline differs from published spreading report')
        for file in ('legacy-zero-length.asf','aac.asf','multitrack-0.asf'):
            result=subprocess.run([str(baseline),'--check',str(work/file)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode!=2:raise Failure('Published binary unexpectedly reads embedded streams')
            checks.append(dict(test=file+' published negative control',result='rejected before, exact PCM after',
                               baseline_commit='00c21b52be8ff6a34d462179b88698d229390129',baseline_cli_sha256=digest(baseline.read_bytes()),baseline_report_sha256=digest(published_path.read_bytes())))
    sources=['src/asf.s','src/asf_extended.inc','src/asf_spread.inc','src/avi.s','src/decoder.s','src/track.s','src/mpegts.s',
             'tests/verify-asf-extended.py','tests/asf-extended-oracle.c','tests/asf-boundary-oracle.c','tests/asf-spread-oracle.c',
             'tests/asf-seek-oracle.c','tests/seek-oracle.c','tests/chain-oracle.c','tests/track-catalog-oracle.c',
             'tests/verify-asf-spread.py','tests/verify-asf.py','tests/verify-asf-metadata.py','tests/verify-asf-chapters.py','tests/verify-robustness.py']
    write_report('asf-extended-wine' if wine else 'asf-extended',dict(result='passed',checks=checks,
                 fixture_hashes=manifest['hashes'],fixture_ffmpeg=manifest['fixture_ffmpeg'],runtime_platform=platform.platform(),
                 runtime_sources={file:digest((ROOT/file).read_bytes()) for file in sources},cli_sha256=digest(Path(cli[-1]).read_bytes()),
                 oracle_sha256={file:digest(Path(command(file)[-1]).read_bytes()) for file in names},
                 reference_hashes={c['name']:digest((work/(c['name']+'.reference.f32')).read_bytes()) for c in manifest['files']}))
    print(f'Passed {len(checks)} checks.',flush=True)

if __name__=='__main__':main_guard(main)
