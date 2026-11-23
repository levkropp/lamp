#!/usr/bin/env python3
"""Native MP4 -> timestamped AVC -> D3D11, with independent packet/image checks.

Only FFmpeg-encoded, reference-decoded inputs enter the hardware oracle. This
does not exercise a shipping container window or an audio-master clock.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess

from lamp_test import ROOT, WINDOWS, compile_c


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    p = subprocess.run(list(map(str, args)), capture_output=True, timeout=120,
                       **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    assert p.returncode == 0, (args, p.returncode, p.stdout[-1000:], p.stderr[-2000:])
    return p.stdout


def hex_data(value):
    return bytes.fromhex(''.join(line.split(':', 1)[1].split('  ', 1)[0].replace(' ', '') for line in value.splitlines() if ':' in line))


def generate(folder):
    # Same six independently encoded profile/crop/VFR cases used by the packet
    # frontend, followed by fragment-addressing and mixed-track variations.
    for name, profile, w, h, n, extra, options in [
        ('main-b', 'main', 320, 240, 90, 'bframes=3', []),
        ('high-b', 'high', 320, 240, 90, 'bframes=8:b-pyramid=strict', []),
        ('slices', 'high', 192, 112, 60, 'bframes=3:slices=4', []),
        ('crop', 'high', 318, 242, 60, 'bframes=3', []),
        ('vfr', 'main', 96, 64, 30, 'bframes=3', ['-vf', 'setpts=(N+floor(N/7))/(30*TB)', '-fps_mode', 'vfr']),
        ('flat', 'baseline', 64, 64, 45, 'bframes=0', [])]:
        run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
             f'color=color=gray:size={w}x{h}:rate=30' if name == 'flat' else f'testsrc2=size={w}x{h}:rate=30',
             '-frames:v', n, *options, '-c:v', 'libx264', '-profile:v', profile, '-qp', '18',
             '-x264-params', 'threads=1:keyint=30:b-adapt=0:'+extra, folder/(name+'.mp4')])
    configs = [
        ('base', 'frag_keyframe+empty_moov+default_base_moof', False, False),
        ('explicit', 'frag_keyframe+empty_moov', False, False),
        ('dash', 'dash', False, False), ('delay', 'frag_keyframe+delay_moov', False, False),
        ('hybrid', 'frag_keyframe', False, False),
        ('mixed', 'frag_keyframe+empty_moov+default_base_moof', True, False),
        ('interleave', 'frag_keyframe+empty_moov+default_base_moof', True, True),
        ('implicit', 'frag_keyframe+empty_moov+omit_tfhd_offset', True, False),
        ('every-frame', 'frag_every_frame+empty_moov+default_base_moof', True, False)]
    for name, flags, audio, interleave in configs:
        command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y']
        if audio:
            command += ['-f', 'lavfi', '-i', 'anullsrc=cl=stereo:r=48000']
        command += ['-f', 'lavfi', '-i', 'testsrc2=size=192x112:rate=30', '-frames:v', '90']
        if audio:
            command += ['-map', '0:a', '-map', '1:v', '-c:a', 'aac', '-shortest']
        command += ['-c:v', 'libx264', '-profile:v', 'high', '-qp', '20', '-x264-params',
                    'threads=1:keyint=30:scenecut=0:bframes=3:b-adapt=0', '-movflags', flags]
        if interleave:
            command += ['-frag_interleave', '1']
        run(command + [folder/(name+'.mp4')])
    for source in sorted(folder.glob('*.mp4')):
        probe = run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_streams',
                     '-show_packets', '-show_data', '-of', 'json', source])
        source.with_suffix('.probe.json').write_bytes(probe)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', required=True, type=Path)
    parser.add_argument('--fixtures', type=Path, default=ROOT/'tests/generated/mp4-video')
    parser.add_argument('--generate', action='store_true')
    args = parser.parse_args()
    assert WINDOWS, 'D3D11 hardware check requires Windows'
    out, folder = args.bin.resolve(), args.fixtures.resolve()
    work = out/'mp4-video-gpu'; work.mkdir(exist_ok=True)
    folder.mkdir(parents=True, exist_ok=True)
    if args.generate:
        generate(folder)
    cpu, gpu = work/'mp4-video-oracle.exe', work/'h264-packet-oracle.exe'
    objects = out/'obj'; libraries = list(objects.glob('*.lib'))
    compile_c(cpu, [ROOT/'tests/mp4-video-oracle.c'], objects=[objects/'video_mp4.obj', objects/'platform.obj'], libraries=libraries)
    compile_c(gpu, [ROOT/'tests/h264-packet-oracle.c'], objects=[objects/(name+'.obj') for name in ('h264', 'platform', 'video')], libraries=libraries)
    report = dict(result='passed', scope='Native MP4 packet API to D3D11; no audio or shipping video window',
                  ffmpeg=run(['ffmpeg', '-version']).decode().splitlines()[0],
                  inputs=[], sources={}, objects={}, oracles={p.name: sha(p) for p in (cpu, gpu)})
    for pattern in ('video_mp4*', 'h264*'):
        for source in (ROOT/'src').glob(pattern):
            report['sources'][source.relative_to(ROOT).as_posix()] = sha(source)
    for source in (ROOT/'src/win/video.s', ROOT/'tests/mp4-video-oracle.c', ROOT/'tests/h264-packet-oracle.c', Path(__file__)):
        report['sources'][source.relative_to(ROOT).as_posix()] = sha(source)
    for name in ('video_mp4', 'platform', 'h264', 'video'):
        report['objects'][name] = sha(objects/(name+'.obj'))
    for source in sorted(folder.glob('*.mp4')):
        name = source.stem
        probe_path = source.with_suffix('.probe.json')
        info = json.loads(probe_path.read_text())
        assert len(info['streams']) == 1 and info['streams'][0]['codec_type'] == 'video'
        stream = info['streams'][0]; packets = info['packets']
        hpa, native, reference, images = [work/(name+suffix) for suffix in ('.hpa', '.json', '.nv12', '.wv')]
        result = [json.loads(line) for line in run([cpu, source, hpa]).splitlines()]
        native.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        assert result[0]['result'] == 'opened' and result[-1]['result'] == 'passed'
        assert len(result[1:-1]) == len(packets) and bytes.fromhex(result[0]['config']) == hex_data(stream['extradata'])
        payload = source.read_bytes(); scale = Fraction(stream['time_base'])
        for a, b in zip(result[1:-1], packets):
            assert (a['offset'], a['size']) == (int(b['pos']), int(b['size'])), (name, a, b)
            assert payload[a['offset']:a['offset']+a['size']] == hex_data(b['data']), name
            assert a['dts_ns'] == int(b['dts'])*scale*10**9//1 and a['pts_ns'] == int(b['pts'])*scale*10**9//1, name
            assert bool(a['flags'] & 1) == ('K' in b['flags']), name
        # Reference decode precedes hardware; ignore edits to include retained
        # preroll/postroll in the all-coded-picture comparison.
        run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-ignore_editlist', '1', '-i', source,
             '-map', '0:v:0', '-fps_mode', 'passthrough', '-pix_fmt', 'nv12', '-f', 'rawvideo', reference])
        expected_bytes = stream['width']*stream['height']*3//2*len(packets)
        assert reference.stat().st_size == expected_bytes
        check = json.loads(run([gpu, hpa, images, reference]))
        assert check['frames'] == len(packets) and check['image_bytes'] == expected_bytes, check
        report['inputs'].append(dict(name=name, **check, sha256={p.name: sha(p) for p in (source, probe_path, hpa, native, reference, images)}))
        print(name, len(packets), 'native packets and exact NV12 images', flush=True)
    assert report['inputs']
    report['frames'] = sum(x['frames'] for x in report['inputs'])
    report['image_bytes'] = sum(x['image_bytes'] for x in report['inputs'])
    path = out/'mp4-video-gpu-verification.json'
    path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(result='passed', frames=report['frames'], image_bytes=report['image_bytes'], report=str(path))))


if __name__ == '__main__':
    main()
