"""Shared helpers for LAMP's verification suites on Linux and Windows.

Reference C code and oracles are compiled only into test executables. The
assembly under test comes from the same objects as the shipping build: the
static Linux objects from build.sh, or the COFF objects from
tools/build-windows.py. Suites link one static library of those objects, so
each oracle pulls in only the assembly it calls.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / 'tests'
WINDOWS = os.name == 'nt'
GENERATED = TESTS / 'generated'
GENERATED_INCLUDE = GENERATED / 'include'
OPUS_ARCHIVE_SHA1 = '86a927223e73d2476646a1b933fcd3fffb6ecc8c'
OPUS_PATCH_SHA1 = '029e3aa88fc342c91e67a21e7bfbc9458661cd5f'
OPUS_REFERENCE = f'RFC6716 + RFC8251 (archive{OPUS_ARCHIVE_SHA1},patch{OPUS_PATCH_SHA1})'


class Failure(Exception):
    """A verification mismatch or a failed build/run step."""


def out_dir():
    """Directory holding lamp-cli, the assembly objects and reports."""
    configured = os.environ.get('LAMP_OUT')
    if configured:
        return Path(configured).resolve()
    return ROOT / ('bin' if WINDOWS else 'build')


def exe(name):
    return out_dir() / (name + ('.exe' if WINDOWS else ''))


def lamp_cli():
    return exe('lamp-cli')


def sha1(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()


def run(args, cwd=ROOT, check=True, env=None, timeout=None, capture=True):
    """Runs a command; returns stripped stdout. Raises Failure on a nonzero exit."""
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, timeout=timeout,
                            stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None)
    output = result.stdout.decode('utf-8', 'replace').strip() if capture else ''
    if check and result.returncode:
        raise Failure(f'{Path(str(args[0])).name} exited {result.returncode}: {output[-4000:]}')
    return output


def node(script, *args):
    return run(['node', TESTS / script, *args])


def ffmpeg(*args):
    run([os.environ.get('FFMPEG', 'ffmpeg'), '-hide_banner', '-loglevel', 'error', '-y', *args])


def write_report(name, report):
    """Writes <out>/<name>-verification.json, as the PowerShell suites did."""
    path = out_dir() / f'{name}-verification.json'
    path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return path


# ---------------------------------------------------------------- references
def _extract(archive, destination, strip=0):
    with tarfile.open(archive) as tar:
        members = []
        for member in tar.getmembers():
            parts = Path(member.name).parts[strip:]
            if not parts:
                continue
            member.name = str(Path(*parts))
            members.append(member)
        tar.extractall(destination, members=members)


def opus_reference(original=False):
    """Extracts the hash-checked RFC 6716 reference, optionally with RFC 8251 applied."""
    parent = TESTS / 'reference'
    archive = parent / 'opus-rfc6716.tar.gz'
    if sha1(archive) != OPUS_ARCHIVE_SHA1:
        raise Failure('Normative Opus reference archive hash differs from RFC6716.')
    reference = parent / 'opus-rfc6716'
    if not (reference / 'celt' / 'entdec.c').exists():
        _extract(archive, parent)
    if original:
        return reference
    patch = parent / 'opus-rfc8251.patch'
    if sha1(patch) != OPUS_PATCH_SHA1:
        raise Failure('Opus decoder update patch hash differs from RFC8251.')
    updated = parent / 'opus-rfc8251'
    marker = updated / '.lamp-rfc8251'
    if not marker.exists():
        if updated.exists():
            raise Failure('Incomplete updated reference directory; inspect tests/reference/opus-rfc8251 before retrying.')
        updated.mkdir()
        _extract(archive, updated, strip=1)
        relative = updated.relative_to(ROOT).as_posix()
        run(['git', '-C', ROOT, 'apply', '--check', f'--directory={relative}', patch])
        run(['git', '-C', ROOT, 'apply', f'--directory={relative}', patch])
        marker.write_text(OPUS_PATCH_SHA1, encoding='utf-8')
    if marker.read_text(encoding='utf-8') != OPUS_PATCH_SHA1:
        raise Failure('Updated reference patch marker differs.')
    return updated


# ---------------------------------------------------------------- assembly
def build_lamp():
    """Builds lamp-cli and the assembly objects; returns the static library path."""
    out = out_dir()
    if WINDOWS:
        python = sys.executable or 'python'
        run([python, ROOT / 'tools/build-windows.py', '--out', out, '--tests'], capture=False)
        objects = sorted((out / 'obj').glob('*.obj'))
        skip = {'player.obj', 'ui.obj', 'engine-probe.obj', 'ui-preview.obj'}
        library = out / 'obj' / 'lamp-test.lib'
        lib = shutil.which('llvm-lib') or shutil.which('lib')
        run([lib, '/nologo', f'/out:{library}', *[o for o in objects if o.name not in skip]])
        return library
    run([ROOT / 'build.sh', out], capture=False)
    objects = [o for o in sorted((out / 'obj').glob('*.o')) if o.name != 'linux_cli.o']
    library = out / 'liblamp-test.a'
    if library.exists() and all(o.stat().st_mtime <= library.stat().st_mtime for o in objects):
        return library
    # Build beside the target and rename, so concurrent suites never link a partial archive.
    temporary = library.with_name(f'{library.name}.{os.getpid()}.tmp')
    run(['ar', 'rcs', temporary, *objects])
    os.replace(temporary, library)
    return library


# ---------------------------------------------------------------- C oracles
def _msvc():
    """Locates cl.exe and its include/lib directories through vswhere."""
    if shutil.which('cl'):
        return {'cl': shutil.which('cl'), 'env': None}
    vswhere = Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    if not vswhere.exists():
        return None
    vs = run([vswhere, '-latest', '-products', '*', '-requires',
              'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'])
    if not vs:
        return None
    vcvars = Path(vs) / 'VC/Auxiliary/Build/vcvars64.bat'
    dump = subprocess.run(f'"{vcvars}" >nul && set', shell=True, stdout=subprocess.PIPE, text=True).stdout
    env = dict(line.split('=', 1) for line in dump.splitlines() if '=' in line)
    cl = shutil.which('cl', path=env.get('Path') or env.get('PATH'))
    return {'cl': cl, 'env': env} if cl else None


def compiler():
    """Returns ('msvc', info) on Windows with Visual C++, else ('gnu', command)."""
    requested = os.environ.get('CC')
    if WINDOWS and not requested:
        info = _msvc()
        if info:
            return 'msvc', info
    for candidate in ([requested] if requested else ['gcc', 'clang', 'cc']):
        if candidate and shutil.which(candidate):
            return 'gnu', candidate
    raise Failure('A C compiler is required for test oracles: gcc or clang, or Visual C++ on Windows.')


def compile_c(output, sources, objects=(), defines=(), includes=(), fp='precise', compile_only=False, libraries=()):
    """Compiles test-only C. fp='strict' disables value-changing float optimizations
    beyond the default; neither mode contracts multiply-adds."""
    kind, tool = compiler()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if kind == 'msvc':
        work = output.parent / (output.stem + '-obj')
        work.mkdir(parents=True, exist_ok=True)
        flags = ['/nologo', '/O2', '/Gy', '/MD', f'/fp:{fp}', *[f'/D{d}' for d in defines], *[f'/I{i}' for i in includes]]
        if compile_only:
            run([tool['cl'], *flags, '/c', f'/Fo{work}\\', *sources], env=tool['env'])
            return sorted(work.glob('*.obj'))
        run([tool['cl'], *flags, f'/Fo{work}\\', f'/Fe{output}', *sources, *objects, *libraries,
             '/link', '/OPT:REF', 'kernel32.lib', 'psapi.lib'], env=tool['env'])
        return output
    flags = ['-O2', '-std=gnu11', '-w', '-Werror=implicit-function-declaration', '-fno-strict-aliasing',
             '-ffp-contract=off', '-fexcess-precision=standard']
    if fp == 'strict':
        flags += ['-frounding-math', '-fsignaling-nans']
    if 'clang' in Path(tool).name:
        flags = [f for f in flags if f not in ('-fexcess-precision=standard', '-fsignaling-nans')]
    flags += [f'-D{d}' for d in defines] + [f'-I{i}' for i in includes] + [f'-I{TESTS}']
    if compile_only:
        work = output.parent / (output.stem + '-obj')
        work.mkdir(parents=True, exist_ok=True)
        produced = []
        for source in sources:
            obj = work / (Path(source).stem + '.o')
            run([tool, *flags, '-c', source, '-o', obj])
            produced.append(obj)
        return produced
    run([tool, *flags, '-o', output, *sources, *objects, *libraries, '-lm'])
    return output


def opus_defines(*extra):
    defines = ['OPUS_BUILD', 'USE_ALLOCA', *extra]
    if WINDOWS:
        defines.append('WIN32')
    return defines


def silk_float_sources(reference):
    """Every non-fixed-point SILK source listed by the reference build."""
    text = (Path(reference) / 'silk_sources.mk').read_text(encoding='utf-8')
    return [Path(reference) / m for m in re.findall(r'(?m)^silk/(?!fixed/)[^\s\\]+\.c', text)]


def main_guard(function):
    """Runs a suite entry point, printing failures without a Python traceback."""
    try:
        function()
    except Failure as error:
        print(f'FAILED: {error}', file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------- lamp-cli checks
def decode_f32(path, output):
    """Exports float32 PCM with lamp-cli; returns its stats line."""
    output = Path(output)
    if output.exists():
        output.unlink()
    result = subprocess.run([str(lamp_cli()), '--decode', str(path), str(output)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    stats = result.stdout.decode('utf-8', 'replace').strip()
    if result.returncode:
        raise Failure(f'Decode failed ({result.returncode}): {Path(path).name} {stats}')
    return stats


def check_file(path):
    """Runs lamp-cli --check; returns (exit code, stats)."""
    result = subprocess.run([str(lamp_cli()), '--check', str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.returncode, result.stdout.decode('utf-8', 'replace').strip()


def stats_frames(stats):
    match = re.search(r' frames=(\d+)', stats)
    return int(match.group(1)) if match else 0


def compare_pcm(ours, reference, min_snr=None, max_error=None):
    """Numerical float32 comparison through compare-pcm.js; returns its measurement."""
    args = ['node', TESTS / 'compare-pcm.js', ours, reference]
    if min_snr is not None:
        args += [str(min_snr), str(max_error)]
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = result.stdout.decode('utf-8', 'replace').strip()
    if result.returncode:
        raise Failure(f'Numerical mismatch {Path(ours).name}: {text}')
    return json.loads(text.splitlines()[-1])


def ffmpeg_version():
    return run([os.environ.get('FFMPEG', 'ffmpeg'), '-version']).splitlines()[0]


def scratch(*parts):
    path = GENERATED.joinpath(*parts)
    path.mkdir(parents=True, exist_ok=True)
    return path


def playback_requested(arguments):
    """Playback checks need an audio device (on Linux, the private test server
    from audio_environment); --skip-playback disables them."""
    return '--skip-playback' not in arguments


def play(path):
    """Plays a file through lamp-cli; returns stats after checking the queue counters."""
    env = audio_environment()
    if env is None:
        raise Failure('Playback needs PulseAudio for its private test server; pass --skip-playback without it.')
    result = subprocess.run([str(lamp_cli()), str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, timeout=60, env=env)
    stats = ' '.join(result.stdout.decode('utf-8', 'replace').split())
    if result.returncode or 'underruns=0 ' not in stats or 'endpoint_dry=0' not in stats:
        raise Failure(f'Playback failed ({result.returncode}): {stats}')
    return stats


def build_oracles(directory, sources, library, includes=(), defines=()):
    """Compiles test oracles that link the assembly library.
    sources maps executable name -> C file in tests/."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name, source in sources.items():
        compile_c(directory / (name + ('.exe' if WINDOWS else '')), [TESTS / source], includes=includes,
                  defines=defines, libraries=[library])
    return directory


