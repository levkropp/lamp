#!/usr/bin/env python3
"""CPU-only source callback, including bounded empty runs and replay epochs."""
import json
import hashlib
from pathlib import Path
import subprocess
from lamp_test import ROOT, WINDOWS, compile_c, out_dir
from mp4_video_fixtures import classic


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out=out_dir();work=out/'mp4-source';work.mkdir(exist_ok=True);obj=out/'obj';ext='.obj' if WINDOWS else '.o'
    binary=work/('mp4-h264-source-oracle'+('.exe' if WINDOWS else ''))
    objects=[obj/(n+ext) for n in ['video_mp4','video_mp4_h264','h264', 'platform' if WINDOWS else 'linux_platform']]
    compile_c(binary,[ROOT/'tests/mp4-h264-source-oracle.c'],objects=objects,libraries=list(obj.glob('*.lib')) if WINDOWS else [])
    folder=ROOT/'tests/generated/mp4-video';sources=sorted(folder.glob('*.mp4'));assert len(sources)==15
    probe=json.loads((folder/'main-b.probe.json').read_text());dump=probe['streams'][0]['extradata'];config=bytes.fromhex(''.join(line.split(':',1)[1].split('  ',1)[0].replace(' ','') for line in dump.splitlines() if ':' in line))
    empty=work/'empty-300.mp4';empty.write_bytes(classic(sizes=(0,)*300,config=config)[0]);sources.append(empty)
    rows=[]
    for source in sources:
        p=subprocess.run([str(binary),str(source)],capture_output=True,timeout=30,**({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}));assert p.returncode==0,(source,p.returncode,p.stdout,p.stderr)
        result=json.loads(p.stdout);assert result['empty_yields']==(2 if source==empty else 0)
        rows.append(dict(input=source.relative_to(ROOT).as_posix(),sha256=sha(source),**result))
    files=[ROOT/'src/video_mp4_h264.s',ROOT/'tests/mp4-h264-source-oracle.c',Path(__file__)]
    report=dict(result='passed',scope='CPU-only source callback equivalence, bounded empty yield, replay and cancellation; no GPU/audio',inputs=rows,sources={p.relative_to(ROOT).as_posix():sha(p) for p in files},artifacts={p.relative_to(out).as_posix():sha(p) for p in [binary,*objects]})
    path=out/'mp4-source-verification.json';path.write_text(json.dumps(report,indent=2)+'\n');print('Passed',len(rows),'source callback inputs',sum(x['pictures'] for x in rows),'pictures',path)


if __name__=='__main__':main()
