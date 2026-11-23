#!/usr/bin/env python3
"""Muted native shared/exclusive engine snapshots. Never changes device settings."""
import argparse,hashlib,json,subprocess,wave
from pathlib import Path
from lamp_test import ROOT,WINDOWS,compile_c
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--bin',required=True,type=Path);args=parser.parse_args();assert WINDOWS
    out=args.bin.resolve();work=out/'engine-clock';work.mkdir(exist_ok=True)
    # The ordinary native lifecycle probe was built in silent mode too. Keep
    # this visible evidence before acquiring any test endpoint.
    assert b'Muted output: lifecycle exercised with volume zero.' in (out/'engine-probe.exe').read_bytes()
    inputs=[]
    for name,frames in [('long',48000*12),('tail',1001),('empty',0)]:
        p=work/(name+'.wav')
        with wave.open(str(p),'wb') as f:f.setnchannels(2);f.setsampwidth(2);f.setframerate(48000);f.writeframes(bytes(frames*4))
        with wave.open(str(p),'rb') as f:assert not any(f.readframes(frames))
        inputs.append(p)
    obj=out/'obj';objects=[obj/(p.stem+'.obj') for p in sorted((ROOT/'src').glob('*.s'))]+[obj/(n+'.obj') for n in ['platform','player','output_notifications','output_format','output_exclusive','video','video_stream','video_present','video_window','video_cli']]
    binary=work/'engine-clock-native.exe';compile_c(binary,[ROOT/'tests/engine-clock-native.c'],objects=objects,libraries=list(obj.glob('*.lib')))
    assert b'Muted output: engine_volume=0 before every engine_play call.' in binary.read_bytes()
    p=subprocess.run([str(binary),*map(str,inputs)],capture_output=True,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW);assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
    lines=p.stdout.decode(errors='replace').splitlines();result=json.loads(lines[-1]);assert 'Muted output: engine_volume=0 before every engine_play call.' in lines
    files=[ROOT/'src/win/player.s',ROOT/'src/win/player_clock.inc',ROOT/'src/audio_clock.s',ROOT/'src/audio_clock.inc',ROOT/'tests/engine-clock-native.c',Path(__file__)]
    result.update(scope='Native default endpoint, one muted owned session at a time; shared endpoint-consumed map and exclusive hardware map, pause/stop/reopen/seek/EOF. No speaker-latency or A/V synchronization claim.',sources={p.relative_to(ROOT).as_posix():sha(p) for p in files},artifacts={p.relative_to(out).as_posix():sha(p) for p in [binary,*objects,*inputs]})
    (out/'engine-clock-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['sources','artifacts']}))
if __name__=='__main__':main()
