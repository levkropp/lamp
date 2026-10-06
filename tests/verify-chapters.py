#!/usr/bin/env python3
"""Chapters (lamp-cli --chapters) against ffprobe.

usage: python3 tests/verify-chapters.py
- FFmpeg-written chapters with non-ASCII, escaped and missing titles in
  Matroska, WebM, M4A, M4B and QuickTime MOV (chpl and chapter text
  tracks), ID3v2.4 and ID3v2.3 CHAP frames (MP3, ADTS, AIFF) and Opus
  comments.
- Written here: Vorbis chapter comments in every form ogm_chapter reads or
  ignores (FLAC and Ogg); FLAC CUESHEET blocks, alone and merged with
  comments; ID3v2 CHAP frames out of order, without TIT2, with repeated,
  empty or undecodable TIT2, ending before they start, with a sub-frame
  running past the frame or bytes after a text sub-frame's first string
  (FFmpeg reads the next sub-frame from there), unsynchronised, in two tags, before MPEG Layer II,
  in a WAVE id3 chunk and before AC-3 (which FFmpeg reads no chapters for); Matroska editions
  with zero UIDs, missing or empty starts, starts out of order, an end
  before the start, a repeated UID, two displays, nested atoms, a 64-bit UID,
  a second Chapters element and Chapters after the clusters, named by the
  SeekHead or not; MP4 chpl alone, a text track alone, a chpl
  longer than the track, a track sample whose length runs past it, UTF-16
  titles, a video chapter track and two tref/chap IDs.
- Each file's chapters (start in milliseconds, rounded down, and title)
  equal ffprobe's; cases FFmpeg reads differently are checked against
  expected values. Mutated files never crash or hang.
Writes <out>/chapters-verification.json.
"""
import importlib.util
import json
from fractions import Fraction
import math
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
text, frame, id3, unsync = _tags.text, _tags.frame, _tags.id3, _tags.unsync
flac_blocks, flac_file, vorbis_comment = _tags.flac_blocks, _tags.flac_file, _tags.vorbis_comment
boxes, box, riff_chunks, riff_file = _tags.boxes, _tags.box, _tags.riff_chunks, _tags.riff_file

TITLE_MAX = 1024
NS = 1000000000


def shown(title):
    """A title as lamp-cli prints it: to its first NUL, at most TITLE_MAX bytes
    at a character boundary, control characters as spaces."""
    data = title.encode('utf-8').split(b'\0')[0]
    if len(data) > TITLE_MAX:
        data = data[:TITLE_MAX]
        while data and (data[-1] & 0xc0) == 0x80:
            data = data[:-1]
        if data and data[-1] >= 0xc0:
            data = data[:-1]
    return ''.join(' ' if ord(c) < 0x20 else c for c in data.decode('utf-8'))


