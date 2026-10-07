#!/usr/bin/env python3
"""Package a locally signed ARM64 app/CLI and record exact sizes and hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary-directory', type=Path, default=ROOT/'build/macos')
    p.add_argument('--output', type=Path, default=ROOT/'build/packages')
    p.add_argument('--skip-build', action='store_true')
    args = p.parse_args()
    source, out = args.binary_directory.resolve(), args.output.resolve()
    if not args.skip_build:
        subprocess.run([sys.executable, ROOT/'tools/build-mac.py','--release','--output',source],check=True)
    version = (ROOT/'VERSION').read_text().strip()
    actual = subprocess.check_output([source/'lamp-cli','--version'],text=True).strip()
    if actual != version:
        raise SystemExit(f'Binary version {actual!r} differs from VERSION {version!r}.')
    subprocess.run(['codesign','--verify','--strict',source/'LAMP.app'],check=True)
    name=f'LAMP-{version}-macOS-arm64'
    stage=out/name
    stage.mkdir(parents=True,exist_ok=True)
    shutil.copytree(source/'LAMP.app',stage/'LAMP.app',dirs_exist_ok=True)
    for original, dest in [(source/'lamp-cli','lamp-cli'),(ROOT/'LICENSE','LICENSE'),
                           (ROOT/'THIRD_PARTY_NOTICES','THIRD_PARTY_NOTICES'),(ROOT/'docs/macos.md','README.md')]:
        shutil.copy2(original,stage/dest)
    manifest={'version':version,'architecture':'arm64','minimum_macos':'12.0',
              'signing':'ad-hoc local build; not Developer ID signed or notarized','files':[]}
    for f in sorted(stage.rglob('*')):
        if f.is_file() and f != stage/'manifest.json':
            manifest['files'].append({'file':str(f.relative_to(stage)),'bytes':f.stat().st_size,
                                     'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
    (stage/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    archive=out/(name+'.zip')
    subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',stage,archive],check=True)
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    (out/(name+'.zip.sha256')).write_text(f'{digest}  {archive.name}\n')
    print(archive)

if __name__ == '__main__': main()
