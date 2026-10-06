#!/usr/bin/env python3
"""Build LAMP's x64 Windows executables with LLVM, on Windows, Linux or macOS.

Only LLVM (llvm-mc, llvm-dlltool, llvm-rc, lld-link) and Python are needed.
Import libraries are generated from src/win/*.def; no CRT, Windows SDK or MSVC
is linked. The same GNU-syntax sources build the Linux binary with build.sh.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def tool(name):
    roots = [os.environ.get('LLVM_BIN', ''), r'C:\Program Files\LLVM\bin',
             '/opt/homebrew/opt/llvm/bin', '/opt/homebrew/opt/lld/bin', '/usr/lib/llvm-18/bin']
    for candidate in (name, name + '-18', name + '-19', name + '-20'):
        found = shutil.which(candidate)
        if found:
            return found
    for root in roots:
        for suffix in ('', '.exe'):
            path = Path(root) / (name + suffix)
            if root and path.is_file():
                return str(path)
    raise SystemExit(f'{name} is required. Install LLVM and set LLVM_BIN to its bin folder.')


def run(args, cwd=ROOT):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)


def resource(rc, out, cli):
    """Expand the one #ifdef in assets/lamp.rc, so llvm-rc needs no preprocessor."""
    lines, keep = [], [True]
    for line in (ROOT / 'assets/lamp.rc').read_text(encoding='utf-8').splitlines():
        word = line.strip()
        if word == '#ifdef LAMP_CLI':
            keep.append(keep[-1] and cli)
        elif word == '#else':
            keep[-1] = keep[-2] and not keep[-1]
        elif word == '#endif':
            keep.pop()
        elif keep[-1]:
            lines.append(line.replace('"lamp.ico"', '"' + (ROOT / 'assets/lamp.ico').as_posix() + '"'))
    name = 'lamp-cli' if cli else 'lamp'
    source = out / f'{name}.rc'
    source.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    res = out / f'{name}.res'
    # Relative paths keep llvm-rc from reading a POSIX absolute path as a /flag.
    run([rc, '/no-preprocess', '/fo', os.path.relpath(res, ROOT), os.path.relpath(source, ROOT)])
    return res


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', default=str(ROOT / 'bin'), help='output directory (default: bin)')
    parser.add_argument('--tests', action='store_true',
                        help='also build engine-probe.exe, ui-preview.exe, ui-list.exe and ui-driver.exe')
    parser.add_argument('--preview-codec', type=int, default=None, help='codec kind shown by ui-preview.exe')
    parser.add_argument('--preview-tags', action='store_true', help='ui-preview.exe shows a tagged title')
    parser.add_argument('--preview-cover', action='store_true',
                        help='ui-preview.exe shows a tagged title with cover art (use --preview-codec 3)')
    parser.add_argument('--preview-list', action='store_true',
                        help='ui-preview.exe shows the second file of a list of three, repeating')
    parser.add_argument('--debug', action='store_true', help='emit a PDB')
    args = parser.parse_args()
    out = Path(args.out).resolve()
    obj_dir = out / 'obj'
    obj_dir.mkdir(parents=True, exist_ok=True)
    mc, dlltool, link, rc = map(tool, ['llvm-mc', 'llvm-dlltool', 'lld-link', 'llvm-rc'])

    shared = sorted((ROOT / 'src').glob('*.s'))
    windows = sorted((ROOT / 'src/win').glob('*.s'))
    tests = [ROOT / f'tests/{name}.s' for name in ('engine-probe', 'ui-preview', 'ui-list', 'ui-driver')] \
        if args.tests else []

    def assemble(path):
        obj = obj_dir / (path.stem + '.obj')
        defines = ['-defsym=WINDOWS=1']
        if path.stem == 'ui-preview' and args.preview_codec is not None:
            defines.append(f'-defsym=PREVIEW_CODEC={args.preview_codec}')
        if path.stem == 'ui-preview' and args.preview_tags:
            defines.append('-defsym=PREVIEW_TAGS=1')
        if path.stem == 'ui-preview' and args.preview_cover:
            defines.append('-defsym=PREVIEW_COVER=1')
        if path.stem == 'ui-preview' and args.preview_list:
            defines.append('-defsym=PREVIEW_LIST=1')
        run([mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj', *defines,
             '-I', ROOT / 'src', '-I', ROOT / 'src/win', '-I', ROOT / 'tests', path, '-o', obj])
        return obj

    with concurrent.futures.ThreadPoolExecutor() as pool:
        objects = dict(zip(shared + windows + tests, pool.map(assemble, shared + windows + tests)))
    libraries = []
    for definition in sorted((ROOT / 'src/win').glob('*.def')):
        lib = obj_dir / (definition.stem + '.lib')
        run([dlltool, '-m', 'i386:x86-64', '-d', definition, '-l', lib])
        libraries.append(lib)

    common = [objects[p] for p in shared] + [objects[ROOT / 'src/win/platform.s'], objects[ROOT / 'src/win/player.s']]

    def executable(name, entry, subsystem, objs, res=None):
        command = [link, '/nologo', '/nodefaultlib', f'/entry:{entry}', f'/subsystem:{subsystem}',
                   '/machine:x64', '/dynamicbase', '/nxcompat', '/largeaddressaware', '/opt:ref', '/opt:icf',
                   f'/out:{out / name}', *objs, *libraries]
        if res:
            command.append(res)
        if args.debug:
            command.append('/debug')
        run(command)

    executable('lamp-cli.exe', 'start', 'console', common, resource(rc, obj_dir, True))
    executable('lamp.exe', 'ui_start', 'windows', common + [objects[ROOT / 'src/win/ui.s']], resource(rc, obj_dir, False))
    if args.tests:
        executable('engine-probe.exe', 'probe_start', 'console', [objects[ROOT / 'tests/engine-probe.s']] + common)
        executable('ui-preview.exe', 'preview_start', 'console',
                   [objects[ROOT / 'tests/ui-preview.s']] + common + [objects[ROOT / 'src/win/ui.s']])
        executable('ui-list.exe', 'list_start', 'console',
                   [objects[ROOT / 'tests/ui-list.s']] + common + [objects[ROOT / 'src/win/ui.s']])
        executable('ui-driver.exe', 'driver_start', 'console', [objects[ROOT / 'tests/ui-driver.s']] + common)
    for name in ('lamp.exe', 'lamp-cli.exe'):
        print(f'{name} {(out / name).stat().st_size}')


if __name__ == '__main__':
    main()
