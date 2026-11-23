"""Original test-only Annex B fixtures; synthetic slice bodies never reach a GPU."""
import hashlib
import json
import random
import re
import runpy
import shutil
import struct
import subprocess
from pathlib import Path
from lamp_test import ROOT


class Writer:
    def __init__(self):
        self.bits = ''

    def u(self, value, n=1):
        self.bits += f'{value:0{n}b}'

    def ue(self, value):
        s = f'{value+1:b}'
        self.bits += '0'*(len(s)-1)+s

    def se(self, value):
        self.ue(2*value-1 if value > 0 else -2*value)

    def nal(self, header):
        s = self.bits+'1'
        s += '0'*(-len(s) % 8)
        raw = bytes(int(s[i:i+8], 2) for i in range(0, len(s), 8))
        out, zeros = bytearray([header]), 0
        for byte in raw:
            if zeros == 2 and byte <= 3:
                out.append(3)
                zeros = 0
            out.append(byte)
            zeros = zeros+1 if byte == 0 else 0
        return bytes(out)


def sequence(crop=None, rich=False, poc=2, sar=(4, 3), tick=1001, scale=60000):
    b = Writer()
    for value in (66, 0xc0, 30):
        b.u(value, 8)
    b.ue(0); b.ue(0); b.ue(poc)
    if poc == 0:
        b.ue(0)
    b.ue(1); b.u(0); b.ue(19); b.ue(14); b.u(1); b.u(1)
    b.u(int(crop is not None))
    if crop is not None:
        for value in crop:
            b.ue(value)
    b.u(int(rich))
    if rich:
        b.u(1); b.u(255, 8); b.u(sar[0], 16); b.u(sar[1], 16)
        b.u(1); b.u(0); b.u(1); b.u(5, 3); b.u(1); b.u(1)
        for value in (9, 16, 9):
            b.u(value, 8)
        b.u(1); b.ue(2); b.ue(3)
        b.u(1); b.u(tick, 32); b.u(scale, 32); b.u(1)
        for _ in range(2):
            b.u(1); b.ue(1); b.u(3, 4); b.u(4, 4)
            for j in range(2):
                b.ue(j); b.ue(j+7); b.u(j)
            for value in (23, 23, 23, 24):
                b.u(value, 5)
        b.u(0); b.u(1); b.u(1); b.u(1)
        for value in (0, 0, 16, 16, 0, 1):
            b.ue(value)
    return b.nal(0x67)


def picture(extension=False, entropy=0):
    b = Writer()
    b.ue(0); b.ue(0); b.u(entropy); b.u(0); b.ue(0)
    b.ue(0); b.ue(0); b.u(0); b.u(0, 2)
    b.se(0); b.se(0); b.se(0); b.u(1); b.u(0); b.u(0)
    if extension:
        b.u(0); b.u(0); b.se(-3)
    return b.nal(0x68)


def idr(mb=0, poc=None, pps=0):
    b = Writer()
    b.ue(mb); b.ue(2); b.ue(pps); b.u(0, 4); b.ue(0)
    if poc is not None:
        b.u(poc, 4)
    b.u(0); b.u(0); b.se(0); b.ue(1); b.u(0xabcd, 16)
    return b.nal(0x65)


def annex(*units):
    return b''.join(b'\0\0\0\1'+unit for unit in units)


def units(data):
    return [x.rstrip(b'\0') for x in re.split(b'\x00\x00(?:\x00)?\x01', data) if x]


def cropped_sps(nal, crop, Bits):
    b = Bits(nal)
    assert b.read(8) == 66
    b.read(16); b.ue(); b.ue(); poc = b.ue()
    if poc == 0:
        b.ue()
    else:
        assert poc == 2
    b.ue(); b.read(); b.ue(); b.ue(); assert b.read() == 1; b.read()
    position = b.position
    assert b.read() == 0
    raw_bits = ''.join(f'{x:08b}' for x in b.data)
    stop = raw_bits.rfind('1')
    writer = Writer(); writer.bits = raw_bits[:position]; writer.u(1)
    for value in crop:
        writer.ue(value)
    writer.bits += raw_bits[b.position:stop]
    return writer.nal(nal[0])


