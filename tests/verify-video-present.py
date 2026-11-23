"""Native Windows GPU presentation and owned hidden-window playback checks."""
import argparse
import ctypes
import hashlib
import json
import platform
import runpy
import shutil
import subprocess
import time
from pathlib import Path
from lamp_test import ROOT, WINDOWS, compile_c
from h264_file_fixtures import annex, cropped_sps, units


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, timeout=45):
    r = subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout,
                       creationflags=subprocess.CREATE_NO_WINDOW)
    assert r.returncode == 0, (args, r.returncode, r.stdout[-3000:], r.stderr[-3000:])
    return r.stdout


def public_window(cli, source):
    """Launch only our child hidden; address its exact PID/class, never desktop input."""
    from ctypes import wintypes as w
    user = ctypes.WinDLL('user32', use_last_error=True)
    callback = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    user.EnumWindows.argtypes = [callback, w.LPARAM]
    user.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]
    user.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, ctypes.c_int]
    user.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, ctypes.c_int]
    user.IsWindowVisible.argtypes = [w.HWND]
    user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
    startup = subprocess.STARTUPINFO(); startup.dwFlags = subprocess.STARTF_USESHOWWINDOW; startup.wShowWindow = 0
    child = subprocess.Popen([str(cli), '--video-play', str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
    owned = []
    @callback
    def visit(hwnd, unused):
        pid = w.DWORD(); user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        name = ctypes.create_unicode_buffer(128)
        if pid.value == child.pid and user.GetClassNameW(hwnd, name, len(name)) and name.value == 'LAMPVideo':
            owned.append(hwnd)
        return True
    try:
        deadline = time.monotonic()+8
        while not owned:
            assert child.poll() is None, child.communicate()
            user.EnumWindows(visit, 0)
            assert time.monotonic() < deadline, 'CLI did not create its video window'
            time.sleep(.01)
        hwnd = owned[0]
        assert not user.IsWindowVisible(hwnd), 'Owned test child must remain hidden'
        assert user.PostMessageW(hwnd, 0x100, 32, 0)
        title = ctypes.create_unicode_buffer(256)
        while True:
            user.GetWindowTextW(hwnd, title, len(title))
            if 'Paused' in title.value:
                break
            assert child.poll() is None and time.monotonic() < deadline
            time.sleep(.01)
        assert user.PostMessageW(hwnd, 0x100, 0xbe, 0)
        time.sleep(.08)
        assert user.PostMessageW(hwnd, 0x10, 0, 0)
        stdout, stderr = child.communicate(timeout=8)
        assert child.returncode == 0, (child.returncode, stdout, stderr)
        return dict(result='passed', scope='Actual --video-play command, PID-owned hidden window, pause title, step request and clean close; direct API oracle establishes exact step counts.')
    finally:
        if child.poll() is None:
            for hwnd in owned:
                user.PostMessageW(hwnd, 0x10, 0, 0)
            try:
                child.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill(); child.communicate()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', required=True, type=Path)
    p.add_argument('--ffmpeg', default='ffmpeg')
    p.add_argument('--report', type=Path, default=ROOT/'reports/video-present-windows-verification.json')
    p.add_argument('--references', action='store_true', help='Also render changing P-picture surfaces and play a reference-dependent sequence.')
    args = p.parse_args()
    assert WINDOWS, 'The presenter requires native Windows and a supported D3D11 hardware adapter.'
    out = args.bin.resolve(); work = out/'video-present'; work.mkdir(exist_ok=True)
    obj = out/'obj'; ffmpeg = Path(shutil.which(args.ffmpeg) or args.ffmpeg).resolve()
    objects = [obj/(n+'.obj') for n in ['h264', 'platform', 'video', 'video_present']]
    libs = [*sorted(obj.glob('*.lib')), 'user32.lib']
    binaries = {}
    for name, extra in [('video-present-oracle', []), ('video-window-oracle', [obj/'video_window.obj'])]:
        binary = work/(name+'.exe')
        compile_c(binary, [ROOT/'tests'/(name+'.c')], objects=[*objects, *extra], libraries=libs)
        binaries[name] = binary
    mock_binary = work/'video-present-mock.exe'
    compile_c(mock_binary, [ROOT/'tests/video-present-mock.c'], objects=[obj/'video_present.obj'])
    mock = json.loads(command([mock_binary]))
    binaries['video-present-mock'] = mock_binary
    version = command([ffmpeg, '-version']).decode().splitlines()[0]
    bits = runpy.run_path(str(ROOT/'tests/verify-windows-video.py'))['Bits']
    images = []
    configs = [(f'{matrix}-{full}', full, matrix, 100, 90, 220, False) for full in (False, True) for matrix in ('smpte170m', 'bt709')]
    configs += [('black-limited', False, 'bt709', 16, 128, 128, False),
                ('white-limited', False, 'bt709', 235, 128, 128, False),
                ('black-full', True, 'bt709', 0, 128, 128, False),
                ('white-full', True, 'bt709', 255, 128, 128, False),
                ('crop-sar', False, 'bt709', 100, 90, 220, True)]
    if args.references:
        configs.append(('p-flat', False, 'bt709', 100, 90, 220, False))
    for name, full, matrix, yy, u, v, crop in configs:
        raw, source, ref, picture = [work/(name+ext) for ext in ('.yuv', '.h264', '.nv12', '.bgra')]
        planes = [bytearray([yy])*4096, bytearray([u])*1024, bytearray([v])*1024]
        if crop:
            for plane, width, border, value in zip(planes, (64, 32, 32), (8, 4, 4), (180, 180, 40)):
                for y in range(width):
                    for x in range(width):
                        if x < border or y < border or x >= width-border or y >= width-border:
                            plane[y*width+x] = value
        count = 24 if name == 'p-flat' else 1
        if count == 1:
            raw.write_bytes(b''.join(planes))
        else:
            raw.write_bytes(b''.join(bytes([32+i*7])*4096+bytes([70+i*3])*1024+bytes([210-i*3])*1024 for i in range(count)))
        command([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pixel_format', 'yuv420p',
                 '-video_size', '64x64', '-i', raw, '-frames:v', str(count), '-c:v', 'libx264', '-profile:v', 'baseline',
                 '-qp', '1', '-x264-params', 'keyint=30:min-keyint=30:scenecut=0:ref=3:threads=1' if count > 1 else 'keyint=1:threads=1', *(['-vf', 'setsar=4/3'] if crop else []),
                 '-colorspace', matrix, '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'pc' if full else 'tv', '-f', 'h264', source])
        if crop:
            source.write_bytes(annex(*[cropped_sps(n, (4, 4, 4, 4), bits) if n[0]&31 == 7 else n for n in units(source.read_bytes())]))
        command([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', source,
                 '-vf', 'scale=in_range=full:out_range=full,format=nv12' if full else 'format=nv12',
                 '-color_range', 'pc' if full else 'tv', '-f', 'rawvideo', ref])
        result = json.loads(command([binaries['video-present-oracle'], source, ref, picture]))
        images.append(dict(name=name, **result, sha256={f.name: sha(f) for f in (raw, source, ref, picture)}))
    timed = work/'timed.h264'
    command([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=30',
             '-frames:v', '90', '-c:v', 'libx264', '-profile:v', 'baseline', '-qp', '20', '-x264-params', 'keyint=60:min-keyint=60:scenecut=0:ref=3:threads=1' if args.references else 'keyint=1:threads=1', '-f', 'h264', timed])
    window = json.loads(command([binaries['video-window-oracle'], timed]))
    # Malformed/unsupported CLI inputs reject before opening a window.
    cli = out/'lamp-cli.exe'
    cli_window = public_window(cli, timed)
    unsupported = []
    for name, profile in [('inter-frame', 'main'), ('high-profile', 'high')]:
        path = work/(name+'.h264')
        command([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=30',
                 '-frames:v', '3', '-c:v', 'libx264', '-profile:v', profile, '-x264-params', 'keyint=30:threads=1', '-f', 'h264', path])
        assert path.stat().st_size > 0
        unsupported.append(path)
    rejects = []
    for argument in [[], *[[path] for path in unsupported]]:
        r = subprocess.run([str(cli), '--video-play', *map(str, argument)], capture_output=True, timeout=8, creationflags=subprocess.CREATE_NO_WINDOW)
        assert r.returncode in (1, 2)
        rejects.append(dict(arguments=[str(x.relative_to(ROOT)) for x in argument], exit_code=r.returncode, message=r.stdout.decode().strip()))
    files = [ROOT/'src/win'/n for n in ['video_present.s', 'video_present.inc', 'video_window.s', 'video_window.inc', 'video_cli.s', 'player.s', 'kernel32.def', 'user32.def']]
    files += [ROOT/'tests'/n for n in ['video-present-oracle.c', 'video-present-mock.c', 'video-window-oracle.c', 'verify-video-present.py', 'verify-h264-file.py', 'verify-runtime.js']]
    files += [ROOT/'tools/build-windows.py', ROOT/'reports/video-present-h264-regression.json']
    files += [*objects, obj/'video_window.obj', obj/'video_cli.obj', *binaries.values(), cli, out/'lamp.exe', ffmpeg, timed, *unsupported]
    report = dict(result='passed', scope='Native hardware NV12-to-BGRA SDR crop/range/matrix/SAR/letterbox/resize and owned hidden-window video-only timing/controls. No real display latency, audio synchronization, seeking, HDR, power or GPU-utilization claims.', reference_dependent_playback=args.references,
                  platform=platform.platform(), reference=version, images=images, window=window, mock=mock, cli_window=cli_window, cli_rejections=rejects,
                  sha256={f.relative_to(ROOT).as_posix() if f.is_relative_to(ROOT) else f.as_posix(): sha(f) for f in files})
    path = args.report
    path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(result='passed', images=sum(x['rendered_images'] for x in images), color_samples=sum(x['color_samples'] for x in images),
                          max_rgb_error=max(x['max_rgb_error'] for x in images), window=window, report=str(path))))


if __name__ == '__main__':
    main()
