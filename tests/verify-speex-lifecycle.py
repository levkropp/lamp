#!/usr/bin/env python3
"""Muted native Windows engine lifecycle with actual Speex files."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/'bin/speex-check');args=p.parse_args();out=args.bin.resolve();probe=out/'engine-probe.exe'
 if sys.platform!='win32':raise RuntimeError('Native Windows execution is required')
 if b'Muted output: lifecycle exercised with volume zero.' not in probe.read_bytes():raise RuntimeError('Build engine-probe with --tests --probe-silent before running this suite')
 work=out/'speex-lifecycle';work.mkdir(exist_ok=True);cases=[]
 for rate,channels in [(8000,1),(16000,2),(32000,2)]:
  path=work/f'silent-{rate}-{channels}.spx';subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'anullsrc=r={rate}:cl='+('mono' if channels==1 else 'stereo')+':d=12','-c:a','libspeex',str(path)],check=True,creationflags=subprocess.CREATE_NO_WINDOW);r=subprocess.run([str(probe),str(path)],capture_output=True,text=True,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW)
  if r.returncode or 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' not in r.stdout:raise RuntimeError(f'Lifecycle {rate}/{channels} failed ({r.returncode}): {r.stdout} {r.stderr}')
  cases.append({'rate':rate,'channels':channels,'fixture_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'result':'passed','details':r.stdout.splitlines()})
 report={'result':'passed','platform':platform.platform(),'scope':'Muted native WASAPI engine lifecycle: three Speex bands, pause/resume, stop/reopen, active/paused seek, cancelled open, and any default-output/exclusive scenarios identified by probe output. Physical device switching and captured hardware PCM are not established.','cases':cases,'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),'sources':{x:hashlib.sha256((ROOT/x).read_bytes()).hexdigest() for x in ['src/speex.s','src/ogg_chain.s','tests/engine-probe.s','tools/build-windows.py','tests/verify-speex-lifecycle.py']}};(out/'speex-lifecycle-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
