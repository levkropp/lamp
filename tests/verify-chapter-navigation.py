#!/usr/bin/env python3
"""Chapter boundaries, heard-file seeks, resampling and console key playback.

Prepare fixtures on any host; run on x86 Linux or Windows. --wine-only uses
shipping COFF objects and compares PCM with the completed native run.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, WINDOWS, Failure, build_lamp, compile_c, decode_f32, exe,
    ffmpeg, ffmpeg_version, lamp_cli, main_guard, out_dir, run, scratch, write_report)

def module(name,filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
chapters=module('chapter_reader','verify-chapters.py')
nav=module('navigation','verify-navigation.py')

def prepare(work):
    metadata=work/'chapters.txt'
    starts=[0,1250,3250,6500,12000]
    metadata.write_text(';FFMETADATA1\ntitle=Chapter test\n'+''.join(
        f'[CHAPTER]\nTIMEBASE=1/1000\nSTART={start}\nEND={end}\ntitle=Part {index}\n'
        for index,(start,end) in enumerate(zip(starts,starts[1:]+[13000]))))
    def source(seed=9100,rate=44100):
        return ['-f','lavfi','-i',f'anoisesrc=r={rate}:d=9:seed={seed}:a=0.25','-ac','2']
    files=[]
    for name,coding in [('book.mp3',['-c:a','libmp3lame']),('book.m4a',['-c:a','alac']),
                        ('book.mka',['-c:a','alac'])]:
        path=work/name
        ffmpeg(*source(),'-i',metadata,'-map','0:a','-map_metadata','1','-map_chapters','1',*coding,path)
        files.append(name)
    comments=[]
    # Deliberately unsorted and duplicated timestamps: time order used for
    # navigation must not alter the order printed by --chapters.
    for index,start in enumerate([6500,0,3250,1250,3250,12000]):
        comments+=['-metadata',f'CHAPTER{index:03}=00:00:{start//1000:02}.{start%1000:03}',
                   '-metadata',f'CHAPTER{index:03}NAME=Part {index}']
    path=work/'book.flac';ffmpeg(*source(),*comments,'-c:a','flac',path);files.append(path.name)
    path=work/'book.ogg';ffmpeg(*source(),*comments,'-c:a','libvorbis',path);files.append(path.name)
    raw=work/'no-chapters.wav';ffmpeg(*source(),'-c:a','pcm_s24le',raw)
    frames=b''.join(chapters.frame(4,b'CHAP',chapters.chap(f'c{i}'.encode(),start,13000,
        chapters.frame(4,b'TIT2',b'\x03Part '+str(i).encode()))) for i,start in enumerate([6500,0,3250,1250,3250,12000]))
    path=work/'book.wav';path.write_bytes(chapters.riff_file(b'WAVE',chapters.riff_chunks(raw.read_bytes())+[(b'id3 ',chapters.id3(4,[frames]))]));files.append(path.name)
    later=work/'later.flac';ffmpeg(*source(9101,48000),'-metadata','CHAPTER001=00:00:07.000','-c:a','flac',later)
    # Faster 48 kHz files also exercise keys and the GUI through the sink.
    played=work/'play.flac';ffmpeg(*source(9102,48000),*comments,'-c:a','flac',played)
    manifest={name:hashlib.sha256((work/name).read_bytes()).hexdigest() for name in files+[raw.name,later.name,played.name]}
    (work/'manifest.json').write_text(json.dumps(dict(files=files,hashes=manifest,ffmpeg=ffmpeg_version()),indent=2)+'\n')

def oracle_run(command,args,env=None):
    with tempfile.TemporaryFile() as log:
        result=subprocess.run([*map(str,command),*map(str,args)],stdout=log,stderr=subprocess.STDOUT,env=env,timeout=180)
        log.seek(0);text=log.read().decode('utf-8','replace')
    if result.returncode:raise Failure(f'Chapter oracle exited {result.returncode}: {text[-2000:]}')
    return json.loads(text.splitlines()[-1])

def console_playback(work, wine, checks, path=None):
    nav.WINE=wine
    audio=nav.audio_environment()
    if audio is None:raise Failure('PulseAudio is required for chapter key playback')
    path=work/'play.flac' if path is None else path;reference=work/'play.f32'
    if not wine:decode_f32(path,reference)
    pcm=reference.read_bytes()
    recorder=None
    offset=0

    def heard_then_key(start_ms,key):
        # The greeting precedes sink startup. Wait for the audio itself before
        # pressing a key, so slow hosts exercise an actually heard position.
        def wait():
            nonlocal offset
            deadline=time.monotonic()+60
            while time.monotonic()<deadline:
                data=recorder.path.read_bytes()
                found=nav.runs(data[offset:],{'book':pcm})
                if any(start_ms*48<=start<(start_ms+500)*48 and frames>=256
                       for _,start,frames in found):
                    offset=len(data)
                    return key
                time.sleep(0.05)
            raise Failure(f'No captured chapter PCM at {start_ms} ms: {found}')
        return wait

    recorder=nav.Recorder(audio,work/('keys-wine.f32' if wine else 'keys.f32'))
    try:
        code,text=nav.interactive(['--start','1.5',path],audio,
            [(0,heard_then_key(1500,b']')),(0,heard_then_key(3250,b'[')),
             (0,heard_then_key(1250,b'q'))],ready_text=b'Playing.')
    finally:capture=recorder.stop()
    if code:raise Failure('Chapter console keys: '+text[-1000:])
    found=nav.runs(capture,{'book':pcm})
    # Wine's driver may split runs; real starts are large discontinuities.
    starts=[found[0][1]] if found else []
    for prior,current in zip(found,found[1:]):
        if abs(current[1]-(prior[1]+prior[2]))>nav.RATE//2:starts.append(current[1])
    if len(starts)!=3 or not 1500*48<=starts[0]<2000*48 or not 3250*48<=starts[1]<3750*48 or not 1250*48<=starts[2]<1750*48:
        raise Failure(f'Chapter console keys had unexpected starts: {starts}; runs {found}')
    checks.append(dict(test='console ] then [',result='heard chapter starts',starts=starts,runs=found))
    recorder=nav.Recorder(audio,work/('paused-wine.f32' if wine else 'paused.f32'))
    offset=0
    observation={}
    def sample_pause():
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            data=recorder.path.read_bytes();window=data[-nav.RATE//2*8:]
            if len(window)==nav.RATE//2*8 and not any(window):
                observation.update(offset=len(data),silent=True)
                return
            time.sleep(0.05)
        raise Failure('Paused chapter navigation did not stay silent')
    try:
        code,text=nav.interactive(['--start','1.5',path],audio,
            [(0,heard_then_key(1500,b' ')),(0.3,b']'),(1.0,sample_pause),
             (0,b' '),(0,heard_then_key(3250,b'q'))],ready_text=b'Playing.')
    finally:capture=recorder.stop()
    after=nav.runs(capture[observation.get('offset',0):],{'book':pcm})
    if code or not observation.get('silent') or not after or not 3250*48<=after[0][1]<3750*48:
        raise Failure(f'Paused console chapter navigation: {observation}, resumed runs {after}: {text[-500:]}')
    checks.append(dict(test='console paused chapter seek',result='silent until resume, then chapter PCM',
        silent_window_frames=nav.RATE//2,resumed_runs=after))

def main():
    work=scratch('chapter-navigation')
    if '--prepare-only' in sys.argv:prepare(work);return
    if not (work/'manifest.json').exists():prepare(work)
    manifest=json.loads((work/'manifest.json').read_text())
    for name,digest in manifest['hashes'].items():
        if hashlib.sha256((work/name).read_bytes()).hexdigest()!=digest:raise Failure('Fixture changed: '+name)
    wine='--wine-only' in sys.argv
    env=None
    out_dir().mkdir(parents=True,exist_ok=True)
    probe=out_dir()/('chapter-navigation-probe.obj' if wine or WINDOWS else 'chapter-navigation-probe.o')
    if wine or WINDOWS:
        spec=importlib.util.spec_from_file_location('windows_build',ROOT/'tools/build-windows.py')
        builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
        run([builder.tool('llvm-mc'),'-triple=x86_64-pc-windows-msvc','-filetype=obj',
             '-defsym=WINDOWS=1','-I',ROOT/'src',ROOT/'tests/chapter-navigation-probe.s','-o',probe])
    else:run(['as','--64','-I',ROOT/'src',ROOT/'tests/chapter-navigation-probe.s','-o',probe])
    if wine:
        run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
        objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
        libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
        oracle=ROOT/'bin/chapter-navigation-oracle.exe'
        run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-municode','-I',ROOT/'tests',ROOT/'tests/chapter-navigation-oracle.c',probe,*objects,*libs,'-lm','-o',oracle])
        command=['wine',oracle];env=dict(os.environ,WINEDEBUG='err+all')
        report=json.loads((out_dir()/'chapter-navigation-verification.json').read_text())
        if report['result']!='passed':raise Failure('Native checks must pass first')
    else:
        library=build_lamp();compile_c(exe('chapter-navigation-oracle'),[ROOT/'tests/chapter-navigation-oracle.c'],objects=[probe],libraries=[library])
        command=[exe('chapter-navigation-oracle')]
    checks=[dict(test='boundary rules',result=oracle_run(command,[],env))]
    for name in manifest['files']+['no-chapters.wav']:
        path=work/name
        printed=chapters.lamp_chapters(path)
        if name!='no-chapters.wav' and not printed:raise Failure('Fixture has no chapters: '+name)
        for rate in (44100,48000):
            reference=work/(name+f'.{rate}.f32')
            if not wine:
                reference.unlink(missing_ok=True);run([lamp_cli(),'--decode','--rate',str(rate),path,reference])
            try:result=oracle_run(command,[path,work/'later.flac',reference,rate,int(name!='no-chapters.wav')],env)
            except Failure as error:raise Failure(f'{name} at {rate} Hz: {error}') from error
            checks.append(dict(test=f'{name} heard-file chapters at {rate} Hz',result=result))
            print(f'Verified {name} heard-file PCM at {rate} Hz',flush=True)
        if chapters.lamp_chapters(path)!=printed:raise Failure('Navigation changed chapter listing order')
    if '--skip-playback' not in sys.argv and not WINDOWS:console_playback(work,wine,checks)
    write_report('chapter-navigation-wine' if wine else 'chapter-navigation',dict(result='passed',checks=checks,
        fixture_hashes=manifest['hashes'],fixture_ffmpeg=manifest['ffmpeg'],
        oracle_source_sha256=hashlib.sha256((ROOT/'tests/chapter-navigation-oracle.c').read_bytes()).hexdigest(),
        probe_source_sha256=hashlib.sha256((ROOT/'tests/chapter-navigation-probe.s').read_bytes()).hexdigest(),
        environment=dict(platform=platform.platform(),python=sys.version),
        scope='Chronological chapter boundaries without reordered metadata; heard-file exact seeks after decode ahead, resampling and keys'))
    print(f'Passed {len(checks)} chapter navigation checks.',flush=True)

if __name__=='__main__':main_guard(main)