def node_suite(script, *args, report=None, destination=None):
    """Runs a Node fixture suite, then copies its JSON report into the output directory."""
    run(['node', TESTS / script, *args], capture=False)
    if report:
        target = out_dir() / (destination or Path(report).name)
        shutil.copyfile(report, target)
        return target


def vorbis_reference():
    """Extracts the hash-pinned Xiph libvorbis/libogg archives; returns (vorbis, ogg, includes)."""
    parent = TESTS / 'reference'
    pins = json.loads((parent / 'vorbis-reference-hashes.json').read_text(encoding='utf-8'))
    for pin in pins['archives']:
        archive = parent / pin['file']
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['sha256']:
            raise Failure(f"Reference archive hash differs: {pin['file']}")
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                parts = Path(member.name).parts
                inside = member.name == pin['directory'] or member.name.startswith(pin['directory'] + '/')
                if not inside or '..' in parts or '\\' in member.name or member.issym() or member.islnk():
                    raise Failure(f'Unsafe reference archive member: {member.name}')
            if not (parent / pin['directory']).exists():
                tar.extractall(parent)
    vorbis, ogg = parent / 'libvorbis-1.3.7', parent / 'libogg-1.3.6'
    includes = [vorbis / 'include', vorbis / 'lib', ogg / 'include']
    if not WINDOWS:
        # libogg's configure normally generates this header outside Windows.
        config = GENERATED_INCLUDE / 'xiph' / 'ogg' / 'config_types.h'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text('#ifndef __CONFIG_TYPES_H__\n#define __CONFIG_TYPES_H__\n#include <stdint.h>\n'
                          'typedef int16_t ogg_int16_t;\ntypedef uint16_t ogg_uint16_t;\ntypedef int32_t ogg_int32_t;\n'
                          'typedef uint32_t ogg_uint32_t;\ntypedef int64_t ogg_int64_t;\ntypedef uint64_t ogg_uint64_t;\n'
                          '#endif\n', encoding='utf-8')
        includes.append(GENERATED_INCLUDE / 'xiph')
    return vorbis, ogg, includes