def poc_zero(nal, Bits):
    """Valid CAVLC transformation: insert POC syntax, preserve coded coefficients."""
    b = Bits(nal)
    if nal[0]&31 == 7:
        assert b.read(8) == 66
        b.read(16); b.ue(); b.ue()
        start = b.position
        assert b.ue() == 2
        insert = Writer(); insert.ue(0); insert.ue(0)
    else:
        assert nal[0]&31 == 5
        b.ue(); assert b.ue() in (2, 7); b.ue(); b.read(4); b.ue()
        start = b.position
        insert = Writer(); insert.u(0, 4)
    raw_bits = ''.join(f'{x:08b}' for x in b.data)
    stop = raw_bits.rfind('1')
    writer = Writer(); writer.bits = raw_bits[:start]+insert.bits+raw_bits[b.position:stop]
    return writer.nal(nal[0])


def generate(folder, ffmpeg):
    folder.mkdir(parents=True, exist_ok=True)
    legacy = runpy.run_path(str(ROOT/'tests/verify-windows-video.py'))
    fixtures = []
    configs = [(f'base-{w}x{h}', w, h, 8, '', []) for w, h in
               [(64, 64), (192, 112), (320, 240), (640, 368), (1280, 720), (1920, 1088)]]
    configs += [(f'crop-{w}x{h}', w, h, 4, '', []) for w, h in
                [(62, 62), (162, 98), (318, 242), (638, 358), (1280, 718), (1920, 1080)]]
    configs += [(f'slices-{n}', 320, 240, 4, f':slices={n}', []) for n in (2, 4, 8)]
    configs += [('sar-color', 320, 240, 4, ':aud=1', ['-vf', 'setsar=4/3', '-color_range', 'pc',
                 '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709'])]
    configs += [('noise', 640, 368, 3, '', ['-qp', '10'])]
    for name, w, h, count, extra, options in configs:
        source = folder/(name+'.h264')
        if name == 'noise':
            raw = folder/'noise.yuv'; raw.write_bytes(random.Random(0x264).randbytes(w*h*3//2*count))
            input_args = ['-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', f'{w}x{h}', '-framerate', '24', '-i', raw]
        else:
            input_args = ['-f', 'lavfi', '-i', f'testsrc2=size={w}x{h}:rate=24']
        command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *input_args, '-frames:v', count,
                   '-c:v', 'libx264', '-profile:v', 'baseline', '-preset', 'medium', '-x264-params',
                   'keyint=1:scenecut=0:ref=1:bframes=0:cabac=0:8x8dct=0:threads=1:slices=1'+extra,
                   *options, '-pix_fmt', 'yuv420p', '-f', 'h264', source]
        subprocess.run([str(x) for x in command], check=True)
        fixtures.append(dict(name=name, width=w, height=h, frames=count, independent_packet_oracle=name.startswith('base-')))
    base = (folder/'base-320x240.h264').read_bytes()
    transformed = [poc_zero(n, legacy['Bits']) if n[0]&31 in (7, 5) else n for n in units(base)]
    (folder/'poc-type-zero.h264').write_bytes(annex(*transformed))
    fixtures.append(dict(name='poc-type-zero', width=320, height=240, frames=8, independent_packet_oracle=False))
    modified = [cropped_sps(n, (1, 2, 3, 4), legacy['Bits']) if n[0]&31 == 7 else n for n in units(base)]
    (folder/'four-sided-crop.h264').write_bytes(annex(*modified))
    fixtures.append(dict(name='four-sided-crop', width=314, height=226, frames=8, independent_packet_oracle=False))
    source_units = units((folder/'base-64x64.h264').read_bytes())
    (folder/'prefixes.h264').write_bytes(bytes(9)+b''.join((b'\0\0\1' if i%2 else b'\0\0\0\1')+n for i, n in enumerate(source_units))+bytes(11))
    fixtures.append(dict(name='prefixes', width=64, height=64, frames=8, independent_packet_oracle=False))
    for item in fixtures:
        source, ref = folder/(item['name']+'.h264'), folder/(item['name']+'.nv12')
        options = ['-vf', 'scale=in_range=full:out_range=full,format=nv12', '-color_range', 'pc'] if item['name']=='sar-color' else ['-pix_fmt', 'nv12']
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source), *options, '-f', 'rawvideo', str(ref)], check=True)
        if item['independent_packet_oracle']:
            legacy['fixture'](source, source.with_suffix('.wv'))
        assert ref.stat().st_size == item['width']*item['height']*3//2*item['frames']
        item['sha256'] = {x.name: hashlib.sha256(x.read_bytes()).hexdigest() for x in
                          [source, ref, *([source.with_suffix('.wv')] if item['independent_packet_oracle'] else [])]}
    synthetic = []
    cases = [
        ('rich-vui', annex(sequence((1, 2, 3, 4), True), picture(True), idr()), True,
         [320, 240, 314, 226, 2, 6, 4, 3, 1, 9, 16, 9, 1001, 60000, 1]),
        ('poc-zero-type', annex(sequence(poc=0), picture(), idr(poc=3)), True, None),
        ('256-slices', annex(sequence(), picture(), *[idr(i) for i in range(256)]), True, None),
        ('257-slices', annex(sequence(), picture(), *[idr(i) for i in range(257)]), False, None),
        ('missing-sps', annex(picture(), idr()), False, None),
        ('missing-pps', annex(sequence(), idr()), False, None),
        ('missing-picture', annex(sequence(), picture()), False, None),
        ('first-mb', annex(sequence(), picture(), idr(1)), False, None),
        ('slice-order', annex(sequence(), picture(), idr(), idr(2), idr(1)), False, None),
        ('unknown-pps', annex(sequence(), picture(), idr(pps=1)), False, None),
        ('empty-crop', annex(sequence((160, 0, 0, 0)), picture(), idr()), False, None),
        ('bad-sar', annex(sequence(rich=True, sar=(0, 1)), picture(), idr()), False, None),
        ('bad-clock', annex(sequence(rich=True, scale=0), picture(), idr()), False, None),
        ('cabac', annex(sequence(), picture(entropy=1), idr()), False, None),
        ('changed-sps', annex(sequence(), picture(), idr(), sequence(rich=True), picture(), idr()), False, None),
        ('changed-pps', annex(sequence(), picture(), idr(), picture(True), idr()), False, None),
        ('truncated-header', b'\0\0\1\x67\x42', False, None),
        ('golomb-overflow', annex(b'\x67\x42\xc0\x1e'+bytes(8)+b'\x80'), False, None),
        ('large-nal', annex(b'\x0c'+b'\xff'*(16777216+1)), False, None),
    ]
    for name, data, accepted, meta in cases:
        file = folder/(name+'.synthetic'); file.write_bytes(data)
        synthetic.append(dict(name=name, accepted=accepted, metadata=meta, sha256=hashlib.sha256(data).hexdigest()))
    # Genuine unsupported Main/B and High-profile files; CPU preflight must reject.
    negatives = []
    for name, profile, params in [('inter-frame', 'main', 'keyint=30:bframes=2:cabac=1:8x8dct=0'),
                                  ('high-profile', 'high', 'keyint=1:cabac=1:8x8dct=1')]:
        file = folder/(name+'.h264')
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                        'testsrc2=size=320x240:rate=24', '-frames:v', '4', '-c:v', 'libx264',
                        '-profile:v', profile, '-x264-params', params+':threads=1', '-f', 'h264', str(file)], check=True)
        negatives.append(dict(name=name, sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
    manifest = dict(reference=subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0],
                    ffmpeg_executable_sha256=hashlib.sha256(Path(shutil.which(ffmpeg) or ffmpeg).read_bytes()).hexdigest(),
                    fixtures=fixtures, synthetic=synthetic, unsupported=negatives)
    (folder/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    return manifest
