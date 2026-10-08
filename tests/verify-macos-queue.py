#!/usr/bin/env python3
"""Observe the shipping native queue's submitted PCM during real playback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
from lamp_test import ROOT, build_lamp, run


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-directory',type=Path,default=ROOT/'build/macos')
    parser.add_argument('--skip-build',action='store_true')
    args=parser.parse_args();out=args.binary_directory.resolve()
    if sys.platform!='darwin':parser.error('native macOS required')
    os.environ['LAMP_OUT']=str(out)
    library=out/'liblamp-test.dylib' if args.skip_build else build_lamp()
    work=out/'queue-playback';work.mkdir(exist_ok=True)
    files=[]
    for name,rate,duration,codec in [('first.wav',48000,.1,'pcm_s16le'),
                                    ('second.flac',22050,1.1,'flac'),('last.wav',48000,.05,'pcm_s24le')]:
        path=work/name
        run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'anoisesrc=r={rate}:d={duration}:seed={len(files)+7}:a=0.02',
             '-ac','2','-c:a',codec,path]);files.append(path)
    reference=work/'reference.f32';reference.unlink(missing_ok=True)
    run([out/'lamp-cli','--decode','--rate','48000',*files,reference])
    observer=work/'observer.dylib'
    run(['xcrun','clang','-arch','arm64','-O2','-dynamiclib',ROOT/'tests/mac-queue-observer.c',
         '-framework','AudioToolbox','-o',observer])
    target=work/'queue-playback'
    run(['xcrun','clang','-arch','arm64','-O2',ROOT/'tests/mac-queue-playback.c',library,observer,'-o',target])
    env=dict(os.environ,DYLD_INSERT_LIBRARIES=str(observer))
    result=run([target,*files,reference],env=env,timeout=30)
    report=json.loads(result)
    report.update(platform=platform.platform(),binary_sha256=hashlib.sha256((out/'lamp-cli').read_bytes()).hexdigest(),
                  library_sha256=hashlib.sha256(library.read_bytes()).hexdigest())
    (out/'macos-queue-playback-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
