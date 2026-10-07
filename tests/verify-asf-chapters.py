#!/usr/bin/env python3
"""ASF Marker Objects: independent serialization, FFmpeg, guarded reads,
heard-file navigation and unchanged metadata/PCM. --prepare-only creates
hash-pinned fixtures; --wine-only checks shipping COFF after a native run.
--baseline-cli PATH verifies the published pre-chapter binary's absence.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg,
                       ffmpeg_version, lamp_cli, main_guard, out_dir, run,
                       scratch, write_report)

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tests' / filename)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result

metadata = module('asf_metadata', 'verify-asf-metadata.py')
chapters = module('chapter_reader', 'verify-chapters.py')
navigation = module('chapter_navigation', 'verify-chapter-navigation.py')
writer = metadata.writer
MARKER = writer.guid('f487cd01-a951-11cf-8ee6-00c00c205365')
RESERVED = writer.guid('4cfedb20-75f6-11cf-9c0f-00a0c90349cb')

def digest(data): return hashlib.sha256(data).hexdigest()

def entry(time, text='', *, entry_length=None, units=None, offset=0, send=0, flags=0):
    text = metadata.utf16(text) if isinstance(text, str) else text
    return struct.pack('<QQHIII', offset, time, 12 + len(text) if entry_length is None else entry_length,
                       send, flags, len(text) // 2 if units is None else units) + text

def markers(entries, *, name='', count=None, extra=b''):
    name = metadata.utf16(name) if name else b''
    return writer.obj(MARKER, RESERVED + struct.pack('<IHH', len(entries) if count is None else count, 0, len(name)) +
                      name + b''.join(entries) + extra)

def header_children(data):
    end = struct.unpack_from('<Q', data, 16)[0]; pos, children = 30, []
    while pos < end:
        size = struct.unpack_from('<Q', data, pos + 16)[0]
        children.append(data[pos:pos + size]); pos += size
    return end, children

def insert(data, extra, preroll=None, before_properties=False):
    end, children = header_children(data)
    if preroll is not None:
        for i, child in enumerate(children):
            if child[:16] == writer.FILE:
                child = bytearray(child); struct.pack_into('<Q', child, 80, preroll); children[i] = bytes(child)
    children = [*extra, *children] if before_properties else [*children, *extra]
    body = b''.join(children); prefix = writer.HEADER + struct.pack('<QI', 30 + len(body), len(children)) + b'\x01\x02'
    result = bytearray(prefix + body + data[end:]); pos = 30
    for child in children:
        if child[:16] == writer.FILE: struct.pack_into('<Q', result, pos + 40, len(result))
        pos += len(child)
    return bytes(result)

def envelope(extra, preroll=0, before_properties=False):
    return insert(metadata.file([metadata.basic('Marker test', 'Ärtist')]), extra, preroll, before_properties)

def isolated(extra, preroll=0):
    _, children = header_children(envelope([], preroll))
    body = b''.join([next(c for c in children if c[:16] == writer.FILE), *extra])
    return writer.HEADER + struct.pack('<QI', len(body) + 30, len(extra) + 1) + b'\x01\x02' + body

def stored_title(text):
    data = text.encode('utf-8').split(b'\0')[0][:1024]
    return data.decode('utf-8', 'ignore')

def writer_hash():
    return digest(Path(__file__).read_bytes().split(b'def main():')[0] +
                  Path(metadata.__file__).read_bytes().split(b'def main():')[0] +
                  Path(writer.__file__).read_bytes().split(b'def main():')[0])

def prepare(work):
    cases = []
    def add(name, data, expected, *, probe=False, guards=False, audio=True, note=''):
        path = work / name; path.write_bytes(data)
        cases.append(dict(name=name, chapters=[[ns, stored_title(text)] for ns, text in expected],
                          ffprobe=probe, guards=guards, audio=audio, note=note))
    items = [(0, 'Opening'), (12500000, 'Part 漢字 🎵'), (32500000, ''), (65000000, 'Café')]
    records = [entry(t, text) for t, text in items]
    add('basic.asf', envelope([markers(records)]), [(t*100, s) for t, s in items], probe=True, guards=True)
    add('Unicode markers Ü.asf', envelope([markers(records, name='Markers 漢字')]),
        [(t*100, s) for t, s in items], probe=True)
    ordered = [(65000000, 'Later'), (0, 'Start'), (32500000, 'Middle'), (12500000, 'Early'), (32500000, 'Same')]
    add('unordered-duplicate.asf', envelope([markers([entry(t, s) for t, s in ordered])]),
        [(t*100, s) for t, s in ordered], probe=True)
    ticks = [0, 1, 9999, 10000, 123456789]
    add('fractional-ticks.asf', envelope([markers([entry(t, str(t)) for t in ticks])]),
        [(t*100, str(t)) for t in ticks], probe=True)
    preroll = 3100
    add('preroll-before.asf', envelope([markers([entry(t+preroll*10000, s) for t, s in items])], preroll),
        [(t*100, s) for t, s in items], probe=True, guards=True)
    add('preroll-after.asf', envelope([markers([entry(t+preroll*10000, s) for t, s in items])], preroll, True),
        [(t*100, s) for t, s in items], note='Marker precedes File Properties; timing is header-order independent')
    add('negative-times.asf', envelope([markers([entry(preroll*10000-1, 'Before'), entry(preroll*10000, 'Zero'),
                                               entry(preroll*10000+1, 'After')])], preroll),
        [(0, 'Zero'), (100, 'After')], note='Before-preroll marker cannot be represented on the nonnegative playback timeline')
    maximum = (2**64-1)//100
    add('time-overflow.asf', envelope([markers([entry(maximum, 'Largest'), entry(maximum+1, 'Overflow'),
                                              entry(2**64-1, 'Unsigned'), entry(1, 'Small')])]),
        [(maximum*100, 'Largest'), (100, 'Small')], guards=True)
    add('preroll-overflow.asf', envelope([markers(records)], 2**64-1), [], guards=True)
    add('zero-markers.asf', envelope([markers([])]), [], probe=True, guards=True)
    add('unterminated.asf', envelope([markers([entry(0, 'No terminator'.encode('utf-16-le')), entry(1, b'')])]),
        [(0, 'No terminator'), (100, '')], probe=True, guards=True)
    add('embedded-nul.asf', envelope([markers([entry(0, metadata.utf16('Prefix')+metadata.utf16('Hidden')), entry(1, 'Next')])]),
        [(0, 'Prefix'), (100, 'Next')])
    for name, text, want in [('high-surrogate', b'A\0\x00\xd8B\0', 'A'),
                             ('low-surrogate', b'A\0\x00\xdcB\0', 'A'),
                             ('surrogate-at-end', b'A\0\x00\xd8', 'A')]:
        add(name+'.asf', envelope([markers([entry(0, text), entry(1, 'Next')])]), [(0, want), (100, 'Next')], guards=True)
    title = 'A'*1023 + '🎵' + 'Z'*100
    add('utf8-title-boundary.asf', envelope([markers([entry(0, title), entry(1, 'Next')])]),
        [(0, title), (100, 'Next')])
    title = '漢'*1500
    add('long-title-cursor.asf', envelope([markers([entry(0, title), entry(1, 'Next')])]),
        [(0, title), (100, 'Next')])
    add('maximum-description.asf',envelope([markers([entry(0,'A'*32760),entry(1,'Next')])]),[(0,'A'*1024),(100,'Next')])
    add('maximum-object-name.asf',envelope([markers(records,name='N'*32766)]),[(t*100,s) for t,s in items])
    large = [entry(i, 'T'*1024) for i in range(1025)]
    add('chapter-title-capacity.asf', envelope([markers(large)]),
        [(i*100, 'T'*1024 if i<256 else '') for i in range(1024)])
    add('chapter-capacity.asf', envelope([markers([entry(i) for i in range(1025)])]),
        [(i*100, '') for i in range(1024)])
    add('negative-before-capacity.asf', envelope([markers([entry(0)]*1024+[entry(10001,'After')])], 1), [(100,'After')])
    add('record-budget.asf', envelope([markers([entry(i, b'') for i in range(65536)])]),
        [(i*100, '') for i in range(1024)])
    add('record-over-budget.asf', envelope([markers([entry(i, b'') for i in range(65537)])]), [])
    add('independent-record-budget.asf', envelope([metadata.descriptors([metadata.descriptor('Ignored','x')]*65535),
                                                  markers([entry(0), entry(1)])]), [(0,''),(100,'')])
    add('first-marker-object.asf', envelope([markers([entry(0,'First')]), markers([entry(1,'Second')])]),
        [(0,'First')], note='The specification allows one Marker Object; first valid object wins')
    add('invalid-then-valid.asf', envelope([markers([entry(0,'Broken', entry_length=0)]), markers([entry(1,'Good')])]),
        [(100,'Good')])
    add('empty-then-valid.asf', envelope([markers([]), markers([entry(1,'Later')])]), [])
    nested = markers(records)
    for _ in range(4): nested = metadata.extension([nested])
    add('nested-depth-four.asf', envelope([nested]), [(t*100,s) for t,s in items])
    add('nested-depth-five.asf', envelope([metadata.extension([nested])]), [], audio=False,
        note='Standalone optional reader skips depth five; the audio opener rejects this header nesting')
    wrong=bytearray(markers(records));wrong[15]^=1
    add('wrong-full-guid.asf',envelope([bytes(wrong)]),[],probe=True,guards=True)
    for length in (0, 11, 13, 65535):
        add(f'bad-entry-length-{length}.asf', envelope([markers([entry(0,'Earlier'), entry(1,b'',entry_length=length)])]),
            [], guards=True, note='A malformed trailing entry must not publish earlier chapters')
    add('bad-units.asf', envelope([markers([entry(0,'Earlier'),entry(1,b'',units=2**32-1)])]), [], guards=True)
    add('bad-count.asf', envelope([markers(records,count=5)]), [], guards=True)
    add('hidden-tail.asf', envelope([markers(records,extra=b'\0')]), [], guards=True)
    odd = bytearray(markers([])); struct.pack_into('<H', odd, 46, 1); odd += b'X'; struct.pack_into('<Q', odd, 16, len(odd))
    add('odd-object-name.asf', envelope([bytes(odd)]), [], guards=True)
    add('truncated-fixed.asf', envelope([writer.obj(MARKER, bytes(23))]), [], guards=True)
    add('isolated-object.asf', isolated([markers(records)], preroll=0), [(t*100,s) for t,s in items], audio=False, guards=True)
    add('isolated-bad-tail.asf', isolated([markers([entry(0,'Earlier'),entry(1,b'',units=2**32-1)])]),
        [], audio=False, guards=True)
    add('no-markers.asf', envelope([]), [], probe=True, guards=True)
    for name,data,delta,expected in [
        ('count-one-marker.asf',envelope([markers(records)]),-1,[(t*100,s) for t,s in items]),
        ('count-no-marker.asf',envelope([]),-1,[]),
        ('count-two-markers.asf',envelope([markers([entry(0,'First')]),markers([entry(1,'Second')])]),-1,[(0,'First')]),
        ('count-marker-overcount.asf',envelope([markers(records)]),1,[(t*100,s) for t,s in items]),
        ('count-marker-undercount-two.asf',envelope([markers(records)]),-2,[(t*100,s) for t,s in items]),
        ('count-short-marker.asf',envelope([writer.obj(MARKER,bytes(23))]),-1,[])]:
        data=bytearray(data);count=struct.unpack_from('<I',data,24)[0];struct.pack_into('<I',data,24,count+delta)
        accepted=name=='count-one-marker.asf'
        add(name,bytes(data),expected,audio=accepted,guards=True,
            note='Only one-marker undercount is accepted; unrelated count mismatches reject')
        cases[-1]['audio_reject']=not accepted
    image=work/'front.png'
    ffmpeg('-f','lavfi','-i','color=c=red:s=16x16','-frames:v','1','-threads','1',image)
    art=metadata.descriptors([metadata.descriptor('WM/Picture',metadata.picture(image.read_bytes()),1,metadata=True)],metadata.LIBRARY)
    for name,object_,expected in [('cover-marker.asf',markers(records),[(t*100,s) for t,s in items]),
                                  ('cover-invalid-marker.asf',markers([entry(0,'Earlier'),entry(1,b'',units=2**32-1)]),[])]:
        add(name,envelope([art,object_]),expected)
        cases[-1]['cover_sha256']=digest(image.read_bytes())
    # Real muxer paths and 9-second inputs for heard-file/console/GUI seeks.
    info = work/'chapters.txt'
    starts = [0,1250,3250,6500,12000]
    info.write_text(';FFMETADATA1\ntitle=ASF Chapter A\nartist=LAMP Test\n'+''.join(
        f'[CHAPTER]\nTIMEBASE=1/1000\nSTART={start}\nEND={end}\ntitle=Part {i} 漢字 🎵\n'
        for i,(start,end) in enumerate(zip(starts,starts[1:]+[13000]))))
    audio_files = []
    for codec, options in [('pcm_s16le',[]), ('libmp3lame',['-b:a','128k']), ('aac',['-aac_pns','0'])]:
        path = work/(codec+'-chapters.asf')
        ffmpeg('-f','lavfi','-i','anoisesrc=r=44100:d=9:seed=9931:a=0.25','-i',info,
               '-map','0:a','-ac','2','-map_metadata','1','-map_chapters','1','-c:a',codec,*options,path)
        expected = chapters.ffprobe_chapters(path)
        add(path.name,path.read_bytes(),[(ms*1000000,s) for ms,s in expected],probe=True,
            note='FFmpeg ASF muxer; navigation/reference decode is also checked')
        audio_files.append(path.name)
        _,children=header_children(path.read_bytes())
        cases[-1]['declared_header_objects']=struct.unpack_from('<I',path.read_bytes(),24)[0]
        cases[-1]['actual_header_objects']=len(children)
    later = work/'later.flac'
    ffmpeg('-f','lavfi','-i','anoisesrc=r=48000:d=9:seed=9932:a=0.25','-ac','2',
           '-metadata','CHAPTER001=00:00:07.000','-c:a','flac',later)
    play = work/'play.asf'
    ffmpeg('-f','lavfi','-i','anoisesrc=r=48000:d=9:seed=9933:a=0.25','-ac','2','-c:a','pcm_s16le',play)
    data=insert(play.read_bytes(),[markers([entry(31000000+t*10000,'Part '+str(i))
        for i,t in enumerate([6500,0,3250,1250,3250,12000])])],3100,True);play.write_bytes(data)
    add(play.name,data,[(t*1000000,'Part '+str(i)) for i,t in enumerate([6500,0,3250,1250,3250,12000])])
    audio_files.append(play.name)
    for case in cases:
        if case['ffprobe']:
            actual=chapters.ffprobe_chapters(work/case['name'])
            expected=[(ns//1000000,chapters.shown(text)) for ns,text in case['chapters']]
            if actual!=expected:raise Failure(case['name']+': fixture FFmpeg comparison differs: '+str(actual))
            case['fixture_ffprobe']=actual
    names={case['name'] for case in cases}|{later.name,info.name,image.name}
    hashes = {name:digest((work/name).read_bytes()) for name in sorted(names)}
    manifest=dict(files=cases,audio_files=audio_files,hashes=hashes,ffmpeg=ffmpeg_version(),writer_sha256=writer_hash())
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Prepared {len(cases)} chapter cases.',flush=True)

def main():
    work=scratch('asf-chapters')
    if '--prepare-only' in sys.argv:prepare(work);return
    if not (work/'manifest.json').exists():prepare(work)
    manifest=json.loads((work/'manifest.json').read_text())
    if manifest['writer_sha256']!=writer_hash():raise Failure('Fixture writer changed; prepare again')
    for name,value in manifest['hashes'].items():
        if digest((work/name).read_bytes())!=value:raise Failure('Changed fixture: '+name)
    wine='--wine-only' in sys.argv;env=dict(os.environ,WINEDEBUG='err+all') if wine else None
    if wine:
        prior=json.loads((out_dir()/'asf-chapters-verification.json').read_text())
        if prior['result']!='passed' or prior['fixture_hashes']!=manifest['hashes']:raise Failure('Matching native run must pass first')
        run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
        objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in
                 {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
        libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
        for name in ('asf-chapters','chapter-navigation'):
            extras=[]
            if name=='chapter-navigation':
                builder=module('windows_builder','../tools/build-windows.py')
                probe=ROOT/'bin/chapter-navigation-probe.obj'
                run([builder.tool('llvm-mc'),'-triple=x86_64-pc-windows-msvc','-filetype=obj',
                     '-defsym=WINDOWS=1','-I',ROOT/'src',ROOT/'tests/chapter-navigation-probe.s','-o',probe]);extras=[probe]
            run(['x86_64-w64-mingw32-gcc','-O2','-std=gnu11','-municode','-I',ROOT/'tests',
                 ROOT/'tests'/(name+'-oracle.c'),*extras,*objects,*libs,'-lm','-o',ROOT/'bin'/(name+'-oracle.exe')])
        cli=['wine',ROOT/'bin/lamp-cli.exe'];oracle=['wine',ROOT/'bin/asf-chapters-oracle.exe']
        navigator=['wine',ROOT/'bin/chapter-navigation-oracle.exe']
    else:
        library=build_lamp();build_oracles(out_dir(),{'asf-chapters-oracle':'asf-chapters-oracle.c'},library)
        probe=out_dir()/'chapter-navigation-probe.o'
        run(['as','--64','-I',ROOT/'src',ROOT/'tests/chapter-navigation-probe.s','-o',probe])
        from lamp_test import compile_c
        compile_c(exe('chapter-navigation-oracle'),[ROOT/'tests/chapter-navigation-oracle.c'],objects=[probe],libraries=[library])
        cli=[lamp_cli()];oracle=[exe('asf-chapters-oracle')];navigator=[exe('chapter-navigation-oracle')]
    checks=[]
    for case in manifest['files']:
        path=work/case['name'];output=run([*oracle,'dump',path],env=env,timeout=120)
        observed=[]
        for line in output.splitlines():
            # Empty titles have only the space after the timestamp.
            parts=line.split(' ',2)
            if parts[0]!='chapter':raise Failure('Unexpected oracle output')
            observed.append([int(parts[1]),bytes.fromhex(parts[2] if len(parts)>2 else '').decode('utf-8')])
        if observed!=case['chapters']:raise Failure(path.name+': guarded chapters differ: '+str(observed)[:1000])
        expected_lines=[chapters.shown(text) for _,text in observed]
        if case.get('audio_reject'):
            rejected=subprocess.run([str(a) for a in [*cli,'--check',path]],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
            if rejected.returncode!=2:raise Failure(path.name+': expected count mismatch rejection')
        if case['audio']:
            shown=run([*cli,'--chapters',path],env=env,timeout=120)
            expected='\n'.join(f'{ns//1000000//3600000:02}:{ns//1000000//60000%60:02}:{ns//1000000//1000%60:02}.{ns//1000000%1000:03}'+
                (' '+s if s else '') for (ns,_),s in zip(observed,expected_lines))
            if '\n'.join(shown.splitlines())!=expected:raise Failure(path.name+': CLI chapters differ')
            if case['name'] not in manifest['audio_files']:
                tags=run([*cli,'--tags',path],env=env,timeout=120)
                if '\n'.join(tags.splitlines())!='title=Marker test\nartist=Ärtist':raise Failure(path.name+': marker changed tags')
                output_pcm=work/'chapters-audio.f32';output_pcm.unlink(missing_ok=True)
                run([*cli,'--decode',path,output_pcm],env=env,timeout=120)
                expected_pcm=struct.pack('<128f',*[v/32768 for v in struct.unpack('<128h',metadata.PCM)])
                if output_pcm.read_bytes()!=expected_pcm:raise Failure(path.name+': marker changed PCM')
                if case.get('cover_sha256'):
                    target=work/'chapters-cover.png';target.unlink(missing_ok=True)
                    run([*cli,'--cover',path,target],env=env,timeout=120)
                    if digest(target.read_bytes())!=case['cover_sha256']:raise Failure(path.name+': marker changed artwork')
        reference=None
        if case['ffprobe'] and not wine:
            reference=chapters.ffprobe_chapters(path)
            if reference!=[(ns//1000000,s) for (ns,_),s in zip(observed,expected_lines)]:raise Failure(path.name+': FFmpeg chapters differ: '+str(reference))
        guards=json.loads(run([*oracle,'guard',path],env=env,timeout=120).splitlines()[-1]) if case['guards'] else None
        checks.append(dict(test=path.name,result='exact',chapters=len(observed),note=case['note'],runtime_ffprobe=reference,
                           fixture_ffprobe=case.get('fixture_ffprobe'),protected_input=guards,
                           declared_header_objects=case.get('declared_header_objects'),actual_header_objects=case.get('actual_header_objects'),
                           audio_rejected=case.get('audio_reject',False),
                           exact_pcm=case['audio'] and case['name'] not in manifest['audio_files']))
        print(path.name+': chapters passed',flush=True)
    for name in manifest['audio_files']:
        if wine:
            ours=work/(name+'.wine.f32');ours.unlink(missing_ok=True)
            run([*cli,'--decode',work/name,ours],env=env,timeout=180)
            reference=work/(name+'.ours.f32')
            if ours.read_bytes()!=reference.read_bytes():raise Failure(name+': Wine continuous PCM differs from verified native PCM')
            checks.append(dict(test=name+' native/Wine continuous PCM',result='exact',
                               lamp_pcm_sha256=digest(ours.read_bytes())))
        else:
            import array, math
            path=work/name;reference=work/(name+'.ffmpeg.f32');ours=work/(name+'.ours.f32');ours.unlink(missing_ok=True)
            ffmpeg('-i',path,'-map','0:a:0','-af','asetpts=N','-f','f32le',reference)
            run([*cli,'--decode',path,ours],timeout=180)
            if len(reference.read_bytes())!=len(ours.read_bytes()):raise Failure(name+': FFmpeg PCM length differs')
            a=array.array('f',reference.read_bytes());b=array.array('f',ours.read_bytes())
            noise=sum((x-y)**2 for x,y in zip(a,b));signal=sum(x*x for x in a)
            snr=math.inf if not noise else 10*math.log10(signal/noise)
            stats=dict(frames=len(a)//2,exact=not noise,snr_db=snr if math.isfinite(snr) else None,
                       peak_error=max(abs(x-y) for x,y in zip(a,b)))
            if snr<(75 if name.startswith('aac') else 95):raise Failure(name+': FFmpeg PCM differs: '+str(stats))
            checks.append(dict(test=name+' FFmpeg continuous PCM',result='passed',stats=stats,
                               ffmpeg_pcm_sha256=digest(reference.read_bytes()),lamp_pcm_sha256=digest(ours.read_bytes())))
        for rate in (44100,48000):
            path=work/name;reference=work/(name+f'.{rate}.f32')
            if not wine:
                reference.unlink(missing_ok=True);run([*cli,'--decode','--rate',rate,path,reference],env=env,timeout=180)
            result=navigation.oracle_run(navigator,[path,work/'later.flac',reference,rate,1],env)
            checks.append(dict(test=f'{name} heard-file navigation at {rate} Hz',result=result,
                               reference_pcm_sha256=digest(reference.read_bytes())))
            print(f'{name}: exact chapter seeks after decode ahead at {rate} Hz',flush=True)
    rng=random.Random(1028);seeds=[work/n for n in ('basic.asf','preroll-after.asf','isolated-object.asf')]
    mutation=work/'mutated.bin';mutations=120 if wine else 1200
    for i in range(mutations):
        data=bytearray(seeds[i%len(seeds)].read_bytes());end=struct.unpack_from('<Q',data,16)[0];pos=rng.randrange(30,end)
        if i%4==0:data=data[:pos]
        elif i%4==1:data[pos]^=1<<rng.randrange(8)
        elif i%4==2:data[pos:pos+min(8,end-pos)]=b'\xff'*min(8,end-pos)
        else:data[pos:pos+min(8,end-pos)]=bytes(min(8,end-pos))
        mutation.write_bytes(data);run([*oracle,'dump',mutation],env=env,timeout=20)
    checks.append(dict(test='mutated markers at protected mapped end',result='passed',inputs=mutations,seed=1028))
    if '--baseline-cli' in sys.argv:
        baseline=Path(sys.argv[sys.argv.index('--baseline-cli')+1]).resolve()
        provenance=json.loads((ROOT/'reports/asf-metadata-verification.json').read_text())
        if digest(baseline.read_bytes())!=provenance['cli_sha256']:raise Failure('Baseline differs from published metadata report')
        for name in ('basic.asf','preroll-after.asf','Unicode markers Ü.asf'):
            path=work/name
            if run([baseline,'--chapters',path]):raise Failure('Pre-chapter baseline unexpectedly lists chapters')
            before=work/'negative-before.f32';after=work/'negative-after.f32'
            for program,target in ((baseline,before),(cli[-1],after)):
                target.unlink(missing_ok=True);run([program,'--decode',path,target],timeout=120)
            if before.read_bytes()!=after.read_bytes():raise Failure('Negative control changed PCM')
            checks.append(dict(test=name+' published-binary negative control',result='absent before, chapters after; unchanged PCM',
                               baseline_commit='10ea02bfb5c1142b4d0d3da21d2183950998e92c',
                               baseline_cli_sha256=digest(baseline.read_bytes()),baseline_report_sha256=digest((ROOT/'reports/asf-metadata-verification.json').read_bytes()),
                               pcm_sha256=digest(after.read_bytes())))
        for name in manifest['audio_files'][:3]:
            result=subprocess.run([str(baseline),'--check',str(work/name)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode!=2:raise Failure(name+': expected pre-fix muxer header rejection')
            checks.append(dict(test=name+' published-binary header-count negative control',result='undercounted muxer file rejects before, opens and seeks after',
                               baseline_cli_sha256=digest(baseline.read_bytes()),baseline_commit='10ea02bfb5c1142b4d0d3da21d2183950998e92c'))
    if '--skip-playback' not in sys.argv:navigation.console_playback(work,wine,checks,path=work/'play.asf')
    sources=['src/tags.s','src/tags_asf.inc','src/chapters_asf.inc','src/chapters.inc','src/asf.s','src/decoder.s',
             'tests/verify-asf-chapters.py','tests/asf-chapters-oracle.c','tests/verify-asf.py','tests/verify-asf-metadata.py',
             'tests/chapter-navigation-oracle.c','tests/chapter-navigation-probe.s','tests/verify-chapter-navigation.py']
    write_report('asf-chapters-wine' if wine else 'asf-chapters',dict(result='passed',checks=checks,
        fixture_hashes=manifest['hashes'],fixture_writer_sha256=manifest['writer_sha256'],fixture_ffmpeg=manifest['ffmpeg'],
        runtime_platform=platform.platform(),runtime_ffmpeg=None if wine else ffmpeg_version(),
        runtime_sources={name:digest((ROOT/name).read_bytes()) for name in sources},cli_sha256=digest(Path(cli[-1]).read_bytes()),
        oracle_sha256=digest(Path(oracle[-1]).read_bytes()),navigation_oracle_sha256=digest(Path(navigator[-1]).read_bytes()),
        playback_skipped='--skip-playback' in sys.argv))
    print(f'Passed {len(checks)} checks.',flush=True)

if __name__=='__main__':main_guard(main)