def lamp_chapters(path):
    result = subprocess.run([str(lamp_cli()), '--chapters', str(path)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if result.returncode:
        raise Failure(f'{Path(path).name}: lamp-cli --chapters exited {result.returncode}: {result.stdout[-300:]}')
    chapters = []
    for line in result.stdout.decode('utf-8').splitlines():
        time, space, title = line.partition(' ')
        hours, minutes, rest = time.split(':')
        seconds, milliseconds = rest.split('.')
        if len(minutes) != 2 or len(seconds) != 2 or len(milliseconds) != 3 or len(hours) < 2 or \
                (space and not title):
            raise Failure(f'{Path(path).name}: unexpected line {line!r}')
        chapters.append((((int(hours) * 60 + int(minutes)) * 60 + int(seconds)) * 1000 + int(milliseconds), title))
    return chapters


def ffprobe_chapters(path):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_chapters', '-of', 'json', str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Failure(f'ffprobe on {Path(path).name}: {result.stderr[-300:]}')
    return [(math.floor(Fraction(c['time_base']) * c['start'] * 1000), shown(c.get('tags', {}).get('title', '')))
            for c in json.loads(result.stdout).get('chapters', [])]


# ---------------------------------------------------------------- ID3v2
def chap(element, start, end, subframes=b''):
    return element + b'\0' + struct.pack('>IIII', start, end, 0xffffffff, 0xffffffff) + subframes


def ctoc(element, children):
    return element + b'\0' + bytes([3, len(children)]) + b''.join(c + b'\0' for c in children)


# ---------------------------------------------------------------- FLAC
def cuesheet(tracks):
    """tracks: (offset in samples, number, ISRC, index points)."""
    out = b'1234567890123'.ljust(128, b'\0') + struct.pack('>Q', 88200) + b'\x80' + bytes(258) + bytes([len(tracks)])
    for offset, number, isrc, indexes in tracks:
        out += struct.pack('>QB', offset, number) + isrc.ljust(12, b'\0') + bytes(14) + bytes([indexes])
        out += b''.join(struct.pack('>QB', 588 * k, k + 1) + bytes(3) for k in range(indexes))
    return out


# ---------------------------------------------------------------- Matroska
def vint(data, pos, mask=True):
    length = 9 - data[pos].bit_length()
    value = int.from_bytes(data[pos:pos + length], 'big')
    return (value & ((1 << (7 * length)) - 1) if mask else value), pos + length


def element(eid, payload):
    for length in range(1, 9):
        if len(payload) < (1 << (7 * length)) - 1:
            size = ((1 << (7 * length)) | len(payload)).to_bytes(length, 'big')
            break
    return eid.to_bytes((eid.bit_length() + 7) // 8, 'big') + size + payload


def uint(value):
    return value if isinstance(value, bytes) else value.to_bytes(max(1, (value.bit_length() + 7) // 8), 'big')


def atom(uid=None, start=None, end=None, titles=(), nested=b''):
    body = b''
    if uid is not None:
        body += element(0x73c4, uint(uid))
    if start is not None:
        body += element(0x91, uint(start))
    if end is not None:
        body += element(0x92, uint(end))
    for title in titles:
        body += element(0x80, element(0x85, title.encode('utf-8')) + element(0x437c, b'eng'))
    return element(0xb6, body + nested)


def edition(uid, *atoms):
    return element(0x45b9, element(0x45bc, uint(uid)) + b''.join(atoms))


def mkv_children(data):
    """The Segment's payload offset and its children as (ID, start, end)."""
    eid, p = vint(data, 0, False)
    size, p = vint(data, p)
    p += size
    eid, p = vint(data, p, False)
    if eid != 0x18538067:
        raise Failure('no Segment')
    size, p = vint(data, p)
    payload, children = p, []
    while p < len(data):
        start = p
        eid, p = vint(data, p, False)
        size, p = vint(data, p)
        children.append((eid, start, p + size))
        p += size
    return payload, children


def void(size):
    if size < 9:
        raise Failure(f'no room for a Void element ({size} bytes)')
    return b'\xec\x01' + (size - 9).to_bytes(7, 'big') + bytes(size - 9)


def mkv_append(data, chapters, index):
    """The file with the level 1 element `chapters` appended to its Segment
    (which runs to the end of the file), named by a new SeekHead entry when
    `index` is set."""
    payload, children = mkv_children(data)
    position = len(data) - payload
    out = bytearray(data + chapters)
    if data[payload - 8] != 1:
        raise Failure('the Segment size is not an 8-byte number')
    out[payload - 8:payload] = ((1 << 56) | (len(out) - payload)).to_bytes(8, 'big')
    if index:
        (eid, start, end), (vid, _, vend) = children[0], children[1]
        if eid != 0x114d9b74 or vid != 0xec:
            raise Failure('no SeekHead and Void at the start')
        p, entries = vint(data, vint(data, start, False)[1])[1], b''
        while p < end:
            e, q = vint(data, p, False)
            size, q = vint(data, q)
            entries += data[p:q + size] if e == 0x4dbb else b''
            p = q + size
        seek_id = chapters[:9 - chapters[0].bit_length()]
        seekhead = element(0x114d9b74, entries + element(0x4dbb, element(0x53ab, seek_id) +
                                                         element(0x53ac, uint(position))))
        out[start:vend] = seekhead + void(vend - start - len(seekhead))
    return bytes(out)


def mkv_replace_chapters(data, replacement):
    """The file with its Chapters element replaced by `replacement`, padded with
    an EBML Void element to the original size so no offset moves."""
    for eid, start, end in mkv_children(data)[1]:
        if eid == 0x1043a770:
            return data[:start] + replacement + void(end - start - len(replacement)) + data[end:]
    raise Failure('no Chapters element')


# ---------------------------------------------------------------- MP4
def mp4_edit(data, edit):
    """The file with moov's children rebuilt by edit(kind, payload) -> payload
    (moov follows mdat, so no sample offset moves)."""
    top = boxes(data)
    kinds = [k for k, _ in top]
    if kinds.index(b'moov') < kinds.index(b'mdat'):
        raise Failure('moov before mdat')
    out = b''
    for kind, payload in top:
        if kind == b'moov':
            payload = b''.join(box(k, p) for k, p in ((k, edit(k, p)) for k, p in boxes(payload)) if p is not None)
        out += box(kind, payload)
    return out


def trak_id(payload):
    tkhd = dict(boxes(payload))[b'tkhd']
    return struct.unpack_from('>I', tkhd, 12 if tkhd[0] == 0 else 20)[0]


def handler(payload):
    return dict(boxes(dict(boxes(payload))[b'mdia']))[b'hdlr'][8:12]


def chpl(entries):
    return box(b'chpl', b'\x01\0\0\0' + bytes(4) + bytes([len(entries)]) +
               b''.join(struct.pack('>Q', start) + bytes([len(t)]) + t for start, t in entries))


def main():
    build_lamp()
    work = scratch('chapters')
    checks = []
    rng = random.Random(2006)

    def compare(path, note='', empty=False):
        ours, reference = lamp_chapters(path), ffprobe_chapters(path)
        if ours != reference:
            raise Failure(f'{path.name}: {str(ours)[:900]} differs from ffprobe {str(reference)[:900]}')
        if bool(ours) == empty:
            raise Failure(f'{path.name}: {"chapters" if empty else "no chapters"} where the test expects '
                          f'{"none" if empty else "some"}')
        checks.append({'test': path.name, 'result': 'equal', 'comparator': 'ffprobe', 'chapters': len(ours),
                       'note': note})
        print(f'{path.name}: {len(ours)} chapters equal ffprobe' + (f' ({note})' if note else ''), flush=True)

    def expect(path, expected, note):
        ours = lamp_chapters(path)
        expected = [(ms, shown(title)) for ms, title in expected]
        if ours != expected:
            raise Failure(f'{path.name}: {str(ours)[:900]} differs from the expected {str(expected)[:900]}')
        checks.append({'test': path.name, 'result': 'equal', 'comparator': 'expected values', 'note': note})
        print(f'{path.name}: {len(ours)} chapters as expected ({note})', flush=True)

    def source(seconds=8):
        return ['-f', 'lavfi', '-i', f'sine=f=440:r=44100:d={seconds}']

    # FFmpeg-written chapters.
    metadata = work / 'chapters.txt'
    titles = ['Intrö 漢字 🎵', 'Second \\= part', None, 'Fourth\\; with a semicolon', 'Last']
    starts = [0, 12345, 25000, 37500, 50009]
    lines = [';FFMETADATA1', 'title=Book']
    for k, (start, title) in enumerate(zip(starts, titles)):
        lines += ['[CHAPTER]', 'TIMEBASE=1/10000', f'START={start}', f'END={(starts + [80000])[k + 1]}']
        lines += [f'title={title}'] if title else []
    metadata.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    written = (('flac.mka', ['-c:a', 'flac']), ('opus.webm', ['-c:a', 'libopus']), ('aac.m4a', ['-c:a', 'aac']),
               ('aac.m4b', ['-c:a', 'aac', '-f', 'ipod']), ('alac.mov', ['-c:a', 'alac']),
               ('id3v24.mp3', ['-c:a', 'libmp3lame']), ('id3v23.mp3', ['-c:a', 'libmp3lame', '-id3v2_version', '3']),
               ('adts.aac', ['-c:a', 'aac', '-f', 'adts', '-write_id3v2', '1']),
               ('id3.aiff', ['-c:a', 'pcm_s16be', '-write_id3v2', '1']), ('opus.opus', ['-c:a', 'libopus']))
    for name, coding in written:
        path = work / name
        ffmpeg(*source(), '-i', metadata, '-map', '0', '-map_metadata', '1', '-map_chapters', '1', *coding, path)
        compare(path, 'FFmpeg-written')

    # Vorbis comments, as ogm_chapter reads them (FLAC and Ogg).
    base_flac = work / 'base.flac'
    ffmpeg(*source(), '-c:a', 'flac', base_flac)
    blocks, frames = flac_blocks(base_flac.read_bytes())
    streaminfo = [b for b in blocks if b[0] == 0]
    comments = [
        'CHAPTER001NAME=Before its chapter (a plain comment)',
        'CHAPTER001=00:00:01.000', 'CHAPTER000=00:00:00.000', 'CHAPTER000NAME=Zerö', 'CHAPTER001NAME=One',
        'chapter002=00:01:02.003', 'Chapter002name=Two, lower case', 'CHAPTER003=1:2:3.4',
        'CHAPTER004= 00:00:05.500', 'CHAPTER004NAME=Leading space', 'CHAPTER005=not a time',
        'CHAPTER0060=00:00:06.000', 'CHAPTER07=00:00:07.000', 'CHAPTER07NAME=Two digits', 'CHAPTER7=00:00:07.500',
        'CHAPTER001=00:00:01.250', 'CHAPTER008=+0:00:08.000', 'CHAPTER009=00:00:09.000 and more',
        'CHAPTER010NAME=No chapter 10', 'CHAPTER011=99:59:59.999', 'CHAPTER011NAME=Tab\there',
        'CHAPTER012=00:00:12', 'CHAPTER013=00:00:13.0', 'CHAPTER013NAME=A=B', 'CHAPTERXYZ=00:00:01.000',
        'TITLE=Chapters in comments']
    path = work / 'comments.flac'
    path.write_bytes(flac_file(streaminfo + [[4, vorbis_comment([c.encode('utf-8') for c in comments])]], frames))
    compare(path, 'chapter comments in every form')
    path = work / 'comments.ogg'
    ffmpeg(*source(2), *[a for c in comments[1:5] + comments[13:16] for a in ('-metadata', c)], '-c:a', 'libvorbis',
           path)
    compare(path, 'Vorbis comments in Ogg')

    # FLAC cue sheets.
    tracks = [(0, 1, b'USABC1234567', 1), (66150, 2, b'', 2), (100000, 3, b'GBXYZ7654321', 1), (352800, 170, b'', 0)]
    path = work / 'cuesheet.flac'
    path.write_bytes(flac_file(streaminfo + [[5, cuesheet(tracks)]], frames))
    compare(path, 'CUESHEET tracks but the lead-out')
    path = work / 'comments-cuesheet.flac'
    entries = [b'CHAPTER001=00:00:00.500', b'CHAPTER001NAME=Comment one', b'CHAPTER005=00:00:04.000',
               b'CHAPTER005NAME=Five']
    path.write_bytes(flac_file(streaminfo + [[4, vorbis_comment(entries)],
                                             [5, cuesheet([(44100, 1, b'', 1), (88200, 2, b'ISRC2', 1),
                                                           (352800, 170, b'', 0)])]], frames))
    compare(path, 'a cue sheet track moves the comment chapter with its number')
    path = work / 'cuesheet-no-index.flac'
    path.write_bytes(flac_file(streaminfo + [[5, cuesheet([(0, 1, b'ONE', 1), (44100, 2, b'TWO', 0),
                                                           (88200, 3, b'THREE', 1), (352800, 170, b'', 0)])]], frames))
    expect(path, [(0, 'ONE')], 'a track without index points ends the cue sheet (FFmpeg rejects the file)')

    # ID3v2 CHAP frames.
    base = work / 'base.mp3'
    ffmpeg(*source(), '-c:a', 'libmp3lame', '-id3v2_version', '0', '-write_xing', '0', base)
    audio = base.read_bytes()

    def chapter_frames(version):
        f = lambda fid, data: frame(version, fid, data)
        return [
            f(b'CTOC', ctoc(b'toc', [b'c5', b'c1'])),
            f(b'CHAP', chap(b'c5', 5000, 6000, f(b'TIT2', text('Fünf')))),
            f(b'CHAP', chap(b'c1', 1000, 2000, f(b'TIT2', text('Eins 🎵', 1)))),
            f(b'CHAP', chap('Kapitel é'.encode('latin-1'), 3000, 4000, f(b'TPE1', text('Artist')))),
            f(b'CHAP', chap(b'c2', 2000, 2500, f(b'TIT2', b'\x05bad\0') + f(b'TIT2', text('Second TIT2', 0)))),
            f(b'CHAP', chap(b'c3', 2500, 3000, f(b'TIT2', text('First')) + f(b'TIT2', text('Second')))),
            f(b'CHAP', chap(b'c4', 4000, 3000, f(b'TIT2', text('Ends before it starts')))),
            f(b'CHAP', chap(b'c6', 6000, 7000, f(b'TIT2', text('Runs past'))[:10] + b'\x03Runs')),
            f(b'CHAP', chap(b'c7', 7000, 8000, f(b'TIT2', b'\x03'))),
            f(b'CHAP', chap(b'c8', 0xff00ff, 0x1ff00ff, f(b'TIT2', text('ÿÿ', 0)))),
            f(b'CHAP', chap(b'c9', 9000, 0xffffffff)),
            f(b'CHAP', chap(b'c10', 10000, 11000, f(b'TIT2', b'\x05') + f(b'TIT2', text('After a bad encoding')))),
            f(b'CHAP', chap(b'c11', 11000, 12000, f(b'TIT2', b'\x03\0') + f(b'TIT2', text('After an empty one')))),
            f(b'CHAP', chap(b'c12', 12000, 13000, f(b'TIT2', b'\x03A\0B\0') + f(b'TPE1', text('Two strings')))),
            f(b'CHAP', chap(b'c13', 13000, 14000, f(b'TIT2', text('Ünicode', 1)) + f(b'TPE1', text('UTF-16')))),
            f(b'CHAP', chap(b'c14', 14000, 15000, f(b'TXXX', text('desc') + 'value'.encode()) +
                            f(b'TIT2', text('After TXXX')))),
            f(b'CHAP', chap(b'c15', 15000, 16000, f(b'TIT2', text('Pad', 0) + bytes(3)) + f(b'TPE1', text('x')))),
            f(b'TIT2', text('Chapters in ID3')),
        ]

    for version in (3, 4):
        path = work / f'chap-v2{version}.mp3'
        path.write_bytes(id3(version, chapter_frames(version)) + audio)
        compare(path, f'ID3v2.{version} CHAP frames')
    path = work / 'chap-unsync.mp3'
    tag = id3(3, chapter_frames(3))
    path.write_bytes(tag[:5] + b'\x80' + _tags.synchsafe(len(unsync(tag[10:]))) + unsync(tag[10:]) + audio)
    compare(path, 'an unsynchronised ID3v2.3 tag')
    path = work / 'chap-two-tags.mp3'
    path.write_bytes(id3(4, [frame(4, b'CHAP', chap(b'a', 0, 1000, frame(4, b'TIT2', text('First tag'))))]) +
                     id3(3, [frame(3, b'CHAP', chap(b'b', 1000, 2000, frame(3, b'TIT2', text('Second tag'))))]) +
                     audio)
    compare(path, 'chapters in two tags in a row')
    layer2 = work / 'base.mp2'
    ffmpeg(*source(), '-c:a', 'mp2', layer2)
    path = work / 'chap-layer2.mp2'
    path.write_bytes(id3(4, chapter_frames(4)) + layer2.read_bytes())
    compare(path, 'before MPEG Layer II')
    wav = work / 'base.wav'
    ffmpeg(*source(), '-c:a', 'pcm_s16le', wav)
    path = work / 'chap-chunk.wav'
    path.write_bytes(riff_file(b'WAVE', [(i, b) for i, b in riff_chunks(wav.read_bytes()) if i != b'LIST'] +
                               [(b'id3 ', id3(4, chapter_frames(4)))]))
    compare(path, 'a WAVE id3 chunk')
    ac3 = work / 'base.ac3'
    ffmpeg(*source(), '-c:a', 'ac3', ac3)
    path = work / 'chap-before.ac3'
    path.write_bytes(id3(4, chapter_frames(4)) + ac3.read_bytes())
    compare(path, 'FFmpeg reads no ID3v2 chapters before AC-3', empty=True)
    path = work / 'chap-long-title.mp3'
    long_title = 'Ä long title ' * 20
    path.write_bytes(id3(4, [frame(4, b'CHAP', chap(b'long', 1500, 2000, frame(4, b'TIT2', text(long_title))))]) +
                     audio)
    expect(path, [(1500, long_title)], 'a sub-frame over 127 bytes with a synchsafe size (FFmpeg drops it)')

    # Matroska chapters.
    lines = [';FFMETADATA1']
    for k in range(40):
        lines += ['[CHAPTER]', 'TIMEBASE=1/1000', f'START={k * 100}', f'END={k * 100 + 100}', 'title=' + 'x' * 200]
    big = work / 'big-chapters.txt'
    big.write_text('\n'.join(lines) + '\n')
    mka = work / 'base.mka'
    ffmpeg(*source(), '-i', big, '-map', '0', '-map_chapters', '1', '-c:a', 'flac', mka)
    long_title = 'Lång titel 漢字 ' * 70
    first = element(0x1043a770, edition(
        1,
        atom(1, 0, titles=['Zero']),
        atom(2, 2 * NS, titles=['Two', 'Two (its second display)']),
        atom(3, 1 * NS, titles=['Earlier than the last: skipped']),
        atom(0, 3 * NS, titles=['UID 0: skipped']),
        atom(4, titles=['No start: skipped']),
        atom(5, b'', titles=['Empty start: skipped']),
        atom(6, 3 * NS, titles=['Three'], nested=atom(60, 3500000000, titles=['Nested: not read'])),
        atom(7, 4 * NS, 3500000000, titles=['Ends before it starts']),
        atom(8, 3800000000, titles=['Before the last start: skipped']),
        atom(0xffffffffffffffff, 5 * NS, titles=[long_title]),
    ) + edition(
        2,
        atom(6, 5500000000),
        atom(9, 6 * NS, titles=['Tab\there']),
        atom(10, 6500000000, titles=['']),
        atom(11, 7 * NS, 7 * NS, titles=['Ends where it starts']),
    ))
    second = element(0x1043a770, edition(3, atom(12, 7500000000, titles=['A second Chapters element'])))
    path = work / 'chapters.mka'
    path.write_bytes(mkv_replace_chapters(mka.read_bytes(), first + second))
    compare(path, 'editions, skipped atoms, a repeated UID, two displays and a second Chapters element')
    nochapters = work / 'nochapters.mka'
    ffmpeg(*source(), '-c:a', 'flac', nochapters)
    late = element(0x1043a770, edition(1, atom(1, 0, titles=['After the clusters']), atom(2, NS, titles=['B'])))
    path = work / 'indexed-at-end.mka'
    path.write_bytes(mkv_append(nochapters.read_bytes(), late, True))
    compare(path, 'Chapters after the clusters, named by the SeekHead')
    path = work / 'unindexed-at-end.mka'
    path.write_bytes(mkv_append(nochapters.read_bytes(), late, False))
    compare(path, 'Chapters after the clusters that no SeekHead names', empty=True)
    path = work / 'front-and-end.mka'
    path.write_bytes(mkv_append(mka.read_bytes(), late, True))
    compare(path, 'Chapters before the clusters and another, indexed, after them')
    path = work / 'zero-starts.mka'
    path.write_bytes(mkv_replace_chapters(mka.read_bytes(), element(0x1043a770, edition(
        1, atom(1, 0, titles=['A']), atom(2, 0, titles=['B']), atom(3, 1, titles=['C']), atom(4, 1, titles=['D'])))))
    compare(path, 'starts at 0 do not count as the last start')

    # MP4 chapters: chpl and text tracks.
    m4a = (work / 'aac.m4a').read_bytes()
    text_ids = []

    def find_text_track(kind, payload):
        if kind == b'trak' and handler(payload) == b'text':
            text_ids.append(trak_id(payload))
        return payload

    mp4_edit(m4a, find_text_track)
    if len(text_ids) != 1:
        raise Failure(f'aac.m4a has {len(text_ids)} text tracks')
    text_id = text_ids[0]

    def without_tref(kind, payload):
        if kind == b'trak':
            payload = b''.join(box(k, p) for k, p in boxes(payload) if k != b'tref')
        return payload

    def without_chpl(kind, payload):
        if kind == b'udta':
            payload = b''.join(box(k, p) for k, p in boxes(payload) if k != b'chpl')
        return payload

    def longer_chpl(kind, payload):
        if kind == b'udta':
            entries = [(k * 15000000, f'chpl {k}'.encode()) for k in range(7)]
            payload = b''.join(box(k, p) if k != b'chpl' else chpl(entries) for k, p in boxes(payload))
        return payload

    def two_ids(kind, payload):
        if kind == b'trak' and b'tref' in dict(boxes(payload)):
            payload = b''.join(box(k, p) if k != b'tref' else box(b'tref', box(b'chap', struct.pack('>II', 99, text_id)))
                               for k, p in boxes(payload))
        return payload

    def video_track(kind, payload):
        if kind == b'trak' and handler(payload) == b'text':
            mdia = dict(boxes(payload))[b'mdia']
            hdlr = dict(boxes(mdia))[b'hdlr']
            mdia = b''.join(box(k, p) if k != b'hdlr' else box(b'hdlr', hdlr[:8] + b'vide' + hdlr[12:])
                            for k, p in boxes(mdia))
            payload = b''.join(box(k, p) if k != b'mdia' else box(b'mdia', mdia) for k, p in boxes(payload))
        return payload

    for name, edit, note in (('chpl-only.m4a', without_tref, 'Nero chpl alone'),
                             ('track-only.m4a', without_chpl, 'a chapter text track alone'),
                             ('longer-chpl.m4a', longer_chpl, 'chpl entries past the track remain'),
                             ('two-ids.m4a', two_ids, 'tref/chap naming a missing track first'),
                             ('video-track.m4a', video_track, 'a video chapter track gives no titles')):
        path = work / name
        path.write_bytes(mp4_edit(m4a, edit))
        compare(path, note)
    data = bytearray(m4a)
    sample = data.find(struct.pack('>H', 13) + b'Second = part')
    if sample < 0:
        raise Failure('no "Second = part" sample')
    data[sample:sample + 2] = b'\x7f\xff'
    path = work / 'long-length.m4a'
    path.write_bytes(bytes(data))
    compare(path, "a sample whose length runs past it keeps chpl's chapter")
    data = bytearray(m4a)
    sample = data.find(b'\x00\x04Last')
    first = data.find('\x00\x12Intrö 漢字 🎵'.encode('utf-8'))
    if sample < 0 or first < 0:
        raise Failure('no "Last" or first sample')
    data[sample + 2:sample + 6] = b'\xfe\xff\x00L'
    data[first:first + 20] = b'\x00\x0e\xff\xfe' + 'Intrö漢'.encode('utf-16-le') + b'\0\0' + bytes(2)
    path = work / 'utf16.m4a'
    path.write_bytes(bytes(data))
    compare(path, 'UTF-16BE and UTF-16LE titles')

    # Files without chapters.
    for name, coding in (('none.flac', ['-c:a', 'flac']), ('none.ogg', ['-c:a', 'libvorbis']),
                         ('none.wav', ['-c:a', 'pcm_s16le']), ('none.m4a', ['-c:a', 'aac'])):
        path = work / name
        ffmpeg(*source(1), '-c:a', coding[1], path)
        compare(path, 'no chapters', empty=True)

    # Robustness: mutated chapters never crash or hang.
    sources = [work / n for n in ('chapters.mka', 'aac.m4a', 'alac.mov', 'longer-chpl.m4a', 'chap-v24.mp3',
                                  'chap-v23.mp3', 'chap-unsync.mp3', 'comments.flac', 'comments-cuesheet.flac',
                                  'opus.opus', 'chap-chunk.wav')]
    regions = {}
    for path in sources:
        data = path.read_bytes()
        if path.suffix in ('.m4a', '.mov'):
            regions[path] = (data.rfind(b'moov') - 4, len(data))
        elif path.suffix == '.mka':
            regions[path] = (0, min(len(data), 24000))
        elif path.suffix == '.wav':
            regions[path] = (data.find(b'id3 '), len(data))
        else:
            regions[path] = (0, min(len(data), 4096))
    mutated, opened = 0, 0
    for n in range(1100):
        origin = sources[n % len(sources)]
        data = bytearray(origin.read_bytes())
        low, high = regions[origin]
        for _ in range(rng.randrange(1, 10)):
            data[rng.randrange(low, high)] = rng.choice((0, 0xff, 0x80, 0x7f, rng.randrange(256)))
        path = work / 'mutated.bin'
        path.write_bytes(bytes(data))
        try:
            result = subprocess.run([str(lamp_cli()), '--chapters', str(path)], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
        except subprocess.TimeoutExpired:
            raise Failure(f'mutation {n} of {origin.name} hung')
        if result.returncode not in (0, 2):
            (work / f'crash-{n}.bin').write_bytes(bytes(data))
            raise Failure(f'mutation {n} of {origin.name} exited {result.returncode}')
        mutated += 1
        opened += result.returncode == 0
    checks.append({'test': 'mutated chapters', 'result': 'no crash or hang', 'files': mutated, 'opened': opened})
    print(f'{mutated} mutated files: no crash or hang ({opened} opened)', flush=True)

    write_report('chapters', {'result': 'passed', 'checks': checks,
                              'scope': 'Chapters (Vorbis comments, FLAC CUESHEET, ID3v2 CHAP, Matroska, MP4 chpl '
                                       'and chapter tracks) against ffprobe; mutated files.'})
    print(f'Passed {len(checks)} chapter checks.')


if __name__ == '__main__':
    main_guard(main)
