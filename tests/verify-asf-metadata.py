#!/usr/bin/env python3
"""ASF tags and WM/Picture: independent layouts, FFmpeg, guarded reads.

--prepare-only creates fixtures with the installed FFmpeg. --wine-only
checks the same hash-pinned fixtures with the shipping COFF objects after
a matching native run. The original writer also supplies ASF audio packets.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg,
                       ffmpeg_version, lamp_cli, main_guard, out_dir, run,
                       scratch, write_report)

spec = importlib.util.spec_from_file_location('asf_writer', ROOT / 'tests/verify-asf.py')
writer = importlib.util.module_from_spec(spec); spec.loader.exec_module(writer)
guid, obj = writer.guid, writer.obj
CONTENT = guid('75b22633-668e-11cf-a6d9-00aa0062ce6c')
EXTENDED = guid('d2d0a440-e307-11d2-97f0-00a0c95ea850')
METADATA = guid('c5f8cbea-5baf-4877-8467-aa8c44fa4cca')
LIBRARY = guid('44231c94-9498-49d1-a141-1d134e457054')
KEYS = ('title', 'artist', 'album', 'album_artist', 'date', 'track', 'disc', 'genre', 'comment', 'composer')
ALIASES = {'author': 'artist', 'description': 'comment', 'wm/albumartist': 'album_artist',
           'wm/albumtitle': 'album', 'wm/composer': 'composer', 'wm/genre': 'genre',
           'wm/partofset': 'disc', 'wm/tracknumber': 'track', 'wm/year': 'date'}
MIMES = {1: 'image/jpeg', 2: 'image/png', 3: 'image/gif', 4: 'image/bmp', 5: 'image/tiff', 6: 'image/webp'}
FMT = struct.pack('<HHIIHHH', 1, 2, 8000, 32000, 4, 16, 0)
PCM = struct.pack('<128h', *[(i * 1193 % 16000) - 8000 for i in range(128)])


def utf16(text): return text.encode('utf-16-le') + b'\0\0'


def basic(title='', artist='', comment='', copyright='Ignored copyright', rating='Ignored rating'):
    values = list(map(utf16, (title, artist, copyright, comment, rating)))
    return obj(CONTENT, struct.pack('<5H', *map(len, values)) + b''.join(values))


def descriptor(name, value, kind=0, stream=0, language=0, metadata=False):
    name = utf16(name) if isinstance(name, str) else name
    if isinstance(value, str): value = utf16(value)
    if metadata:
        return struct.pack('<HHHHI', language, stream, len(name), kind, len(value)) + name + value
    if stream or language: raise ValueError('Extended Content is global')
    return struct.pack('<H', len(name)) + name + struct.pack('<HH', kind, len(value)) + value


def descriptors(entries, key=EXTENDED):
    return obj(key, struct.pack('<H', len(entries)) + b''.join(entries))


def extension(children):
    data = b''.join(children)
    return obj(writer.EXT, writer.NONE + struct.pack('<HI', 6, len(data)) + data)


def picture(data, kind=3, mime='image/png', description='Front 🎵'):
    return bytes([kind]) + struct.pack('<I', len(data)) + utf16(mime) + utf16(description) + data


def file(extra, two=False, before_streams=False):
    streams = [writer.stream(FMT, ident=3)]
    items = [writer.payload(PCM, stream=3)]
    if two:
        streams.append(writer.stream(FMT, ident=117)); items.append(writer.payload(PCM[::-1], stream=117))
    result = bytearray(writer.asf(streams, [writer.packet(items, physical=1024)], minimum=1024, extra=extra))
    if before_streams:
        end = struct.unpack_from('<Q', result, 16)[0]; pos, children = 30, []
        while pos < end:
            size = struct.unpack_from('<Q', result, pos + 16)[0]
            children.append(bytes(result[pos:pos + size])); pos += size
        front = [c for c in children if c[:16] not in (writer.FILE, writer.STREAM)]
        rest = [c for c in children if c[:16] in (writer.FILE, writer.STREAM)]
        result[30:end] = b''.join(front + rest)
    return bytes(result)


def digest(data): return hashlib.sha256(data).hexdigest()


def writer_hash():
    return digest(Path(__file__).read_bytes().split(b'def main():')[0] +
                  (ROOT / 'tests/verify-asf.py').read_bytes().split(b'def main():')[0])


def probe_tags(path):
    data = json.loads(run(['ffprobe', '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', path]))
    return {ALIASES.get(k.lower(), k.lower()): v for k, v in data.get('format', {}).get('tags', {}).items()
            if ALIASES.get(k.lower(), k.lower()) in KEYS and v}


def check_probe(case, observed, version):
    expected = case['tags']
    if observed == expected: return None
    # FFmpeg 5 sign-extends a maximum unsigned DWORD to a QWORD string.
    # Modern FFmpeg 9 preserves 4294967295. Keep the format's unsigned value
    # and record this narrow, versioned comparator difference explicitly.
    legacy = dict(expected)
    if case['name'].startswith('unsigned-') and 'version 5.' in version:
        legacy['disc'] = '18446744073709551615'
        if observed == legacy: return 'FFmpeg 5 sign-extends DWORD 0xffffffff; LAMP and FFmpeg 9 preserve unsigned 4294967295'
    raise Failure(case['name'] + ': ffprobe tags differ: ' + str(observed))


def prepare(work):
    files = []
    # Small real images, generated only by the test comparator.
    images = {}
    for name, codec, color in [('front.png', 'png', 'red'), ('back.png', 'png', 'blue'), ('other.jpg', 'mjpeg', 'green')]:
        path = work / name
        ffmpeg('-f', 'lavfi', '-i', f'color=c={color}:s=16x16', '-frames:v', '1', '-c:v', codec, path)
        images[name] = path.read_bytes()

    def add(name, data, tags, art=None, *, choice=0, stream=3, probe=False, guards=False, cli=True, note=''):
        path = work / name; path.write_bytes(data)
        files.append(dict(name=name, tags=tags, art=None if art is None else
                          dict(kind=art[0], sha256=digest(art[1]), hex=art[1].hex()),
                          choice=choice, stream=stream, ffprobe=probe, guards=guards, cli=cli, note=note))

    meta = dict(title='Tïtle 漢字 🎵', artist='Ärtist', album='Albüm', album_artist='Album Ärtist',
                date='2026-10-07', track='3/12', disc='1/2', genre='Rock', comment='Cömment', composer='Cömposer')
    for codec in ('pcm_s16le', 'libmp3lame', 'aac'):
        path = work / (codec + '.asf')
        options = [x for k, v in meta.items() for x in ('-metadata', k + '=' + v)]
        ffmpeg('-f', 'lavfi', '-i', 'sine=f=641:r=44100:d=0.15', '-ac', '2', '-c:a', codec, *options, '-f', 'asf', path)
        add(path.name, path.read_bytes(), probe_tags(path), probe=True,
            note='FFmpeg muxer: basic and extended metadata, all ten normalized keys')
    add('basic.asf', file([basic(meta['title'], meta['artist'], meta['comment'])]),
        {k: meta[k] for k in ('title', 'artist', 'comment')}, probe=True, guards=True)
    names = {'title': 'Title', 'artist': 'Author', 'album': 'WM/AlbumTitle', 'album_artist': 'WM/AlbumArtist',
             'date': 'WM/Year', 'track': 'WM/TrackNumber', 'disc': 'WM/PartOfSet', 'genre': 'WM/Genre',
             'comment': 'Description', 'composer': 'WM/Composer'}
    entries = [descriptor(names[k], v) for k, v in meta.items()]
    add('extended.asf', file([descriptors(entries)]), meta, probe=True, guards=True)
    for key, label in ((METADATA, 'metadata'), (LIBRARY, 'library')):
        entries = [descriptor(names[k], v, metadata=True) for k, v in meta.items()]
        add(label + '.asf', file([extension([descriptors(entries, key)])]), meta, probe=True, guards=True)
    nested = descriptors([descriptor('Title', 'Depth four', metadata=True)], LIBRARY)
    for _ in range(4): nested = extension([nested])
    add('nested-four.asf', file([nested]), dict(title='Depth four'), guards=True)
    add('global-language.asf', file([basic('Default language'), extension([descriptors([
        descriptor('Title', 'Other language', language=1, metadata=True)], LIBRARY)])]),
        dict(title='Default language'), guards=True)
    numeric = [('track', 'WM/TrackNumber', 5, struct.pack('<H', 65535)),
               ('disc', 'WM/PartOfSet', 3, struct.pack('<I', 4294967295)),
               ('date', 'WM/Year', 4, struct.pack('<Q', 18446744073709551615)),
               ('comment', 'Description', 2, struct.pack('<I', 1))]
    add('unsigned-extended.asf', file([descriptors([descriptor(n, b, t) for _, n, t, b in numeric])]),
        {k: str(int.from_bytes(b, 'little')) for k, _, _, b in numeric}, probe=True)
    numeric[-1] = ('comment', 'Description', 2, struct.pack('<H', 1))
    for key, label in ((METADATA, 'metadata'), (LIBRARY, 'library')):
        add('unsigned-' + label + '.asf', file([extension([descriptors(
            [descriptor(n, b, t, metadata=True) for _, n, t, b in numeric], key)])]),
            {k: str(int.from_bytes(b, 'little')) for k, _, _, b in numeric}, probe=True)

    add('selected-stream.asf', file([extension([descriptors([
        descriptor('Title', 'Other stream', stream=117, metadata=True),
        descriptor('Title', 'Chosen 🎵', stream=3, metadata=True),
        descriptor('Title', 'Wrong language', stream=3, language=1, metadata=True),
        descriptor('WM/Genre', 'Local genre', stream=3, metadata=True),
    ], LIBRARY)]), basic('Global title', 'Global artist')], two=True, before_streams=True),
        dict(title='Chosen 🎵', artist='Global artist', genre='Local genre'), guards=True,
        note='Metadata precedes stream discovery; selected stream overrides global regardless of header order')
    files.append(dict(files[-1], name='selected-stream-2.asf', choice=2, stream=117,
                      tags=dict(title='Other stream', artist='Global artist')))
    (work / files[-1]['name']).write_bytes((work / 'selected-stream.asf').read_bytes())
    add('aliases-and-empty.asf', file([descriptors([
        descriptor('title', 'Earlier'), descriptor('TITLE', 'Later'), descriptor('Title', ''),
        descriptor('WM/AlbumTitle', 'Album'), descriptor('ALBUM', 'Canonical'),
        descriptor('WM/Comments', 'Notes'), descriptor('Title', bytes(16), 6),
        descriptor('artist', b'junk', 1), descriptor('Unknown', 'Ignored')])]),
        dict(title='Later', album='Canonical', comment='Notes'))
    add('duplicates.asf', file([descriptors([descriptor('Title', 'X' * 4096)] * 60 +
                                          [descriptor('Title', 'Last global')]),
                               extension([descriptors([descriptor('Title', 'Local survives', stream=3,
                                                                   metadata=True)], LIBRARY)])]),
        dict(title='Local survives'), note='More duplicate text than the shared 128 KiB arena')
    add('record-budget.asf', file([basic('Preserved'), descriptors([descriptor(b'', b'')] * 65535),
                                  descriptors([descriptor('Title', 'Over budget')] * 2),
                                  descriptors([descriptor('Author', 'Within remaining budget')])]),
        dict(title='Preserved', artist='Within remaining budget'),
        note='65536 descriptor budget per pass; a group exceeding the remainder is skipped')
    add('value-boundary.asf', file([descriptors([descriptor('Title', 'a' * 4095 + '🎵 tail')])]),
        dict(title='a' * 4095), note='UTF-8 cut never splits a supplementary character')
    add('Ünïcode 漢字 🎵.asf', file([basic('Path 🎵', 'Ärtist')]),
        dict(title='Path 🎵', artist='Ärtist'), guards=True)
    add('nul-surrogate.asf', file([descriptors([
        descriptor('Title', utf16('Visible') + utf16('Hidden')),
        descriptor('Author', 'Good'.encode('utf-16-le') + b'\x00\xd8'),
        descriptor(utf16('album') + b'\x00\xd8', 'Ignored'),
        descriptor(utf16('genre') + utf16('suffix'), 'Ignored')])]),
        dict(title='Visible', artist='Good'), note='Values stop at NUL/unpaired surrogate; names must be complete ASCII')

    front, back, jpg = images['front.png'], images['back.png'], images['other.jpg']
    add('cover-extended.asf', file([descriptors([
        descriptor('WM/Picture', picture(back, 4), 1), descriptor('WM/Picture', picture(front), 1),
        descriptor('WM/Picture', picture(jpg, mime='image/jpeg'), 1)])]), {}, (2, front), probe=True, guards=True)
    add('cover-library.asf', file([extension([descriptors([
        descriptor('WM/Picture', picture(front), 1, metadata=True)], LIBRARY)])]), {}, (2, front), probe=True)
    add('cover-local.asf', file([descriptors([descriptor('WM/Picture', picture(front), 1)]),
                               extension([descriptors([
        descriptor('WM/Picture', picture(jpg, 4, 'image/jpeg'), 1, stream=117, metadata=True),
        descriptor('WM/Picture', picture(back, 4), 1, stream=3, metadata=True),
        descriptor('WM/Picture', picture(jpg, mime='image/jpeg'), 1, stream=3, language=1, metadata=True),
        ], LIBRARY)])], two=True), {}, (2, back), guards=True,
        note='A valid local back cover overrides global front cover; other stream/language cannot replace it')
    files.append(dict(files[-1], name='cover-local-2.asf', choice=2, stream=117,
                      art=dict(kind=1, sha256=digest(jpg), hex=jpg.hex())))
    (work / files[-1]['name']).write_bytes((work / 'cover-local.asf').read_bytes())
    add('cover-case.asf', file([descriptors([descriptor('WM/Picture', picture(front, mime='IMAGE/PNG'), 1)])]), {},
        note='ASF MIME comparison is case sensitive')
    add('cover-local-invalid.asf', file([descriptors([descriptor('WM/Picture', picture(front), 1)]),
                                       extension([descriptors([
        descriptor('WM/Picture', b'\x03\xff\xff\xff\xff', 1, stream=3, metadata=True)], LIBRARY)])]),
        {}, (2, front), guards=True, note='An invalid local picture cannot clear a valid global cover')
    add('cover-declared-jpeg.asf', file([descriptors([descriptor('WM/Picture', picture(front, mime='image/jpeg'), 1)])]),
        {}, (1, front), note='ASF keeps declared image codec; bytes are not rewritten')
    add('cover-large.asf', file([extension([descriptors([
        descriptor('WM/Picture', picture(front + bytes(70000)), 1, metadata=True)], LIBRARY)])]),
        {}, (2, front + bytes(70000)), note='DWORD library data length exceeds Extended Content WORD capacity')

    # Optional malformed metadata is ignored without damaging valid audio.
    malformed = {
        'basic-short': obj(CONTENT, bytes(9)),
        'basic-overflow': obj(CONTENT, struct.pack('<5H', 65534, 0, 0, 0, 0)),
        'basic-odd': obj(CONTENT, struct.pack('<5H', 3, 0, 0, 0, 0) + b'A\0X'),
        'extended-count': obj(EXTENDED, b'\xff\xff'),
        'extended-name': obj(EXTENDED, b'\x01\0\xfe\xff'),
        'extended-value': obj(EXTENDED, b'\x01\0' + utf16('Title').__len__().to_bytes(2, 'little') +
                              utf16('Title') + b'\0\0\xfe\xff'),
        'metadata-value': obj(METADATA, b'\x01\0' + struct.pack('<HHHHI', 0, 0, 12, 0, 0xffffffff) + utf16('Title')),
        'library-name': obj(LIBRARY, b'\x01\0' + struct.pack('<HHHHI', 0, 0, 65534, 0, 0)),
        'partial-descriptors': obj(EXTENDED, b'\x02\0' + descriptor('Title', 'Must not leak') + b'\xff'),
        'word-width': descriptors([descriptor('Title', b'\x01', 5)]),
        'dword-width': descriptors([descriptor('Title', bytes(8), 3)]),
        'qword-width': descriptors([descriptor('Title', bytes(4), 4)]),
        'bool-width': descriptors([descriptor('Title', bytes(2), 2)]),
        'text-odd': descriptors([descriptor('Title', b'A\0B')]),
        'name-odd': descriptors([descriptor(b'T\0i', 'Ignored')]),
        'picture-size': descriptors([descriptor('WM/Picture', b'\x03\xff\xff\xff\xff' + utf16('image/png') + b'\0\0', 1)]),
        'picture-mime': descriptors([descriptor('WM/Picture', b'\x03\x01\0\0\0' + b'A\0' * 63, 1)]),
        'picture-mime-surrogate': descriptors([descriptor('WM/Picture', b'\x03' + struct.pack('<I', len(front)) +
                                                        'image/png'.encode('utf-16-le') + b'\x00\xd8\0\0\0\0' + front, 1)]),
        'picture-description': descriptors([descriptor('WM/Picture', b'\x03\x01\0\0\0' + utf16('image/png') + b'A\0' * 8, 1)]),
        'picture-empty': descriptors([descriptor('WM/Picture', picture(b''), 1)]),
        'picture-long-description': descriptors([descriptor('WM/Picture', picture(front, description='X' * 4096), 1)]),
    }
    for label, extra in malformed.items():
        add('bad-' + label + '.asf', file([basic('Preserved'), extra, descriptors([descriptor('Author', 'After')])]),
            dict(title='Preserved', artist='After'), guards=len(extra) < 200, note='Malformed optional object/value skipped; later metadata/audio survive')
    add('after-data.asf', file([]) + basic('Hidden in trailing data'), {}, guards=True,
        note='Metadata is read only from the Header Object')
    add('bare-header.asf', writer.HEADER + struct.pack('<QI', 30, 0) + b'\x01\x02', {}, guards=True, cli=False)
    for label in ('basic-short', 'extended-name', 'metadata-value', 'library-name', 'picture-size'):
        child = malformed[label]
        header = writer.HEADER + struct.pack('<QI', 30 + len(child), 1) + b'\x01\x02' + child
        add('protected-' + label + '.asf', header, {}, guards=True, cli=False,
            note='Short optional object ends exactly at PAGE_NOACCESS without audio/data padding')
    for case in files:
        if case['ffprobe']:
            observed = probe_tags(work / case['name'])
            case['fixture_probe_note'] = check_probe(case, observed, ffmpeg_version())
            case['fixture_probe_tags'] = observed
    hashes = {p.name: digest(p.read_bytes()) for p in work.iterdir()
              if p.is_file() and p.suffix in ('.asf', '.png', '.jpg')}
    manifest = dict(files=files, hashes=hashes, ffmpeg=ffmpeg_version(), writer_sha256=writer_hash())
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Prepared {len(files)} metadata/art cases.', flush=True)


def main():
    work = scratch('asf-metadata')
    if '--prepare-only' in sys.argv: prepare(work); return
    if not (work / 'manifest.json').exists(): prepare(work)
    manifest = json.loads((work / 'manifest.json').read_text())
    if manifest['writer_sha256'] != writer_hash(): raise Failure('Fixture writer changed; prepare again')
    for name, value in manifest['hashes'].items():
        if digest((work / name).read_bytes()) != value: raise Failure('Changed fixture: ' + name)
    wine = '--wine-only' in sys.argv
    env = dict(os.environ, WINEDEBUG='err+all') if wine else None
    if wine:
        prior = json.loads((out_dir() / 'asf-metadata-verification.json').read_text())
        if prior['result'] != 'passed' or prior['fixture_hashes'] != manifest['hashes']:
            raise Failure('A matching native run must pass first')
        run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
        objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj')) if p.stem not in
                   {'player', 'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}]
        libs = sorted((ROOT / 'bin/obj').glob('*.lib'))
        run(['x86_64-w64-mingw32-gcc', '-O2', '-std=gnu11', '-municode', '-I', ROOT / 'tests',
             ROOT / 'tests/asf-metadata-oracle.c', *objects, *libs, '-lm', '-o', ROOT / 'bin/asf-metadata-oracle.exe'])
        cli = ['wine', ROOT / 'bin/lamp-cli.exe']; oracle = ['wine', ROOT / 'bin/asf-metadata-oracle.exe']
    else:
        library = build_lamp()
        build_oracles(out_dir(), {'asf-metadata-oracle': 'asf-metadata-oracle.c'}, library)
        cli, oracle = [lamp_cli()], [exe('asf-metadata-oracle')]

    checks = []
    for case in manifest['files']:
        path = work / case['name']
        options = ['--track', case['choice']] if case['choice'] else []
        # Direct guarded reader verifies raw UTF-8 and exact artwork bytes,
        # independently of the CLI's escaping of control characters.
        output = run([*oracle, 'dump', path, case['stream']], env=env, timeout=120)
        tags, art = {}, None
        for line in output.splitlines():
            kind, index, value = line.split(' ', 2)
            if kind == 'tag': tags[KEYS[int(index)]] = bytes.fromhex(value).decode('utf-8')
            elif kind == 'cover': art = dict(kind=int(index), sha256=digest(bytes.fromhex(value)), hex=value)
            else: raise Failure('Unexpected oracle output: ' + line[:200])
        if tags != case['tags'] or art != case['art']:
            raise Failure(path.name + ': guarded metadata differs: ' + str(tags)[:500] + ', art=' + str(art)[:100])
        if case['cli']:
            shown = run([*cli, *options, '--tags', path], env=env, timeout=120)
            shown = '\n'.join(shown.splitlines())
            expected = '\n'.join(k + '=' + case['tags'][k] for k in KEYS if k in case['tags'])
            if shown != expected: raise Failure(path.name + ': CLI/selected stream differs: ' + shown[:500])
            target = work / 'cover-output.bin'; target.unlink(missing_ok=True)
            result = subprocess.run([str(x) for x in [*cli, *options, '--cover', path, target]],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            if case['art'] is None:
                if result.returncode != 2 or target.exists() or result.stdout.strip() != b'No embedded cover art.':
                    raise Failure(path.name + ': expected no picture: ' + repr(result.stdout[-300:]))
            elif result.returncode or digest(target.read_bytes()) != case['art']['sha256'] or \
                    result.stdout.strip().decode() != f"{MIMES[case['art']['kind']]} {len(target.read_bytes())} bytes":
                raise Failure(path.name + ': exported picture differs')
            if case['name'] not in ('pcm_s16le.asf', 'libmp3lame.asf', 'aac.asf'):
                # Every independent metadata envelope carries the same PCM.
                # Even rejected optional descriptors leave all audio intact.
                output_pcm = work / 'metadata-audio.f32'; output_pcm.unlink(missing_ok=True)
                run([*cli, *options, '--decode', path, output_pcm], env=env, timeout=120)
                raw = PCM[::-1] if case['choice'] == 2 else PCM
                expected_pcm = struct.pack('<128f', *[v / 32768 for v in struct.unpack('<128h', raw)])
                if output_pcm.read_bytes() != expected_pcm: raise Failure(path.name + ': metadata changed PCM')
        reference, reference_note = None, None
        if case['ffprobe'] and not wine:
            reference = probe_tags(path)
            reference_note = check_probe(case, reference, ffmpeg_version())
            if case['art']:
                target = work / 'ffmpeg-picture.bin'
                streams = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', path]))['streams']
                pictures = [s for s in streams if s.get('disposition', {}).get('attached_pic')]
                chosen = next((s for s in pictures if s.get('tags', {}).get('comment') == 'Cover (front)'), pictures[0])
                ffmpeg('-i', path, '-map', f"0:{chosen['index']}", '-c', 'copy', '-frames:v', '1', '-f', 'rawvideo', target)
                if digest(target.read_bytes()) != case['art']['sha256']: raise Failure(path.name + ': ffmpeg picture differs')
        guards = json.loads(run([*oracle, 'guard', path, case['stream']], env=env, timeout=120).splitlines()[-1]) if case['guards'] else None
        checks.append(dict(test=path.name, result='exact', keys=sorted(tags), picture_sha256=None if art is None else art['sha256'],
                           note=case['note'], fixture_ffprobe=case.get('fixture_probe_tags'),
                           runtime_ffprobe=reference, runtime_ffprobe_note=reference_note, protected_input=guards,
                           exact_pcm=case['cli'] and case['name'] not in ('pcm_s16le.asf', 'libmp3lame.asf', 'aac.asf')))
        print(path.name + ': tags and art passed', flush=True)
    # Reversible malformed metadata must not crash/hang, including valid
    # object envelopes whose nested lengths/counts are adversarial.
    rng = random.Random(1027); seeds = [work / n for n in ('extended.asf', 'selected-stream.asf', 'cover-library.asf')]
    mutation = work / 'mutated.bin'; mutations = 120 if wine else 1200
    for i in range(mutations):
        data = bytearray(seeds[i % len(seeds)].read_bytes())
        end = struct.unpack_from('<Q', data, 16)[0]
        pos = rng.randrange(30, end)
        if i % 5 == 0: data = data[:pos]
        elif i % 5 == 1: data[pos:min(pos + rng.randrange(1, 32), end)] = b'\xff' * min(rng.randrange(1, 32), end - pos)
        elif i % 5 == 2: data[pos] ^= 1 << rng.randrange(8)
        elif i % 5 == 3: data[pos:min(pos + 8, end)] = bytes(min(8, end - pos))
        else: data[pos:pos + 4] = struct.pack('<I', rng.randrange(1 << 32))
        mutation.write_bytes(data)
        run([*oracle, 'dump', mutation, 3 if i % 2 else 117], env=env, timeout=20)
    checks.append(dict(test='mutated metadata at a protected mapped end', result='passed', inputs=mutations, seed=1027))
    sources = ['src/tags.s', 'src/tags_asf.inc', 'src/cover.inc', 'src/asf.s', 'src/decoder.s',
               'tests/verify-asf-metadata.py', 'tests/asf-metadata-oracle.c', 'tests/verify-asf.py']
    write_report('asf-metadata-wine' if wine else 'asf-metadata', dict(result='passed', checks=checks,
                 fixture_hashes=manifest['hashes'], fixture_ffmpeg=manifest['ffmpeg'],
                 fixture_writer_sha256=manifest['writer_sha256'], runtime_platform=platform.platform(),
                 runtime_ffmpeg=None if wine else ffmpeg_version(),
                 runtime_sources={n: digest((ROOT / n).read_bytes()) for n in sources},
                 cli_sha256=digest(Path(cli[-1]).read_bytes()), oracle_sha256=digest(Path(oracle[-1]).read_bytes())))
    print(f'Passed {len(checks)} checks.', flush=True)


if __name__ == '__main__': main_guard(main)
