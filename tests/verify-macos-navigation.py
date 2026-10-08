#!/usr/bin/env python3
"""Native queue navigation and real CLI keys, with exact submitted PCM checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import select
import subprocess
import sys
import termios
import time
from lamp_test import ROOT, run


def terminal(binary, observer, work, name, paths, options, actions, reference, repeat=False):
    capture=work/(name+'.f32');capture.unlink(missing_ok=True)
    master,slave=pty.openpty();original=termios.tcgetattr(slave)
    env=dict(os.environ,DYLD_INSERT_LIBRARIES=str(observer),LAMP_TEST_PCM_OUTPUT=str(capture))
    process=subprocess.Popen([binary,*options,*paths],stdin=slave,stdout=slave,stderr=slave,env=env)
    output=bytearray()
    def pump(seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if select.select([master],[],[],.01)[0]:
                output.extend(os.read(master,4096))
    try:
        deadline=time.monotonic()+10
        while b'Core Audio playback.' not in output:
            pump(.01)
            assert process.poll() is None and time.monotonic()<deadline,output
        for delay,keys in actions:
            pump(delay)
            assert process.poll() is None,(name,output)
            os.write(master,keys)
        assert process.wait(timeout=5)==0,(name,output)
        pump(.02)
        restored=termios.tcgetattr(slave)
        restored[3]&=~termios.PENDIN;original[3]&=~termios.PENDIN
        assert restored==original,(name,'terminal settings')
        data=capture.read_bytes()
        if repeat:
            assert b'Repeat: on' in output and b'Repeat: off' in output,output
            expected=(reference*(len(data)//len(reference)+1))[:len(data)]
            assert len(data)>len(reference) and data==expected,(name,len(data))
        elif reference:
            assert data and data==reference[:len(data)],(name,len(data),len(reference))
        else:
            assert not data,(name,'navigation past the end submitted extra PCM')
        return dict(test=name,result='exact submitted PCM',frames=len(data)//8,terminal_restored=True)
    finally:
        if process.poll() is None:process.kill();process.wait()
        os.close(master);os.close(slave)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary-directory',type=Path,default=ROOT/'build/macos')
    p.add_argument('--skip-build',action='store_true')
    args=p.parse_args();out=args.binary_directory.resolve()
    if sys.platform!='darwin':p.error('native macOS required')
    if not args.skip_build:run([sys.executable,ROOT/'tools/build-mac.py','--output',out])
    library=out/'liblamp-test.dylib'
    objects=[x for x in sorted((out/'obj').glob('*.o')) if x.name not in ('mac_cli.o','mac_ui.o')]
    run(['xcrun','clang','-arch','arm64','-dynamiclib',*objects,'-framework','AudioToolbox','-o',library])
    work=out/'navigation-playback';work.mkdir(exist_ok=True)
    metadata=work/'chapters.txt'
    metadata.write_text(';FFMETADATA1\n'+''.join(f'[CHAPTER]\nTIMEBASE=1/1000\nSTART={start}\nEND={end}\ntitle=Chapter {i}\n'
                        for i,(start,end) in enumerate([(0,5000),(5000,10000),(10000,14000)])))
    paths=[];references=[];outputs=[]
    for i,(name,rate,duration,codec) in enumerate([('first.wav',48000,5.5,'pcm_s16le'),
                                                ('second.mka',22050,14,'flac'),('last.wav',48000,.05,'pcm_s24le')]):
        path=work/name
        metadata_args=['-i',metadata,'-map_metadata','1'] if i==1 else []
        run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'anoisesrc=r={rate}:d={duration}:seed={i+18}:a=0.02',
             *metadata_args,'-ac','2','-c:a',codec,path]);paths.append(path)
        target=path.with_suffix('.f32');target.unlink(missing_ok=True)
        run([out/'lamp-cli','--decode','--rate','48000',path,target]);outputs.append(target);references.append(target.read_bytes())
    observer=work/'observer.dylib'
    run(['xcrun','clang','-arch','arm64','-O2','-dynamiclib',ROOT/'tests/mac-queue-observer.c','-framework','AudioToolbox','-o',observer])
    driver=work/'navigation-playback'
    run(['xcrun','clang','-arch','arm64','-O2',ROOT/'tests/mac-navigation-playback.c',library,observer,'-o',driver])
    backend=json.loads(run([driver,*paths,*outputs],env=dict(os.environ,DYLD_INSERT_LIBRARIES=str(observer)),timeout=30))
    print('Core Audio navigation passed',flush=True)
    records=[]
    pause=(.01,b' ');quit=(.1,b'q')
    cases=[('next-previous',[],[pause,(.15,b'n'),(.1,b'p'),(.1,b'>'),quit],references[1]),
           ('previous-restart',['--start','4'],[pause,(.15,b'P'),quit],references[0]),
           ('seek-right',[],[pause,(.15,b'n'),(.1,b'\x1b'),(.02,b'['),(.02,b'C'),quit],references[1][240000*8:]),
           ('seek-left',[],[pause,(.15,b'n'),(.1,b'\x1b[C'),(.1,b'\x1b[D'),quit],references[1]),
           ('seek-up',[],[pause,(.15,b'n'),(.1,b'\x1b[A'),quit],references[2]),
           ('seek-down',[],[pause,(.15,b'n'),(.1,b'\x1b[C'),(.1,b'\x1bOB'),quit],references[1]),
           ('home',[],[pause,(.15,b'n'),(.1,b'\x1b[C'),(.1,b'\x1bOH'),quit],references[1]),
           ('chapters',[],[pause,(.15,b'n'),(.1,b']'),(.1,b']'),(.1,b'['),quit],references[1][240000*8:]),
           ('next-at-end',[],[pause,(.15,b'n'),(.1,b'n'),(.1,b'n')],b'')]
    for name,options,actions,reference in cases:
        records.append(terminal(out/'lamp-cli',observer,work,name,paths,['--rate','48000',*options],actions,reference))
        print(name+': passed',flush=True)
    records.append(terminal(out/'lamp-cli',observer,work,'late-repeat',paths[2:],[],[(.01,b'r'),(.5,b'R')],references[2],repeat=True))
    report=dict(result='passed',platform=platform.platform(),backend=backend,terminal=records,
                binary_sha256=hashlib.sha256((out/'lamp-cli').read_bytes()).hexdigest(),
                library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                scope='Real default Core Audio and pseudo-terminal keys. Observer compares submitted float PCM; it does not measure physical output or transition latency.')
    (out/'macos-navigation-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
