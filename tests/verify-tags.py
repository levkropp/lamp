#!/usr/bin/env python3
"""Metadata tags (lamp-cli --tags) against ffprobe.

usage: python3 tests/verify-tags.py
- FFmpeg-written tags with non-ASCII values in every container LAMP reads
  tags from: ID3v2.4 and ID3v2.3 (MP3, ADTS, AIFF), ID3v1, APEv2 (WavPack),
  Vorbis comments (FLAC, Ogg Vorbis, Opus, FLAC in Ogg), MP4 ilst, Matroska,
  RIFF INFO (WAVE, AVI) and CAF info.
- Tags written here: ID3v2.2, unsynchronisation (whole tag and per frame),
  extended headers, data length indicators, encrypted frames, every text
  encoding with surrogate pairs, described and plain comments, TXXX, repeated
  frames and tags, all 192 numeric genres; ID3v1.1; APEv2 replacing ID3v2;
  repeated and differently cased Vorbis comments and a comment packet over
  two Ogg pages; MP4 genre numbers and track/disc forms; Matroska track
  tags; WAVE id3 chunks; CAF's Apple keys.
- Each file's ten keys equal ffprobe's (format tags, or the stream's for
  Ogg), keys mapped as FFmpeg names them; cases FFmpeg reads differently are
  checked against expected values. Mutated tags never crash or hang.
Writes <out>/tags-verification.json.
"""
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, ffmpeg, lamp_cli, main_guard, scratch, write_report,
                       metadata_vorbis_encoder)

KEYS = ('title', 'artist', 'album', 'album_artist', 'date', 'track', 'disc', 'genre', 'comment', 'composer')
ALIASES = {'albumartist': 'album_artist', 'tracknumber': 'track', 'discnumber': 'disc', 'description': 'comment',
           'year': 'date', 'part_number': 'track', 'track number': 'track', 'comments': 'comment'}
VALUE_MAX = 4096
sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util
_spec = importlib.util.spec_from_file_location('genres', Path(__file__).resolve().parent / 'generate-genre-table.py')
_genres = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_genres)
GENRES = _genres.GENRES


def shown(value):
    """A value as lamp-cli prints it: at most VALUE_MAX bytes at a character
    boundary, control characters as spaces."""
    data = value.encode('utf-8')
    if len(data) > VALUE_MAX:
        data = data[:VALUE_MAX]
        while data and (data[-1] & 0xc0) == 0x80:
            data = data[:-1]
        if data and data[-1] >= 0xc0:
            data = data[:-1]
        value = data.decode('utf-8')
    return ''.join(' ' if ord(c) < 0x20 else c for c in value)


