#!/usr/bin/env python3
"""Embedded cover art (lamp-cli --cover) against FFmpeg's attached pictures.

usage: python3 tests/verify-cover.py
- FFmpeg-written pictures in MP3 (ID3v2.4, ID3v2.3), FLAC, M4A, AIFF and
  Matroska attachments.
- Written here: ID3v2.2 PIC frames, MIME types in any case or unknown, PNG
  data under a JPEG type, picture types past the list, empty pictures,
  unsynchronised tags and frames (with a data length indicator) holding a
  220 KB picture, pictures in WAVE id3 chunks, before ADTS and before AC-3
  (which FFmpeg reads none for); FLAC PICTURE blocks with case-sensitive
  MIME types and links, METADATA_BLOCK_PICTURE comments in FLAC, Ogg Vorbis
  and Opus (one over many pages); MP4 covr items of every data type;
  Matroska image and font attachments; WavPack APEv2 binary items.
- LAMP's picture is FFmpeg's first front cover ("Cover (front)", an APEv2
  "Cover Art (Front)" item or a Matroska "cover.*" attachment), else its
  first picture; the written bytes equal FFmpeg's stream copy and the type
  its codec. Files without pictures report none; mutated files never crash.
Writes <out>/cover-verification.json.
"""
import base64
import importlib.util
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import Failure, build_lamp, ffmpeg, lamp_cli, main_guard, scratch, write_report

_spec = importlib.util.spec_from_file_location('verify_tags', Path(__file__).resolve().parent / 'verify-tags.py')
_tags = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tags)
text, frame, id3, unsync, synchsafe = _tags.text, _tags.frame, _tags.id3, _tags.unsync, _tags.synchsafe
flac_blocks, flac_file, vorbis_comment = _tags.flac_blocks, _tags.flac_file, _tags.vorbis_comment
boxes, box, item, mp4_with_ilst = _tags.boxes, _tags.box, _tags.item, _tags.mp4_with_ilst
riff_chunks, riff_file, ape_tag = _tags.riff_chunks, _tags.riff_file, _tags.ape_tag
_spec = importlib.util.spec_from_file_location('verify_chapters',
                                               Path(__file__).resolve().parent / 'verify-chapters.py')
_chapters = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_chapters)
element, mkv_append = _chapters.element, _chapters.mkv_append

MIME = {'mjpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'bmp': 'image/bmp', 'tiff': 'image/tiff',
        'webp': 'image/webp'}


