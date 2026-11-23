#!/usr/bin/env python3
"""Known encoded video remuxed to QuickTime MOV and fast-start MP4."""
import argparse,hashlib,json,subprocess
from pathlib import Path
from lamp_test import ROOT,WINDOWS

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args):
    r=subprocess.run(list(map(str,args)),capture_output=True,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
    assert r.returncode==0,(args,r.returncode,r.stdout,r.stderr)
    return r.stdout.decode().strip()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',required=True,type=Path);args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();work=out/'mov-video';work.mkdir(exist_ok=True);source=ROOT/'tests/generated/mp4-video/main-b.mp4';cli=out/'lamp-cli.exe';rows=[]
    for name,options in [('quicktime.mov',['-f','mov']),('faststart.mp4',['-movflags','+faststart'])]:
        remux=work/name;run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',source,'-map','0:v:0','-c:v','copy',*options,remux])
        reference=work/(name+'.reference.nv12');run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',remux,'-map','0:v:0','-fps_mode','passthrough','-pix_fmt','nv12','-f','rawvideo',reference])
        target=work/(name+'.nv12');target.unlink(missing_ok=True);check=run([cli,'--video-check',remux]);decode=run([cli,'--video-decode',remux,target]);assert target.read_bytes()==reference.read_bytes()
        rows.append(dict(name=name,frames=90,image_bytes=target.stat().st_size,check=check,decode=decode,sha256={p.name:sha(p) for p in [source,remux,reference,target]}))
    report=dict(result='passed',scope='Actual MOV/faststart encoded video public check/export, no audio or window',inputs=rows,sources={p.relative_to(ROOT).as_posix():sha(p) for p in [Path(__file__),ROOT/'src/win/video_cli.s']},artifacts={'lamp-cli.exe':sha(cli)})
    path=out/'mov-video-verification.json';path.write_text(json.dumps(report,indent=2)+'\n');print('Passed',path)
if __name__=='__main__':main()
