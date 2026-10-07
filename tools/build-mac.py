#!/usr/bin/env python3
"""Build LAMP's native Apple Silicon CLI and app using Xcode command line tools."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import arm64
from arm64_lamp import Translator
from masm import normalize, procedures


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def build(out, release=False):
    if sys.platform != 'darwin':
        raise SystemExit('The macOS build requires Xcode command line tools on macOS.')
    gnu, a64, obj = (out / x for x in ('gnu', 'a64', 'obj'))
    for p in (gnu, a64, obj): p.mkdir(parents=True, exist_ok=True)
    compiler = ['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=12.0']
    if not release: compiler.append('-g')
    version = (ROOT/'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        raise SystemExit('VERSION is not a supported bundle version.')
    for p in sorted((ROOT/'src').iterdir()):
        if p.suffix in ('.inc', '.asm'):
            (gnu/p.name).write_text(normalize(p))
    objects = []
    functions = []
    for p in sorted(gnu.glob('*.asm')):
        if p.stem in ('player', 'ui'): continue
        source = arm64.Source([str(gnu)], {})
        source.run(str(p))
        target = a64 / (p.stem + '.s')
        target.write_text(Translator(source, str(p)).run())
        o = obj / (p.stem + '.o')
        run(*compiler, '-c', target, '-o', o)
        objects.append(o)
        text = (ROOT/'src'/p.name).read_text()
        proc = procedures(ROOT/'src'/p.name)
        public = re.findall(r'^PUBLIC\s+([^\n]+)', text, re.M | re.I)
        functions += [s.strip() for line in public for s in line.split(',') if s.strip() in proc]
    # Export the same callable decoder API to native test oracles.
    bridge = a64 / 'bridge.s'
    bridge.write_text((ROOT/'src/mac/bridge.s').read_text() + '\n' +
                      '\n'.join('BRIDGE '+n for n in sorted(set(functions))
                                if n not in ('decoder_open','decoder_read','decoder_seek','decoder_close'))+'\n')
    o = obj/'mac_bridge.o'
    run(*compiler, '-I', ROOT/'src/mac', '-c', bridge, '-o', o)
    objects.append(o)
    native = {}
    for p in sorted((ROOT/'src/mac').glob('*.s')):
        if p.stem == 'bridge': continue
        o = obj / ('mac_' + p.stem + '.o')
        run(*compiler, '-I', ROOT/'src/mac', '-c', p, '-o', o)
        if p.stem in ('cli','ui'): native[p.stem] = o
        else: objects.append(o)
    version_source = a64/'version.s'
    version_source.write_text('.section __TEXT,__cstring,cstring_literals\n.globl _lamp_version\n_lamp_version: .asciz "'+version+'"\n')
    version_object = obj/'mac_version.o'
    run(*compiler, '-c', version_source, '-o', version_object)
    objects.append(version_object)
    for kind, name in [('cli','lamp-cli'), ('ui','lamp')]:
        if kind not in native: continue
        tmp = out / (name+'.new')
        libraries = ['-framework', 'AudioToolbox']
        if kind == 'ui': libraries += ['-framework', 'AppKit']
        run(*compiler, '-o', tmp, *objects, native[kind], *libraries)
        if release: run('xcrun','strip','-x',tmp)
        tmp.replace(out/name)
    if 'ui' in native:
        contents = out / 'LAMP.app/Contents'
        for folder in ('MacOS','Resources'): (contents/folder).mkdir(parents=True,exist_ok=True)
        shutil.copy2(out/'lamp',contents/'MacOS/lamp.new')
        (contents/'MacOS/lamp.new').replace(contents/'MacOS/lamp')
        for name in ('LICENSE','THIRD_PARTY_NOTICES'):
            shutil.copy2(ROOT/name, contents/'Resources'/name)
        # Use the existing LAMP artwork at standard and Retina icon sizes.
        iconset = out/'lamp.iconset'
        iconset.mkdir(exist_ok=True)
        for points in (16,32,128,256,512):
            for scale in (1,2):
                pixels = points*scale
                name = f'icon_{points}x{points}'+('@2x' if scale==2 else '')+'.png'
                subprocess.run(['sips','-z',str(pixels),str(pixels),str(ROOT/'assets/lamp.png'),
                                '--out',str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
        run('iconutil','-c','icns',iconset,'-o',contents/'Resources/lamp.icns')
        plist = {'CFBundleName':'LAMP','CFBundleDisplayName':'LAMP',
                 'CFBundleIdentifier':'io.github.levkropp.lamp', 'CFBundleExecutable':'lamp',
                 'CFBundlePackageType':'APPL','CFBundleShortVersionString':version.split('-')[0],
                 'CFBundleIconFile':'lamp.icns',
                 'CFBundleVersion':version.split('-')[0], 'LSMinimumSystemVersion':'12.0',
                 'NSHighResolutionCapable':True,
                 'CFBundleDocumentTypes':[{'CFBundleTypeName':'Audio','CFBundleTypeRole':'Viewer',
                    'LSHandlerRank':'Alternate','CFBundleTypeExtensions':['wav','aiff','aif','aifc','flac','mp3','ogg','opus']} ]}
        (contents/'Info.plist').write_bytes(plistlib.dumps(plist))
        run('codesign','--force','--sign','-',out/'LAMP.app')
    print(out/'lamp-cli')
    if 'ui' in native: print(out/'LAMP.app')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT/'build/macos')
    args = parser.parse_args()
    build(args.output.resolve(), args.release)
