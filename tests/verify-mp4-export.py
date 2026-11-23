#!/usr/bin/env python3
"""Native public MP4 export matrix, owned output cleanup and hidden CLI windows."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
from lamp_test import ROOT, WINDOWS


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def call(args, expected=0):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
    assert p.returncode==expected,(args,p.returncode,p.stdout[-2000:],p.stderr[-2000:])
    return p.stdout.decode(errors='replace').strip()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',type=Path,required=True)
    parser.add_argument('--fixtures',type=Path,default=ROOT/'tests/generated/mp4-video');args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();folder=args.fixtures.resolve();work=out/'mp4-export';work.mkdir(exist_ok=True);cli=out/'lamp-cli.exe'
    control_api=runpy.run_path(str(ROOT/'tests/verify-h264-file.py'))['cancel_or_write_control']
    public_window=runpy.run_path(str(ROOT/'tests/verify-video-present.py'))['public_window']
    report=dict(result='passed',scope='Public MP4/MOV H264 video-only commands; known encoded samples only, no audio endpoint',inputs=[],controls=[],windows=[],sources={},artifacts={})
    for p in [ROOT/'src/win/video_cli.s',ROOT/'src/win/video_stream.s',ROOT/'src/win/video_stream.inc',ROOT/'src/win/video_window.s',ROOT/'src/win/video_window.inc',ROOT/'src/video_mp4_h264.s',Path(__file__),ROOT/'tests/verify-h264-file.py',ROOT/'tests/verify-video-present.py']:
        report['sources'][p.relative_to(ROOT).as_posix()]=sha(p)
    for source in sorted(folder.glob('*.mp4')):
        probe=json.loads(source.with_suffix('.probe.json').read_text());stream=probe['streams'][0];assert stream['codec_type']=='video'
        reference=work/(source.stem+'.reference.nv12');call(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',source,'-map','0:v:0','-fps_mode','passthrough','-pix_fmt','nv12','-f','rawvideo',reference])
        target=work/(source.stem+'.nv12');target.unlink(missing_ok=True)
        check=call([cli,'--video-check',source]);decode=call([cli,'--video-decode',source,target]);assert target.read_bytes()==reference.read_bytes(),source
        frames=target.stat().st_size//(stream['width']*stream['height']*3//2)
        assert 'frames='+str(frames) in check and 'frames='+str(frames) in decode,(check,decode)
        report['inputs'].append(dict(name=source.stem,frames=frames,bytes=target.stat().st_size,check=check,decode=decode,sha256={p.name:sha(p) for p in [source,source.with_suffix('.probe.json'),reference,target]}))
        print(source.stem,frames,'public exported images exact',flush=True)
    assert len(report['inputs'])==15
    source=folder/'base.mp4'
    sentinel=work/'existing.nv12';sentinel.write_bytes(b'existing user output\0');before=sha(sentinel)
    call([cli,'--video-decode',source,sentinel],1);assert sha(sentinel)==before
    report['existing_output_preserved']=True
    for mode in ('cancel','write'):
        binary,details=control_api(out,work,mode);target=work/(mode+'-partial.nv12');target.unlink(missing_ok=True)
        message=call([binary,'--video-decode',source,target],1);assert not target.exists(),mode
        report['controls'].append(dict(**details,partial_output_removed=True,message=message))
    for name in ('base','interleave','vfr'):
        report['windows'].append(dict(name=name,**public_window(cli,folder/(name+'.mp4'))))
    for p in [cli,out/'lamp.exe',*[out/'obj'/(n+'.obj') for n in ['video_mp4_h264','video_cli','video_stream','video_window']]]:
        report['artifacts'][p.relative_to(out).as_posix()]=sha(p)
    path=out/'mp4-export-verification.json';path.write_text(json.dumps(report,indent=2)+'\n');print('Passed',path)


if __name__=='__main__':main()
