#!/usr/bin/env python3
"""Build a pinned, test-only official WavPack hybrid fixture oracle (no runtime link)."""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import tarfile
import urllib.request

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tests'))
from lamp_test import compile_c, exe
VERSION='5.9.0'
SHA256='2a53e50aefd8c9f04a0828a0e1ef77b6f4c17b0ef6964ad234ab295f313b7d6d'
URL=f'https://codeload.github.com/dbry/WavPack/tar.gz/refs/tags/{VERSION}'
SOURCES='common_utils decorr_utils entropy_utils extra1 extra2 open_utils open_filename open_legacy open_raw pack pack_dns pack_floats pack_utils read_words tags tag_utils unpack unpack_floats unpack_seek unpack_utils write_words'.split()

def build():
 parent=ROOT/'build/reference';parent.mkdir(parents=True,exist_ok=True)
 archive=parent/f'wavpack-{VERSION}.tar.gz'
 if not archive.exists():
  with urllib.request.urlopen(URL,timeout=45) as response:data=response.read(8*1024*1024+1)
  if hashlib.sha256(data).hexdigest()!=SHA256:raise RuntimeError('Official WavPack source hash mismatch')
  archive.write_bytes(data)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA256:raise RuntimeError('Official WavPack source hash mismatch')
 source=parent/f'WavPack-{VERSION}'
 with tarfile.open(archive) as bundle:
  for member in bundle.getmembers():
   path=(parent/member.name).resolve()
   if not path.is_relative_to(source.resolve()) or member.issym() or member.islnk():raise RuntimeError('Unsafe WavPack archive member')
  bundle.extractall(parent,filter='data')
 target=parent/exe('wavpack-hybrid-reference').name
 compile_c(target,[ROOT/'tests/wavpack-hybrid-reference.c',*[source/'src'/f'{name}.c' for name in SOURCES]],includes=[source/'include',source/'src',ROOT/'tests'],libraries=[] if sys.platform=='win32' else ['-lm'])
 (parent/'wavpack-reference-build.json').write_text(json.dumps({'version':VERSION,'url':URL,'archive_sha256':SHA256,'oracle':str(target),'oracle_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'runtime_linked':False},indent=2)+'\n',encoding='utf-8')
 print(target)
 return target

if __name__=='__main__':build()