def lamp_cover(path, output):
    """lamp-cli --cover: (MIME type, bytes) or None when the file has none."""
    output = Path(output)
    if output.exists():
        output.unlink()
    result = subprocess.run([str(lamp_cli()), '--cover', str(path), str(output)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    lines = result.stdout.decode('utf-8').splitlines()
    if result.returncode == 2 and lines == ['No embedded cover art.']:
        if output.exists():
            raise Failure(f'{Path(path).name}: an output file without a picture')
        return None
    if result.returncode or len(lines) != 1:
        raise Failure(f'{Path(path).name}: lamp-cli --cover exited {result.returncode}: {result.stdout[-300:]}')
    mime, size, unit = lines[0].split(' ')
    data = output.read_bytes()
    if unit != 'bytes' or int(size) != len(data):
        raise Failure(f'{Path(path).name}: unexpected line {lines[0]!r}')
    return mime, data


def ffmpeg_cover(path, work):
    """FFmpeg's attached picture LAMP picks: (MIME type, bytes) or None."""
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Failure(f'ffprobe on {Path(path).name}: {result.stderr[-300:]}')
    pictures = [s for s in json.loads(result.stdout).get('streams', [])
                if s.get('disposition', {}).get('attached_pic')]
    if not pictures:
        return None

    def front(stream):
        tags = stream.get('tags', {})
        return (tags.get('comment') == 'Cover (front)' or 'Cover Art (Front)' in tags or
                tags.get('filename', '').lower().startswith('cover.'))
    chosen = next((s for s in pictures if front(s)), pictures[0])
    codec = chosen['codec_name']
    output = work / 'ffmpeg-cover.bin'           # the raw muxer keeps the packet as it is
    ffmpeg('-i', path, '-map', f'0:{chosen["index"]}', '-c', 'copy', '-frames:v', '1', '-f', 'rawvideo', output)
    return MIME[codec], output.read_bytes()


def flac_picture(kind, mime, data, description=b''):
    return (struct.pack('>II', kind, len(mime)) + mime + struct.pack('>I', len(description)) + description +
            struct.pack('>IIIII', 64, 48, 24, 0, len(data)) + data)


def apic(version, mime, kind, data, description='', encoding=3):
    if version == 2:
        return frame(2, b'PIC', bytes([encoding]) + mime + bytes([kind]) + text(description, encoding)[1:] + data)
    return frame(version, b'APIC', bytes([encoding]) + mime + b'\0' + bytes([kind]) + text(description, encoding)[1:] +
                 data)


def main():
    build_lamp()
    work = scratch('cover')
    checks = []
    rng = random.Random(4004)

    def compare(path, note='', empty=False):
        ours, reference = lamp_cover(path, work / 'lamp-cover.bin'), ffmpeg_cover(path, work)
        if ours != reference:
            describe = lambda c: 'none' if c is None else f'{c[0]}, {len(c[1])} bytes'
            raise Failure(f'{path.name}: {describe(ours)} differs from FFmpeg: {describe(reference)}')
        if (ours is None) != empty:
            raise Failure(f'{path.name}: {"a picture" if ours else "no picture"} where the test expects '
                          f'{"none" if empty else "one"}')
        checks.append({'test': path.name, 'result': 'equal', 'comparator': 'FFmpeg attached picture',
                       'picture': None if ours is None else f'{ours[0]}, {len(ours[1])} bytes', 'note': note})
        print(f'{path.name}: ' + ('no picture, as FFmpeg' if ours is None else
                                  f'{ours[0]} ({len(ours[1])} bytes) equals FFmpeg') +
              (f' ({note})' if note else ''), flush=True)

    # Pictures.
    front, back, big, gif, bmp = (work / n for n in ('front.jpg', 'back.png', 'big.jpg', 'icon.gif', 'logo.bmp'))
    ffmpeg('-f', 'lavfi', '-i', 'testsrc=s=64x48:d=1', '-frames:v', '1', front)
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=s=32x32:d=1', '-frames:v', '1', back)
    ffmpeg('-f', 'lavfi', '-i', 'nullsrc=s=640x480:d=1,geq=random(1)*255:128:128', '-frames:v', '1', '-q:v', '1', big)
    ffmpeg('-f', 'lavfi', '-i', 'testsrc=s=16x16:d=1', '-frames:v', '1', gif)
    ffmpeg('-f', 'lavfi', '-i', 'testsrc=s=24x16:d=1', '-frames:v', '1', bmp)
    jpg, png, large = front.read_bytes(), back.read_bytes(), big.read_bytes()
    if len(large) < 150000:
        raise Failure(f'big.jpg is only {len(large)} bytes')

    def source(seconds=1):
        return ['-f', 'lavfi', '-i', f'sine=f=440:r=44100:d={seconds}']

    # FFmpeg-written pictures: the back cover first, then the front cover.
    pictures = ['-i', back, '-i', front, '-map', '0', '-map', '1', '-map', '2', '-c:v', 'copy',
                '-disposition:v', 'attached_pic', '-metadata:s:v:0', 'comment=Cover (back)',
                '-metadata:s:v:1', 'comment=Cover (front)']
    for name, coding in (('id3v24.mp3', ['-c:a', 'libmp3lame']),
                         ('id3v23.mp3', ['-c:a', 'libmp3lame', '-id3v2_version', '3']),
                         ('native.flac', ['-c:a', 'flac']), ('aac.m4a', ['-c:a', 'aac']),
                         ('id3.aiff', ['-c:a', 'pcm_s16be', '-write_id3v2', '1'])):
        path = work / name
        ffmpeg(*source(), *pictures, *coding, path)
        compare(path, 'FFmpeg-written')
    path = work / 'attachments.mka'
    ffmpeg(*source(), '-attach', back, '-metadata:s:t:0', 'mimetype=image/png', '-attach', front,
           '-metadata:s:t:1', 'mimetype=image/jpeg', '-metadata:s:t:1', 'filename=cover.jpg', '-c:a', 'flac', path)
    compare(path, 'FFmpeg-written attachments')

    # ID3v2 pictures.
    base = work / 'base.mp3'
    ffmpeg(*source(), '-c:a', 'libmp3lame', '-id3v2_version', '0', '-write_xing', '0', base)
    audio = base.read_bytes()
    tags = {
        'upper-mime.mp3': id3(4, [apic(4, b'IMAGE/JPEG', 3, jpg)]),
        'jpg-mime.mp3': id3(4, [apic(4, b'image/jpg', 3, jpg, 'Ünicode', 1)]),
        'unknown-mime.mp3': id3(4, [apic(4, b'image/svg+xml', 3, b'<svg/>'), apic(4, b'image/png', 4, png)]),
        'no-mime.mp3': id3(4, [apic(4, b'', 3, jpg)]),
        'png-as-jpeg.mp3': id3(3, [apic(3, b'image/jpeg', 3, png)]),
        'type-99.mp3': id3(3, [apic(3, b'image/jpeg', 99, jpg), apic(3, b'image/png', 0, png)]),
        'two-fronts.mp3': id3(3, [apic(3, b'image/gif', 3, gif.read_bytes()), apic(3, b'image/png', 3, png)]),
        'bmp.mp3': id3(4, [apic(4, b'image/bmp', 3, bmp.read_bytes())]),
        'empty-picture.mp3': id3(4, [apic(4, b'image/jpeg', 3, b''), apic(4, b'image/png', 6, png)]),
        'v22.mp3': id3(2, [apic(2, b'PNG', 4, png, 'back', 0), apic(2, b'JPG', 3, jpg, 'front', 0)]),
        'v22-gif.mp3': id3(2, [apic(2, b'GIF', 3, jpg, '', 0)]),
        'big-v24.mp3': id3(4, [frame(4, b'TIT2', text('Big')), apic(4, b'image/jpeg', 3, large)]),
    }
    for name, tag in tags.items():
        path = work / name
        path.write_bytes(tag + audio)
        compare(path, 'ID3v2', empty=name in ('no-mime.mp3', 'v22-gif.mp3'))
    path = work / 'unsync-v23.mp3'
    body = id3(3, [apic(3, b'image/jpeg', 3, large)])[10:]
    path.write_bytes(b'ID3\x03\x00\x80' + synchsafe(len(unsync(body))) + unsync(body) + audio)
    compare(path, 'an unsynchronised ID3v2.3 tag')
    path = work / 'unsync-v24.mp3'
    data = b'\x03image/jpeg\0\x03\0' + large
    stored = synchsafe(len(data)) + unsync(data)
    path.write_bytes(id3(4, [b'APIC' + synchsafe(len(stored)) + b'\x00\x03' + stored]) + audio)
    compare(path, 'an unsynchronised ID3v2.4 frame with a data length indicator')
    adts = work / 'base.aac'
    ffmpeg(*source(), '-c:a', 'aac', '-f', 'adts', adts)
    path = work / 'id3.aac'
    path.write_bytes(id3(4, [apic(4, b'image/png', 3, png)]) + adts.read_bytes())
    compare(path, 'before ADTS')
    ac3 = work / 'base.ac3'
    ffmpeg(*source(), '-c:a', 'ac3', ac3)
    path = work / 'id3.ac3'
    path.write_bytes(id3(4, [apic(4, b'image/png', 3, png)]) + ac3.read_bytes())
    compare(path, 'FFmpeg reads no pictures before AC-3', empty=True)
    wav = work / 'base.wav'
    ffmpeg(*source(), '-c:a', 'pcm_s16le', wav)
    path = work / 'id3-chunk.wav'
    path.write_bytes(riff_file(b'WAVE', riff_chunks(wav.read_bytes()) +
                               [(b'id3 ', id3(4, [apic(4, b'image/png', 4, png), apic(4, b'image/jpeg', 3, jpg)]))]))
    compare(path, 'a WAVE id3 chunk')

    # FLAC PICTURE blocks and METADATA_BLOCK_PICTURE comments.
    blocks, frames = flac_blocks((work / 'native.flac').read_bytes())
    streaminfo = [b for b in blocks if b[0] == 0]
    encoded = lambda *a: b'METADATA_BLOCK_PICTURE=' + base64.b64encode(flac_picture(*a))
    flacs = {
        'case-sensitive.flac': [[6, flac_picture(3, b'IMAGE/PNG', png)], [6, flac_picture(4, b'image/png', png)]],
        'png-as-jpeg.flac': [[6, flac_picture(3, b'image/jpeg', png)]],
        'type-99.flac': [[6, flac_picture(99, b'image/jpeg', jpg)]],
        'link.flac': [[6, flac_picture(3, b'-->', b'http://example.com/cover.jpg')]],
        'empty-picture.flac': [[6, flac_picture(3, b'image/jpeg', b'')]],
        'comment-picture.flac': [[4, vorbis_comment([b'TITLE=x', encoded(3, b'image/jpeg', jpg)])]],
        'block-then-comment.flac': [[6, flac_picture(5, b'image/png', png)],
                                    [4, vorbis_comment([encoded(3, b'image/jpeg', jpg)])]],
        'short-length.flac': [[6, flac_picture(3, b'image/jpeg', jpg)[:-100]]],
    }
    for name, extra in flacs.items():
        path = work / name
        path.write_bytes(flac_file(streaminfo + extra, frames))
        compare(path, 'FLAC', empty=name in ('link.flac', 'empty-picture.flac', 'short-length.flac'))
    picture = base64.b64encode(flac_picture(3, b'image/jpeg', large)).decode()
    metadata = work / 'picture.txt'
    metadata.write_text(';FFMETADATA1\nMETADATA_BLOCK_PICTURE=' + picture.replace('=', '\\=') + '\n')
    for name, coding in (('vorbis.ogg', ['-c:a', 'libvorbis']), ('opus.opus', ['-c:a', 'libopus'])):
        path = work / name
        ffmpeg(*source(), '-i', metadata, '-map', '0', '-map_metadata', '1', *coding, path)
        compare(path, 'a comment over many Ogg pages')

    # MP4 covr items.
    m4a = (work / 'base.m4a')
    ffmpeg(*source(), '-c:a', 'aac', m4a)
    data = m4a.read_bytes()

    def covr(*entries):
        return box(b'covr', b''.join(box(b'data', struct.pack('>II', kind, 0) + payload) for kind, payload in entries))
    for name, ilst in (('covr-types.m4a', covr((0, jpg), (1, b'text'), (27, bmp.read_bytes()), (14, png))),
                       ('covr-png-as-jpeg.m4a', covr((13, png))),
                       ('covr-jpeg-as-png.m4a', covr((14, jpg))),
                       ('covr-later.m4a', item(b'\xa9nam', b'Title') + covr((13, jpg)) + covr((14, png)))):
        path = work / name
        path.write_bytes(mp4_with_ilst(data, ilst))
        compare(path, 'MP4 covr')

    # Matroska attachments.
    path = work / 'font-first.mka'
    font = work / 'font.ttf'
    font.write_bytes(b'\0\1\0\0' + bytes(60))
    ffmpeg(*source(), '-attach', font, '-metadata:s:t:0', 'mimetype=application/x-truetype-font',
           '-attach', back, '-metadata:s:t:1', 'mimetype=image/png; x=y', '-attach', front,
           '-metadata:s:t:2', 'mimetype=image/jpeg', '-c:a', 'flac', path)
    compare(path, 'a font and a MIME type with parameters')
    path = work / 'upper-mime.mka'
    ffmpeg(*source(), '-attach', front, '-metadata:s:t:0', 'mimetype=IMAGE/JPEG', '-c:a', 'flac', path)
    compare(path, 'Matroska MIME types are case-sensitive', empty=True)
    nopictures = work / 'nopictures.mka'
    ffmpeg(*source(), '-c:a', 'flac', nopictures)
    attachments = element(0x1941a469, element(0x61a7, element(0x466e, b'cover.png') +
                                              element(0x4660, b'image/png') + element(0x465c, png) +
                                              element(0x46ae, b'\x01')))
    path = work / 'indexed-at-end.mka'
    path.write_bytes(mkv_append(nopictures.read_bytes(), attachments, True))
    compare(path, 'Attachments after the clusters, named by the SeekHead')
    path = work / 'unindexed-at-end.mka'
    path.write_bytes(mkv_append(nopictures.read_bytes(), attachments, False))
    compare(path, 'Attachments after the clusters that no SeekHead names', empty=True)

    # WavPack APEv2 binary items.
    wv = work / 'base.wv'
    ffmpeg(*source(), '-c:a', 'wavpack', wv)
    for name, items, empty in (
            ('ape-cover.wv', [('Cover Art (Back)', b'back.png\0' + png, 2),
                              ('Cover Art (Front)', b'front.jpg\0' + jpg, 2)], False),
            ('ape-other.wv', [('Notes', b'notes.txt\0text', 2), ('Logo', b'LOGO.BMP\0' + bmp.read_bytes(), 2),
                              ('Cover Art (Other)', b'x.jpeg\0' + jpg, 2)], False),
            ('ape-no-name.wv', [('Cover Art (Front)', jpg, 2)], True)):
        path = work / name
        path.write_bytes(wv.read_bytes() + ape_tag([(k, v, f) for k, v, f in items]))
        compare(path, 'APEv2 binary items', empty=empty)

    path = work / 'ape-in.mp3'
    path.write_bytes(audio + ape_tag([('Cover Art (Front)', b'front.jpg\0' + jpg, 2)]))
    compare(path, 'FFmpeg reads no APEv2 tags in MP3', empty=True)

    # Files without pictures.
    for name in ('base.mp3', 'base.wav', 'base.m4a', 'base.wv'):
        compare(work / name, 'no picture', empty=True)

    # Robustness: mutated pictures never crash or hang.
    sources = [work / n for n in ('id3v24.mp3', 'unsync-v24.mp3', 'native.flac', 'comment-picture.flac', 'aac.m4a',
                                  'covr-types.m4a', 'attachments.mka', 'ape-cover.wv', 'id3-chunk.wav', 'vorbis.ogg')]
    mutated, opened = 0, 0
    for n in range(1000):
        origin = sources[n % len(sources)]
        data = bytearray(origin.read_bytes())
        span = min(len(data), 6000)
        tail = origin.suffix in ('.m4a', '.wv', '.wav') and n % 2 == 0
        for _ in range(rng.randrange(1, 10)):
            p = rng.randrange(span)
            data[len(data) - 1 - p if tail else p] = rng.choice((0, 0xff, 0x80, rng.randrange(256)))
        path = work / 'mutated.bin'
        path.write_bytes(bytes(data))
        output = work / 'mutated-cover.bin'
        if output.exists():
            output.unlink()
        try:
            result = subprocess.run([str(lamp_cli()), '--cover', str(path), str(output)], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
        except subprocess.TimeoutExpired:
            raise Failure(f'mutation {n} of {origin.name} hung')
        if result.returncode not in (0, 2):
            (work / f'crash-{n}.bin').write_bytes(bytes(data))
            raise Failure(f'mutation {n} of {origin.name} exited {result.returncode}')
        mutated += 1
        opened += result.returncode == 0
    checks.append({'test': 'mutated pictures', 'result': 'no crash or hang', 'files': mutated, 'written': opened})
    print(f'{mutated} mutated files: no crash or hang ({opened} pictures written)', flush=True)

    write_report('cover', {'result': 'passed', 'checks': checks,
                           'scope': 'Embedded cover art (ID3v2 APIC/PIC, FLAC PICTURE, METADATA_BLOCK_PICTURE, MP4 '
                                    'covr, Matroska attachments, APEv2 binary items) against FFmpeg attached '
                                    'pictures; mutated files.'})
    print(f'Passed {len(checks)} cover art checks.')


if __name__ == '__main__':
    main_guard(main)
