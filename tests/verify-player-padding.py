#!/usr/bin/env python3
"""Reproduce the starvation-clock bug in the published previous engine object."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
from lamp_test import ROOT,WINDOWS,compile_c
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',required=True,type=Path);parser.add_argument('--baseline',default='ba8f3fd335c4f9fa83059b2c4769646d4fd76b7c');args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();work=out/'player-padding';work.mkdir(exist_ok=True);assembler=shutil.which('llvm-mc')
    def path(p):
        s=str(p.absolute());return s if assembler else '/mnt/'+s[0].lower()+s[2:].replace('\\','/')
    old=subprocess.check_output(['git','-c','safe.directory=C:/Users/Med/Downloads/lamp','show',args.baseline+':src/win/player.s'],cwd=ROOT)
    baseline=work/'previous-player.s';baseline.write_bytes(old)
    aliases='''
.globl pc_test_fill,pc_test_client,pc_test_render,pc_test_buffer_frames,pc_test_done,pc_test_error,pc_test_write,pc_test_read,pc_test_seek
.set pc_test_fill,fill_render
.set pc_test_client,client_obj
.set pc_test_render,render_obj
.set pc_test_buffer_frames,buffer_frames
.set pc_test_done,producer_done
.set pc_test_error,audio_hresult
.set pc_test_write,write_count
.set pc_test_read,read_count
.set pc_test_seek,engine_seek_frames
'''
    probe=work/'previous-probe.s';probe.write_text('.include "previous-player.s"\n'+aliases)
    obj=work/'previous-player.obj';options=['-triple=x86_64-pc-windows-msvc','-filetype=obj','-defsym=WINDOWS=1','-I',path(ROOT/'src'),'-I',path(ROOT/'src/win'),'-I',path(work),path(probe),'-o',path(obj)]
    lib=ROOT/'build/toolchain/root/usr/lib';command=[assembler,*options] if assembler else ['wsl','-d','Ubuntu','--','env','LD_LIBRARY_PATH='+path(lib/'x86_64-linux-gnu'),path(lib/'llvm-18/bin/llvm-mc'),*options];subprocess.run(command,check=True,capture_output=True,timeout=30)
    objects=[out/'obj'/(p.stem+'.obj') for p in sorted((ROOT/'src').glob('*.s'))]+[out/'obj'/(n+'.obj') for n in ['platform','output_notifications','output_format','output_exclusive','video','video_stream','video_present','video_window','video_cli']]
    rows=[]
    for name,player,defines,expected in [('previous',obj,[],2),('current',out/'player-clock/player-clock-probe.obj',['CURRENT_ENGINE'],0)]:
        binary=work/(name+'.exe');compile_c(binary,[ROOT/'tests/player-padding-oracle.c'],objects=[*objects,player],defines=defines,libraries=list((out/'obj').glob('*.lib')))
        p=subprocess.run([str(binary)],capture_output=True,timeout=20,creationflags=subprocess.CREATE_NO_WINDOW);assert p.returncode==expected,(name,p.returncode,p.stdout,p.stderr)
        rows.append(dict(name=name,exit=p.returncode,stdout=p.stdout.decode().strip(),stderr=p.stderr.decode().strip(),binary_sha256=sha(binary)))
    report=dict(result='passed',scope='Isolated published previous/current shared render objects, CPU-only fake clients; never opens an audio endpoint.',baseline=args.baseline,comparisons=rows,sources={p.relative_to(ROOT).as_posix():sha(p) for p in [ROOT/'tests/player-padding-oracle.c',Path(__file__)]},artifacts={p.relative_to(out).as_posix():sha(p) for p in [baseline,probe,obj,out/'player-clock/player-clock-probe.obj',*[work/(n+'.exe') for n in ['previous','current']]]})
    (out/'player-padding-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