# ---------------------------------------------------------------- audio server
_audio = {}


def audio_environment():
    """Environment for playback child processes.

    Windows uses the default WASAPI endpoint. On Linux a private PulseAudio
    daemon with a float32 null sink keeps tests silent and capturable; it
    starts on first use and stops at exit. Returns None when unavailable."""
    if WINDOWS:
        return dict(os.environ)
    if 'env' in _audio:
        return _audio['env']
    if os.environ.get('LAMP_TEST_PULSE'):
        # A parent runner already started the private server; reuse it.
        _audio['env'] = dict(os.environ)
        return _audio['env']
    daemon = shutil.which('pulseaudio')
    if not daemon:
        _audio['env'] = None
        return None
    import atexit
    import tempfile
    import time
    runtime = Path(tempfile.mkdtemp(prefix='lamp-pulse-'))
    runtime.chmod(0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), PULSE_SERVER=f'unix:{runtime}/pulse/native',
               HOME=str(runtime), LAMP_TEST_PULSE='1')
    env.pop('PULSE_COOKIE', None)
    subprocess.run([daemon, '-n', '--daemonize=yes', '--exit-idle-time=-1', '--use-pid-file=yes',
                    '-L', 'module-native-protocol-unix',
                    '-L', 'module-null-sink sink_name=lamp_test format=float32le rate=48000 channels=2',
                    '--log-target=file:' + str(runtime / 'pulse.log')], env=env, check=True)
    for _ in range(100):
        if (runtime / 'pulse' / 'native').exists():
            break
        time.sleep(0.05)
    else:
        raise Failure('The private PulseAudio daemon did not start; see ' + str(runtime / 'pulse.log'))

    def stop():
        subprocess.run([daemon, '--kill'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(runtime, ignore_errors=True)
    atexit.register(stop)
    _audio['env'] = env
    return env
