#!/usr/bin/env python3
"""Pinned BSD Speex 1.2.1 test-only source; never linked into LAMP."""
from pathlib import Path
import hashlib
import json
import ssl
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS

VERSION='1.2.1'
URL='https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz'
SHA256='4b44d4f2b38a370a2d98a78329fefc56a0cf93d1c1be70029217baae6628feea'
SOURCES='cb_search exc_10_32_table exc_8_128_table filters gain_table hexc_table high_lsp_tables lsp ltp speex stereo vbr vq bits exc_10_16_table exc_20_32_table exc_5_256_table exc_5_64_table gain_table_lbr hexc_10_32_table lpc lsp_tables_nb modes modes_wb nb_celp quant_lsp sb_celp speex_callbacks speex_header window'.split()

def prepare():
 parent=ROOT/'build/reference';parent.mkdir(parents=True,exist_ok=True)
 archive=parent/f'speex-{VERSION}.tar.gz'
 if not archive.exists():
  try:
   with urllib.request.urlopen(URL,timeout=45) as response:data=response.read(8*1024*1024+1)
  except urllib.error.URLError as error:
   # Use the Windows certificate store when Python lacks a mirror's CA.
   # HTTPS verification stays enabled and the independent pinned hash applies.
   if not WINDOWS or not isinstance(error.reason,ssl.SSLCertVerificationError):raise
   subprocess.run(['curl.exe','--fail','--location','--silent','--show-error','--max-time','45',URL,'--output',str(archive)],check=True)
   data=archive.read_bytes()
  if hashlib.sha256(data).hexdigest()!=SHA256:raise RuntimeError('Speex source checksum mismatch')
  archive.write_bytes(data)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA256:raise RuntimeError('Speex source checksum mismatch')
 source=parent/f'speex-{VERSION}'
 with tarfile.open(archive) as bundle:
  for member in bundle.getmembers():
   target=(parent/member.name).resolve()
   if not target.is_relative_to(source.resolve()) or member.issym() or member.islnk():raise RuntimeError('Unsafe Speex archive member')
  bundle.extractall(parent,filter='data')
 # Release tarballs normally generate this during configure. Keep source
 # files pristine; this portable test-only type header is a build product.
 generated=parent/'speex-test-include/speex';generated.mkdir(parents=True,exist_ok=True)
 (generated/'speex_config_types.h').write_text('#include <stdint.h>\ntypedef int16_t spx_int16_t;\ntypedef uint16_t spx_uint16_t;\ntypedef int32_t spx_int32_t;\ntypedef uint32_t spx_uint32_t;\n')
 return source,[generated,generated.parent,source/'include',source/'libspeex'],[source/'libspeex'/f'{name}.c' for name in SOURCES]

if __name__=='__main__':
 source,includes,sources=prepare()
 print(json.dumps({'source':str(source),'archive_sha256':SHA256,'files':len(sources),'runtime_linked':False}))