def lamp_tags(path):
    result = subprocess.run([str(lamp_cli()), '--tags', str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise Failure(f'{Path(path).name}: lamp-cli --tags exited {result.returncode}: {result.stdout[-300:]}')
    tags = {}
    for line in result.stdout.decode('utf-8').splitlines():
        key, _, value = line.partition('=')
        if key not in KEYS or key in tags:
            raise Failure(f'{Path(path).name}: unexpected line {line!r}')
        tags[key] = value
    return tags


def ffprobe_tags(path, scope='format', aliases=None):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format_tags:stream_tags', '-of', 'json',
                             str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Failure(f'ffprobe on {Path(path).name}: {result.stderr[-300:]}')
    data = json.loads(result.stdout)
    tags = (data.get('streams') or [{}])[0].get('tags', {}) if scope == 'stream' else \
        data.get('format', {}).get('tags', {})
    names = dict(ALIASES, **(aliases or {}))
    out = {}
    for key, value in tags.items():
        key = names.get(key.lower(), key.lower())
        if key in KEYS and value != '':
            if key in out:
                raise Failure(f'{Path(path).name}: ffprobe has {key} twice')
            out[key] = shown(value)
    return out


# ---------------------------------------------------------------- ID3v2
def synchsafe(n):
    return bytes([(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127])


def text(value, encoding=3, terminate=True):
    if encoding == 0:
        data = value.encode('latin-1') + (b'\0' if terminate else b'')
    elif encoding == 1:
        data = b'\xff\xfe' + value.encode('utf-16-le') + (b'\0\0' if terminate else b'')
    elif encoding == 'bom-be':
        encoding, data = 1, b'\xfe\xff' + value.encode('utf-16-be') + (b'\0\0' if terminate else b'')
    elif encoding == 2:
        data = value.encode('utf-16-be') + (b'\0\0' if terminate else b'')
    else:
        data = value.encode('utf-8') + (b'\0' if terminate else b'')
    return bytes([encoding]) + data


def unsync(data):
    return data.replace(b'\xff', b'\xff\x00')


def frame(version, fid, data, flags=0):
    if version == 2:
        return fid + len(data).to_bytes(3, 'big') + data
    size = synchsafe(len(data)) if version == 4 else struct.pack('>I', len(data))
    return fid + size + struct.pack('>H', flags) + data


def id3(version, frames, flags=0, extended=b'', padding=16):
    body = extended + b''.join(frames) + bytes(padding)
    return b'ID3' + bytes([version, 0, flags]) + synchsafe(len(body)) + body


def comment(version, value, description='', encoding=3, language=b'eng'):
    return text(description, encoding)[0:1] + language + text(description, encoding)[1:] + text(value, encoding)[1:]


def ape_tag(items, header=True):
    body = b''
    for key, value, flags in items:
        body += struct.pack('<II', len(value), flags) + key.encode('ascii') + b'\0' + value
    size = len(body) + 32
    footer = b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0x80000000 if header else 0) + bytes(8)
    head = b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0xa0000000) + bytes(8) if header else b''
    return head + body + footer


def id3v1(title, artist, album, year, comment_text, track, genre):
    def field(value, n):
        return value.encode('latin-1')[:n].ljust(n, b' ' if value else b'\0')
    tail = field(comment_text, 28) + b'\0' + bytes([track]) if track else field(comment_text, 30)
    return b'TAG' + field(title, 30) + field(artist, 30) + field(album, 30) + field(year, 4) + tail + bytes([genre])


# ---------------------------------------------------------------- containers
def flac_blocks(data):
    pos, blocks = 4, []
    while True:
        head = data[pos]
        size = int.from_bytes(data[pos + 1:pos + 4], 'big')
        blocks.append([head & 0x7f, data[pos + 4:pos + 4 + size]])
        pos += 4 + size
        if head & 0x80:
            return blocks, data[pos:]


def flac_file(blocks, frames):
    out = b'fLaC'
    for k, (kind, body) in enumerate(blocks):
        out += bytes([kind | (0x80 if k == len(blocks) - 1 else 0)]) + len(body).to_bytes(3, 'big') + body
    return out + frames


def vorbis_comment(entries, vendor=b'test'):
    out = struct.pack('<I', len(vendor)) + vendor + struct.pack('<I', len(entries))
    for entry in entries:
        out += struct.pack('<I', len(entry)) + entry
    return out


def boxes(data, pos=0, end=None):
    end = len(data) if end is None else end
    out = []
    while pos + 8 <= end:
        size, kind = struct.unpack_from('>I4s', data, pos)
        size = size or end - pos
        out.append((kind, data[pos + 8:pos + size]))
        pos += size
    return out


def box(kind, payload):
    return struct.pack('>I', 8 + len(payload)) + kind + payload


def mp4_with_ilst(data, ilst, quicktime=False):
    """An MP4 file whose moov (after mdat) gets a new udta/meta/ilst."""
    top = boxes(data)
    if [k for k, _ in top].index(b'moov') < [k for k, _ in top].index(b'mdat'):
        raise Failure('moov before mdat')
    out = b''
    for kind, payload in top:
        if kind == b'moov':
            children = [(k, p) for k, p in boxes(payload) if k != b'udta']
            hdlr = box(b'hdlr', bytes(8) + b'mdirappl' + bytes(9))
            meta = box(b'meta', (b'' if quicktime else bytes(4)) + hdlr + box(b'ilst', ilst))
            payload = b''.join(box(k, p) for k, p in children) + box(b'udta', meta)
        out += box(kind, payload)
    return out


def item(kind, payload, data_type=1):
    return box(kind, box(b'data', struct.pack('>II', data_type, 0) + payload))


def riff_chunks(data):
    pos, out = 12, []
    while pos + 8 <= len(data):
        ident, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        out.append((ident, data[pos + 8:pos + 8 + size]))
        pos += 8 + size + (size & 1)
    return out


def riff_file(form, chunks):
    body = b''.join(i + struct.pack('<I', len(b)) + b + (b'\0' if len(b) & 1 else b'') for i, b in chunks)
    return b'RIFF' + struct.pack('<I', 4 + len(body)) + form + body


def caf_chunks(data):
    pos, out = 8, []
    while pos + 12 <= len(data):
        kind, size = data[pos:pos + 4], struct.unpack_from('>q', data, pos + 4)[0]
        if size < 0:
            out.append((kind, data[pos + 12:]))
            break
        out.append((kind, data[pos + 12:pos + 12 + size]))
        pos += 12 + size
    return out


def caf_file(chunks):
    return b'caff\x00\x01\x00\x00' + b''.join(k + struct.pack('>q', len(b)) + b for k, b in chunks)


def main():
    build_lamp()
    work = scratch('tags')
    checks = []
    rng = random.Random(1006)
    meta = {'title': 'Tïtle 漢字 🎵', 'artist': 'Ärtist', 'album': 'Albüm', 'album_artist': 'Album Ärtist',
            'date': '2024-05-17', 'track': '3/12', 'disc': '1/2', 'genre': 'Rock', 'comment': 'Cömment\nline two',
            'composer': 'Cömposer'}
    options = [a for key, value in meta.items() for a in ('-metadata', f'{key}={value}')]

    def source(seconds=0.3, channels=2):
        return ['-f', 'lavfi', '-i', f'sine=f=440:r=44100:d={seconds}', '-ac', str(channels)]

    def compare(path, scope='format', aliases=None, note=''):
        ours, reference = lamp_tags(path), ffprobe_tags(path, scope, aliases)
        if ours != reference:
            raise Failure(f'{path.name}: {str(ours)[:600]} differs from ffprobe {str(reference)[:600]}')
        if not ours:
            raise Failure(f'{path.name}: no tags to compare')
        checks.append({'test': path.name, 'result': 'equal', 'comparator': 'ffprobe', 'keys': sorted(ours),
                       'note': note})
        print(f'{path.name}: {len(ours)} tags equal ffprobe' + (f' ({note})' if note else ''), flush=True)

    def expect(path, expected, note):
        ours = lamp_tags(path)
        expected = {k: shown(v) for k, v in expected.items()}
        if ours != expected:
            raise Failure(f'{path.name}: {str(ours)[:600]} differs from the expected {str(expected)[:600]}')
        checks.append({'test': path.name, 'result': 'equal', 'comparator': 'expected values', 'note': note})
        print(f'{path.name}: {len(ours)} tags as expected ({note})', flush=True)

    # FFmpeg-written tags.
    for name, coding in (('id3v24.mp3', ['-c:a', 'libmp3lame']),
                         ('id3v23.mp3', ['-c:a', 'libmp3lame', '-id3v2_version', '3']),
                         ('id3v2-and-v1.mp3', ['-c:a', 'libmp3lame', '-write_id3v1', '1']),
                         ('id3v1.mp3', ['-c:a', 'libmp3lame', '-id3v2_version', '0', '-write_id3v1', '1']),
                         ('adts.aac', ['-c:a', 'aac', '-f', 'adts', '-write_id3v2', '1']),
                         ('native.flac', ['-c:a', 'flac']),
                         ('vorbis.ogg', metadata_vorbis_encoder()),
                         ('opus.opus', ['-c:a', 'libopus']),
                         ('flac.oga', ['-c:a', 'flac', '-f', 'ogg']),
                         ('aac.m4a', ['-c:a', 'aac']),
                         ('alac.mov', ['-c:a', 'alac']),
                         ('audio.mka', ['-c:a', 'flac']),
                         ('opus.webm', ['-c:a', 'libopus']),
                         ('pcm.wav', ['-c:a', 'pcm_s16le']),
                         ('pcm.avi', ['-c:a', 'pcm_s16le']),
                         ('pcm.caf', ['-c:a', 'pcm_s16le']),
                         ('wavpack.wv', ['-c:a', 'wavpack']),
                         ('id3.aiff', ['-c:a', 'pcm_s16be', '-write_id3v2', '1']),
                         ('text.aiff', ['-c:a', 'pcm_s16be', '-metadata', 'author=Äuthor']),
                         ('annotation.au', ['-c:a', 'pcm_s16be'])):
        path = work / name
        values = options if name != 'id3v1.mp3' else [a for key in ('title', 'artist', 'album', 'date', 'comment',
                                                                     'track', 'genre')
                                                       for a in ('-metadata', f'{key}={meta[key][:28]}')]
        ffmpeg(*source(), *values, *coding, path)
        scope = 'stream' if name.endswith(('.ogg', '.opus', '.oga')) else 'format'
        compare(path, scope, {'author': 'artist'} if name.endswith('.aiff') else None)

    base = work / 'base.mp3'
    ffmpeg(*source(), '-c:a', 'libmp3lame', '-id3v2_version', '0', '-write_xing', '0', base)
    audio = base.read_bytes()
    layer2 = work / 'base.mp2'
    ffmpeg(*source(), '-c:a', 'mp2', layer2)
    tagged = (work / 'id3v24.mp3').read_bytes()
    size = tagged[6] << 21 | tagged[7] << 14 | tagged[8] << 7 | tagged[9]
    path = work / 'id3v24.mp2'
    path.write_bytes(tagged[:10 + size] + layer2.read_bytes())
    compare(path, note="FFmpeg's ID3v2.4 tag on Layer II")

    # ID3v2 written here.
    unicode_text = 'Ünïcödé 𝄞 ∑ ÿ'
    variants = {
        'v22.mp3': id3(2, [frame(2, b'TT2', text('Title two')), frame(2, b'TP1', text('Artist', 0)),
                           frame(2, b'TAL', text(unicode_text, 1)), frame(2, b'TYE', text('1999')),
                           frame(2, b'TRK', text('7')), frame(2, b'TCO', text('(17)')),
                           frame(2, b'TCM', text('Writer', 2)), frame(2, b'COM', comment(2, 'Two comment'))]),
        'v23-encodings.mp3': id3(3, [frame(3, b'TIT2', text(unicode_text, 1)),
                                     frame(3, b'TPE1', text(unicode_text, 'bom-be')),
                                     frame(3, b'TALB', text('Älbum ÿ', 0)), frame(3, b'TPE2', text(unicode_text, 2)),
                                     frame(3, b'TYER', text('2001', 0)), frame(3, b'TPOS', text('2/3', 1)),
                                     frame(3, b'TCON', text('Jazz', 0)),
                                     frame(3, b'COMM', comment(3, unicode_text, 'described', 1)),
                                     frame(3, b'COMM', comment(3, 'Plain ÿ', '', 1, b'deu'))]),
        # Frame headers stay as they are and sizes count the stored bytes,
        # as FFmpeg reads whole-tag unsynchronisation.
        'v23-unsync.mp3': id3(3, [frame(3, b'TIT2', unsync(text('ÿÿ Title ÿ', 0))),
                                  frame(3, b'TPE1', unsync(text('Ärtist ÿ', 1)))], flags=0x80),
        'v23-extended.mp3': id3(3, [frame(3, b'TIT2', text('Extended'))], flags=0x40,
                                extended=struct.pack('>IHI', 6, 0, 0)),
        'v24-frame-unsync.mp3': id3(4, [frame(4, b'TIT2', unsync(text('ÿ Frame ÿ unsync', 0)), flags=0x0002),
                                        frame(4, b'TPE1', struct.pack('>I', 9) + text('Artist4', 0), flags=0x0001),
                                        frame(4, b'TALB', text('Kept'), flags=0x0000)]),
        'v24-extended.mp3': id3(4, [frame(4, b'TIT2', text('Extended four'))], flags=0x40,
                                extended=synchsafe(6) + b'\x01\x00'),
        'v24-encrypted.mp3': id3(4, [frame(4, b'TIT2', b'\x01' + text('Secret'), flags=0x0004),
                                     frame(4, b'TIT2', text('Open title')), frame(4, b'TPE1', text('Ärtist'))]),
        'v24-txxx.mp3': id3(4, [frame(4, b'TXXX', text('comment') + text('User comment')[1:]),
                                frame(4, b'TXXX', text('ALBUM_ARTIST') + text('User album artist')[1:]),
                                frame(4, b'TXXX', text('other') + text('ignored')[1:]),
                                frame(4, b'TIT2', text('First')), frame(4, b'TIT2', text('Second')),
                                frame(4, b'TRCK', text('5/9')), frame(4, b'TCON', text('(13)Pop'))]),
        'v24-genres.mp3': id3(4, [frame(4, b'TCON', text(' 7')), frame(4, b'TIT2', text('Genre with space'))]),
        'two-tags.mp3': id3(4, [frame(4, b'TIT2', text('First tag'))]) + id3(3, [frame(3, b'TPE1', text('Second'))]),
    }
    for name, tag in variants.items():
        path = work / name
        path.write_bytes(tag + audio)
        # FFmpeg leaves ID3v2.2 TCM and TPA under their frame IDs.
        compare(path, aliases={'tcm': 'composer', 'tpa': 'disc'} if name == 'v22.mp3' else None,
                note='ID3v2 written here')
    for name, value in (('genre-raw.mp3', '(200)'), ('genre-word.mp3', 'abc'), ('genre-negative.mp3', '-3'),
                        ('genre-text.mp3', '17abc')):
        path = work / name
        path.write_bytes(id3(4, [frame(4, b'TCON', text(value))]) + audio)
        compare(path, note=f'genre {value!r}')
    for n in range(192):
        path = work / 'genre.mp3'
        path.write_bytes(id3(3 if n % 2 else 4, [frame(3 if n % 2 else 4, b'TCON', text(f'({n})' if n % 3 else str(n)))])
                         + audio)
        ours, reference = lamp_tags(path), ffprobe_tags(path)
        if n == 133:                      # renamed; FFmpeg 6.1 keeps the original
            reference = {'genre': 'Afro-Punk'}
        if ours != reference or ours.get('genre') != GENRES[n]:
            raise Failure(f'genre {n}: {ours} against ffprobe {reference}')
    checks.append({'test': 'ID3v1 genres 0-191 in TCON', 'result': 'equal', 'comparator': 'ffprobe',
                   'note': 'genre 133 is "Afro-Punk"'})
    print('192 numeric genres equal ffprobe (133 renamed)', flush=True)

    # ID3v1 and APEv2.
    tag = id3v1('Vintage title   ', 'Artist', 'Album', '1987', 'Comment', 9, 17)
    path = work / 'v11.mp3'
    path.write_bytes(audio + tag)
    compare(path, note='ID3v1.1 with a track and genre')
    path = work / 'v1-latin1.mp3'
    path.write_bytes(audio + id3v1('Vïntage ÿ', 'Ärtist', '', '', '', 0, 12))
    expect(path, {'title': 'Vïntage ÿ', 'artist': 'Ärtist', 'genre': 'Other'},
           'ID3v1 Latin-1 text (FFmpeg passes the bytes through)')
    path = work / 'v1-genre.mp3'
    path.write_bytes(audio + id3v1('Title', '', '', '', '', 0, 255))
    compare(path, note='ID3v1 without a genre')
    ape = ape_tag([('Title', 'APE tïtle'.encode(), 0), ('Artist', 'APE ärtist'.encode(), 0),
                   ('Year', b'2010', 0), ('Track', b'4', 0), ('Album Artist', b'Band', 0),
                   ('Cover Art (Front)', b'x' * 64, 2), ('Genre', b'Ambient\0Second', 0)])
    # FFmpeg 6.1 reads no APEv2 tags in MP3; LAMP fills the keys ID3v2 left.
    path = work / 'id3-ape.mp3'
    path.write_bytes(id3(4, [frame(4, b'TIT2', text('ID3 title')), frame(4, b'TALB', text('ID3 album'))]) + audio + ape)
    expect(path, {'title': 'ID3 title', 'album': 'ID3 album', 'artist': 'APE ärtist', 'album_artist': 'Band',
                   'date': '2010', 'track': '4', 'genre': 'Ambient'}, 'APEv2 fills keys ID3v2 left empty')
    path = work / 'ape-only.mp3'
    path.write_bytes(audio + ape)
    expect(path, {'title': 'APE tïtle', 'artist': 'APE ärtist', 'album_artist': 'Band', 'date': '2010',
                  'track': '4', 'genre': 'Ambient'}, 'APEv2 alone, binary items skipped')
    path = work / 'ape-v1.mp3'
    path.write_bytes(audio + ape_tag([('Title', b'APE before ID3v1', 0)], header=False) + id3v1('v1', 'v1', '', '', '',
                                                                                              0, 1))
    expect(path, {'title': 'APE before ID3v1'}, 'APEv2 before ID3v1 (FFmpeg 6.1 reads no APEv2 in MP3)')

    # Vorbis comments.
    flac = (work / 'native.flac').read_bytes()
    blocks, frames = flac_blocks(flac)
    entries = [b'TITLE=One', b'artist=First', b'ARTIST=Second', b'Album=Mixed case', b'TRACKNUMBER=2',
               b'DISCNUMBER=1', b'DESCRIPTION=Described', 'GENRE=Ümlaut'.encode(), b'NOEQUALS', b'=empty key',
               b'ALBUMARTIST=Band', b'DATE=2020']
    for k, (kind, body) in enumerate(blocks):
        if kind == 4:
            blocks[k][1] = vorbis_comment(entries)
    path = work / 'comments.flac'
    path.write_bytes(flac_file(blocks, frames))
    compare(path, note='repeated, cased and malformed comments')
    path = work / 'long.ogg'
    ffmpeg(*source(), '-metadata', 'comment=' + 'Lóng ' * 14000, '-metadata', 'title=Long', *metadata_vorbis_encoder(), path)
    compare(path, 'stream', note='a comment packet over two pages, cut at 4096 bytes')

    # MP4 items.
    m4a = (work / 'aac.m4a').read_bytes()
    ilst = (item(b'\xa9nam', 'MP4 tïtle'.encode()) + item(b'gnre', b'\x00\x12', 0) +
            item(b'trkn', struct.pack('>HHHH', 0, 7, 0, 0), 0) + item(b'disk', struct.pack('>HHH', 0, 1, 2), 0) +
            item(b'\xa9wrt', b'Writer') + item(b'aART', b'Band') + item(b'\xa9day', b'1990-01-02') +
            item(b'\xa9cmt', b'Note') + item(b'\xa9ART', b'Artist', 2))
    for name, quicktime in (('items.m4a', False), ('items-qt.m4a', True)):
        path = work / name
        path.write_bytes(mp4_with_ilst(m4a, ilst, quicktime))
        compare(path, note='genre number, track without total' + (', QuickTime meta' if quicktime else ''))

    # Matroska: a track tag stays the track's; WAVE id3 chunks; CAF Apple keys.
    path = work / 'track-tags.mka'
    ffmpeg(*source(), '-metadata', 'title=Global', '-metadata', 'artist=Global artist', '-metadata:s:a:0',
           'title=Track title', '-metadata:s:a:0', 'composer=Track composer', '-c:a', 'flac', path)
    compare(path, note='track-targeted tags skipped')
    wav = (work / 'pcm.wav').read_bytes()
    chunks = [(i, b) for i, b in riff_chunks(wav) if i != b'LIST'] + [
        (b'id3 ', id3(3, [frame(3, b'TIT2', text('Chunk title', 1)), frame(3, b'TCON', text('(8)'))]))]
    path = work / 'id3-chunk.wav'
    path.write_bytes(riff_file(b'WAVE', chunks))
    compare(path, note='an id3 chunk')
    caf = (work / 'pcm.caf').read_bytes()
    info = [b'title', 'Cäf'.encode(), b'artist', b'Apple artist', b'year', b'2003', b'track number', b'11',
            b'comments', b'Apple comment', b'approximate duration in seconds', b'0.3']
    info_chunk = struct.pack('>I', len(info) // 2) + b''.join(v + b'\0' for v in info)
    chunks = [(k, b) for k, b in caf_chunks(caf) if k != b'info']
    chunks.insert(1, (b'info', info_chunk))
    path = work / 'apple.caf'
    path.write_bytes(caf_file(chunks))
    compare(path, note="Apple's info keys")

    # Robustness: mutated tags never crash or hang.
    sources = [work / n for n in ('id3v24.mp3', 'id3v23.mp3', 'v22.mp3', 'v23-unsync.mp3', 'id3-ape.mp3', 'v11.mp3',
                                  'comments.flac', 'vorbis.ogg', 'opus.opus', 'items.m4a', 'audio.mka', 'pcm.wav',
                                  'pcm.caf', 'wavpack.wv', 'id3.aiff', 'pcm.avi')]
    mutated, opened = 0, 0
    for n in range(1200):
        data = bytearray(sources[n % len(sources)].read_bytes())
        span = min(len(data), 1200)
        tail = n % 3 == 0
        for _ in range(rng.randrange(1, 12)):
            p = rng.randrange(span)
            data[len(data) - 1 - p if tail else p] = rng.randrange(256)
        path = work / 'mutated.bin'
        path.write_bytes(bytes(data))
        try:
            result = subprocess.run([str(lamp_cli()), '--tags', str(path)], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
        except subprocess.TimeoutExpired:
            raise Failure(f'mutation {n} of {sources[n % len(sources)].name} hung')
        if result.returncode not in (0, 2):
            (work / f'crash-{n}.bin').write_bytes(bytes(data))
            raise Failure(f'mutation {n} of {sources[n % len(sources)].name} exited {result.returncode}')
        mutated += 1
        opened += result.returncode == 0
    checks.append({'test': 'mutated tags', 'result': 'no crash or hang', 'files': mutated, 'opened': opened})
    print(f'{mutated} mutated files: no crash or hang ({opened} opened)', flush=True)

    write_report('tags', {'result': 'passed', 'vorbis_fixture_encoder': metadata_vorbis_encoder(), 'checks': checks,
                          'scope': 'Metadata tags (ID3v2.2-2.4, ID3v1, APEv2, Vorbis comments, MP4 ilst, Matroska, '
                                   'RIFF INFO, AIFF, CAF) against ffprobe; mutated tags.'})
    print(f'Passed {len(checks)} tag checks.')


if __name__ == '__main__':
    main_guard(main)
