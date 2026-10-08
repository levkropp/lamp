#!/usr/bin/env python3
"""Audio track selection (lamp-cli --track N) against FFmpeg's stream maps.

usage: python3 tests/verify-tracks.py
- FFmpeg writes files with two or three audio tracks of different codecs
  (and video in some): Matroska (with the second track marked default),
  MP4, MPEG transport and program streams, AVI and multiplexed Ogg. For each
  track N, LAMP's decode with --track N equals its decode of FFmpeg's copy of
  that track alone (-map 0:a:N-1 -c copy) into the same container, and
  FFmpeg's decodes of the two agree too. Without --track the automatic
  choice is unchanged (Matroska's default track, else the first supported).
- A chained Ogg file chooses the track in every link. In an Ogg file of
  Speex and Opus, Speex counts as track 1 (and rejects when chosen) and the
  Opus stream, whose header is not on the file's first page, plays.
- --track applies to every file of a queue.
- A track that does not exist, or one LAMP does not decode (WMA in
  Matroska), rejects with decode_error 101
  (tests/chain-oracle.c), and so does --track 2 on a file of one track
  (WAV, MP3, FLV); --track 1 plays them.
Writes <out>/tracks-verification.json.
"""
import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg, lamp_cli, main_guard, out_dir, run, scratch,
                       write_report, fixture_vorbis_encoder)

SOURCES = ['-f', 'lavfi', '-i', 'sine=f=440:d=2', '-f', 'lavfi', '-i', 'anoisesrc=r=44100:d=2:a=0.2:seed=3',
           '-f', 'lavfi', '-i', 'sine=f=880:d=2:sample_rate=48000']
VIDEO = ['-f', 'lavfi', '-i', 'testsrc=size=96x64:rate=10:duration=2']


def vorbis_track(index):
    """Apply the recorded fixture encoder choice to one multiplexed stream."""
    flags = {'-c:a': f'-c:a:{index}', '-strict': f'-strict:a:{index}', '-ac': f'-ac:a:{index}'}
    return [flags.get(value, value) for value in fixture_vorbis_encoder()]


def catalog_wine():
    work = scratch('tracks')
    cases = json.loads((work / 'catalog-cases.json').read_text())
    prior = json.loads((out_dir() / 'tracks-verification.json').read_text())
    if prior['result'] != 'passed': raise Failure('Native track verification must pass first')
    spec = importlib.util.spec_from_file_location('catalog_windows_build', ROOT / 'tools/build-windows.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    run([sys.executable, ROOT / 'tools/build-windows.py'], capture=False)
    skip = {'player', 'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}
    objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj')) if p.stem not in skip]
    libs = list(sorted((ROOT / 'bin/obj').glob('*.lib')))
    target = ROOT / 'bin/track-catalog-oracle.exe'
    run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
         '-I', ROOT / 'tests', ROOT / 'tests/track-catalog-oracle.c', *objects, *libs, '-lm', '-o', target])
    checks = []
    for case in cases:
        path = work / case['file']
        if hashlib.sha256(path.read_bytes()).hexdigest() != case['sha256']: raise Failure('Track fixture changed')
        result = json.loads(run(['wine', target, path, case['choice'], case['count'], case['selected']],
                                timeout=120).strip().splitlines()[-1])
        checks.append(dict(test=case['file'], **result))
    for case in json.loads((work / 'wide-pcm-cases.json').read_text()):
        path, reference = work / case['file'], work / case['reference']
        if hashlib.sha256(path.read_bytes()).hexdigest() != case['sha256']:
            raise Failure('Wide program stream fixture changed')
        expected = reference.read_bytes()
        if hashlib.sha256(expected).hexdigest() != case['pcm_sha256']:
            raise Failure('Wide program stream PCM reference changed')
        output = work / (case['file'] + '.wine.f32')
        output.unlink(missing_ok=True)
        run(['wine', ROOT / 'bin/lamp-cli.exe', '--decode', '--track', case['choice'], path, output], timeout=120)
        if output.read_bytes() != expected:
            raise Failure(f"Windows program stream ordinal {case['choice']}: PCM differs from raw stream")
        checks.append(dict(test=f"{case['file']} track {case['choice']} PCM", result='exact',
                           frames=len(expected)//8, pcm_sha256=case['pcm_sha256']))
    probe = out_dir() / 'ui-tracks-probe.obj'
    run([builder.tool('llvm-mc'), '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
         '-defsym=WINDOWS=1', '-I', ROOT / 'src', '-I', ROOT / 'src/win',
         ROOT / 'tests/ui-queue-snapshot-probe.s', '-o', probe])
    ui_objects = [p for p in sorted((ROOT / 'bin/obj').glob('*.obj'))
                  if p.stem not in {'ui', 'engine-probe', 'ui-preview', 'ui-list', 'ui-driver'}]
    ui_target = ROOT / 'bin/ui-tracks-oracle.exe'
    run([os.environ.get('MINGW_CC', 'x86_64-w64-mingw32-gcc'), '-O2', '-std=c11', '-municode',
         '-I', ROOT / 'tests', ROOT / 'tests/ui-tracks-oracle.c', probe, *ui_objects, *libs,
         '-lm', '-luser32', '-o', ui_target])
    ui_result = json.loads(run(['wine', ui_target, work / 'three.mp4', work / 'wma.mkv', work / 'one.wav',
                               work / 'three.mp4.track2.f32', work / 'one.wav.f32'], timeout=120).strip().splitlines()[-1])
    checks.append(dict(test='Windows track menu, deferred switch and per-file queue', **ui_result))
    sources = catalog_sources()
    sources.update({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
                    ['src/queue.s', 'src/win/ui.s', 'src/win/ui_queue.inc', 'src/win/ui_tracks.inc',
                     'src/win/ui_menu.inc', 'src/win/ui_draw.inc', 'tests/ui-tracks-oracle.c',
                     'tests/ui-queue-snapshot-probe.s']})
    write_report('track-catalog-wine', dict(result='passed', checks=checks,
        sources=sources, scope='Shipping Windows COFF decoder audio counts/ordinals, reopen and failure clearing, real Win32 menu labels/checks/cap, deferred paused track switching, shorter-track clamp, unsupported-track rollback, menu file pairing and exact per-file queue PCM under Wine; same hashed fixtures as the native PCM track suite.'))
    print(f'Passed {len(checks)} Windows track catalog checks.', flush=True)


def catalog_sources():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
            ['src/decoder.s', 'src/mp4.s', 'src/mkv.s', 'src/avi.s', 'src/mpegts.s', 'src/ogg_chain.s',
             'tests/track-catalog-oracle.c', 'tests/verify-tracks.py']}


def decode(path, track=None, output=None):
    """lamp-cli --decode [--track N] -> (exit code, stats, PCM bytes)."""
    output = Path(output or str(path) + (f'.track{track}' if track else '') + '.f32')
    if output.exists():
        output.unlink()
    args = [str(lamp_cli()), '--decode'] + (['--track', str(track)] if track else []) + [str(path), str(output)]
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    data = output.read_bytes() if output.exists() else b''
    return result.returncode, result.stdout.decode('utf-8', 'replace').strip(), data


def ffmpeg_pcm(path, stream=None):
    args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(path)]
    if stream is not None:
        args += ['-map', f'0:a:{stream}']
    result = subprocess.run(args + ['-ac', '2', '-f', 'f32le', '-'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Failure(f'FFmpeg on {Path(path).name}: {result.stderr.decode()[:200]}')
    return result.stdout


def rejected(chain, path, track):
    """Opening with track chosen fails with decode_error 101 (chain-oracle),
    and lamp-cli skips the file."""
    line = run([chain, 'reject', path, str(track)]).strip().splitlines()[-1]
    if json.loads(line).get('decode_error') != 101:
        raise Failure(f'{Path(path).name} --track {track}: expected decode_error 101, got {line}')
    code, stats, _ = decode(path, track)
    if code == 0:
        raise Failure(f'{Path(path).name} --track {track}: lamp-cli decoded it ({stats})')
    return line


def wide_program_stream(pack_source, mp2, ac3=None):
    """Synthetic unsupported IDs followed by independently encoded audio.

    Exercise the parser's complete recognized ID domain, rather than claiming
    that the placeholder private streams contain decodable DTS/MLP/TrueHD.
    """
    source = pack_source.read_bytes()
    if source[:4] != b'\x00\x00\x01\xba' or source[4] & 0xc0 != 0x40:
        raise Failure('Expected an MPEG-2 pack header')
    chunks = [source[:14 + (source[13] & 7)]]
    def pes(stream, payload):
        body = b'\x80\x00\x00' + payload
        chunks.append(b'\x00\x00\x01' + bytes([stream]) + len(body).to_bytes(2, 'big') + body)
    for substream in [*range(0x88, 0x90), *range(0x98, 0xd0)]:
        pes(0xbd, bytes([substream]) + bytes(8))
    if ac3 is not None:
        for substream in range(0x80, 0x88):
            for start in range(0, len(ac3), 60000):
                pes(0xbd, bytes([substream, 0, 0, 0]) + ac3[start:start + 60000])
    for stream in range(0xc0, 0xe0 if ac3 is not None else 0xc1):
        for start in range(0, len(mp2), 60000):
            pes(stream, mp2[start:start + 60000])
    return b''.join(chunks) + b'\x00\x00\x01\xb9'


def main():
    if '--wine-only' in sys.argv: catalog_wine(); return
    library = build_lamp()
    build_oracles(out_dir(), {'chain-oracle': 'chain-oracle.c', 'track-catalog-oracle': 'track-catalog-oracle.c'}, library)
    chain = exe('chain-oracle')
    work = scratch('tracks')
    checks = []
    catalog_cases = []
    wide_pcm_cases = []
    def catalog(path, choice, count, selected):
        run([exe('track-catalog-oracle'), path, choice, count, selected])
        catalog_cases.append(dict(file=path.name, choice=choice, count=count, selected=selected,
                                  sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    files = {
        'three.mkv': (VIDEO + SOURCES, ['-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:a', '-c:v', 'mpeg4',
                                         '-c:a:0', 'libopus', '-c:a:1', 'flac', '-c:a:2', 'aac',
                                         '-disposition:a:0', '0', '-disposition:a:1', 'default'], 3, 2),
        'three.mp4': (SOURCES, ['-map', '0', '-map', '1', '-map', '2', '-c:a:0', 'aac', '-c:a:1', 'alac',
                                '-c:a:2', 'aac'], 3, 1),
        'three.ts': (VIDEO + SOURCES, ['-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:a', '-c:v', 'mpeg2video',
                                        '-c:a:0', 'mp2', '-c:a:1', 'ac3', '-c:a:2', 'aac'], 3, 1),
        'two.vob': (SOURCES, ['-map', '0', '-map', '1', '-c:a:0', 'mp2', '-c:a:1', 'ac3', '-f', 'vob'], 2, 1),
        'two.avi': (SOURCES, ['-map', '0', '-map', '1', '-c:a:0', 'pcm_s16le', '-c:a:1', 'libmp3lame'], 2, 1),
        'three.ogg': (SOURCES, ['-map', '0', '-map', '1', '-map', '2', *vorbis_track(0), '-c:a:1', 'libopus',
                                '-c:a:2', 'flac'], 3, 1),
    }
    for name, (inputs, maps, count, automatic) in files.items():
        path = work / name
        ffmpeg(*inputs, *maps, path)
        tracks = []
        for n in range(1, count + 1):
            single = work / f'{path.stem}-a{n}{path.suffix}'
            extra = ['-f', 'vob'] if path.suffix == '.vob' else []
            ffmpeg('-i', path, '-map', f'0:a:{n - 1}', '-c', 'copy', *extra, single)
            code, stats, ours = decode(path, n)
            if code:
                raise Failure(f'{name} --track {n}: {stats}')
            _, _, reference = decode(single)
            if ours != reference:
                raise Failure(f'{name} --track {n}: differs from {single.name}')
            if ffmpeg_pcm(path, n - 1) != ffmpeg_pcm(single):
                raise Failure(f'{name}: FFmpeg decodes track {n} differently from {single.name}')
            tracks.append(ours)
            catalog(path, n, count, n)
        if len(set(tracks)) != count:
            raise Failure(f'{name}: tracks decode alike')
        code, stats, default = decode(path)
        if default != tracks[automatic - 1]:
            raise Failure(f'{name}: the automatic choice is not track {automatic}')
        checks.append({'test': name, 'result': 'exact', 'tracks': count, 'automatic': automatic,
                       'comparator': 'FFmpeg -map 0:a:N -c copy'})
        print(f'{name}: {count} tracks exact, automatic choice track {automatic}', flush=True)
        catalog(path, 0, count, automatic)
        rejected(chain, path, count + 1)
        catalog(path, count + 1, 0, 0)

    # Chained Ogg: the track is chosen in every link.
    links = []
    for k in range(2):
        link = work / f'link{k}.ogg'
        ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'libopus', *vorbis_track(1), '-ar', '48000',
               '-metadata', f'title=link {k}', link)
        links.append(link.read_bytes())
    chained = work / 'chained.ogg'
    chained.write_bytes(b''.join(links))
    code, stats, ours = decode(chained, 2)
    parts = b''
    for k in range(2):
        single = work / f'link{k}-a2.ogg'
        ffmpeg('-i', work / f'link{k}.ogg', '-map', '0:a:1', '-c', 'copy', single)
        parts += decode(single)[2]
    if code or ours != parts:
        raise Failure(f'chained.ogg --track 2: {stats}')
    checks.append({'test': 'chained.ogg --track 2', 'result': 'exact', 'note': 'track 2 of each link'})
    catalog(chained, 0, 2, 1)
    catalog(chained, 2, 2, 2)

    # Speex counts as a track: Opus second in its link plays automatically.
    speex = work / 'speex-opus.ogg'
    retained = os.environ.get('LAMP_TRACK_FIXTURES')
    if retained:
        shutil.copyfile(Path(retained) / speex.name, speex)
    else:
        ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'libspeex', '-ar:a:0', '16000', '-c:a:1', 'libopus', speex)
    single = work / 'speex-opus-a2.ogg'
    ffmpeg('-i', speex, '-map', '0:a:1', '-c', 'copy', single)
    reference = decode(single)[2]
    if decode(speex)[2] != reference or decode(speex, 2)[2] != reference:
        raise Failure('speex-opus.ogg: the Opus track does not play as its own file')
    rejected(chain, speex, 1)
    catalog(speex, 0, 2, 2)
    catalog(speex, 2, 2, 2)
    catalog(speex, 1, 0, 0)
    checks.append({'test': 'speex-opus.ogg', 'result': 'exact', 'automatic': 2,
                   'note': 'Speex (track 1) is counted and rejects; Opus begins on the second BOS page'})

    # A queue: --track applies to every file.
    queue = work / 'queue.f32'
    if queue.exists():
        queue.unlink()
    result = subprocess.run([str(lamp_cli()), '--decode', '--track', '3', str(work / 'three.mkv'),
                             str(work / 'three.mp4'), str(queue)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    expected = decode(work / 'three-a3.mkv')[2] + decode(work / 'three-a3.mp4')[2]
    if result.returncode or queue.read_bytes() != expected:
        raise Failure(f'queue --track 3: {result.stdout.decode()[:300]}')
    checks.append({'test': 'queue --track 3', 'result': 'exact', 'files': 2})

    # Unsupported tracks and single-track files.
    wma = work / 'wma.mkv'
    ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'flac', '-c:a:1', 'wmav2', wma)
    rejected(chain, wma, 2)
    catalog(wma, 0, 2, 1)
    catalog(wma, 2, 0, 0)
    eac3 = work / 'eac3.ts'
    ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'ac3', '-c:a:1', 'eac3', eac3)
    single = work / 'eac3-a2.ts'
    ffmpeg('-i', eac3, '-map', '0:a:1', '-c', 'copy', single)
    code, stats, pcm = decode(eac3, 2)
    if code or pcm != decode(single)[2]:
        raise Failure(f'E-AC-3 track 2: {stats}')
    checks.append({'test': 'eac3.ts track 2', 'result': 'exact', 'comparator': 'isolated E-AC-3 track'})
    catalog(eac3, 0, 2, 1)
    catalog(eac3, 2, 2, 2)
    singles = []
    for name, coding in (('one.wav', ['-c:a', 'pcm_s16le']), ('one.mp3', ['-c:a', 'libmp3lame']),
                         ('one.flv', ['-c:a', 'libmp3lame'])):
        path = work / name
        ffmpeg(*SOURCES[:4], *coding, path)
        code, stats, data = decode(path, 1)
        if code or data != decode(path)[2]:
            raise Failure(f'{name} --track 1: {stats}')
        rejected(chain, path, 2)
        catalog(path, 0, 1, 1)
        catalog(path, 1, 1, 1)
        catalog(path, 2, 0, 0)
        singles.append(name)
    checks.append({'test': 'unsupported and missing tracks', 'result': 'rejected',
                   'files': ['wma.mkv track 2'] + [f'{n} track 2' for n in singles] +
                   [f'{n} track {files[n][2] + 1}' for n in files]})
    print('Missing and unsupported tracks reject; --track 1 plays single-track files', flush=True)
    # A disabled MP4 sound track still occupies its physical audio ordinal.
    disabled = work / 'disabled-first.mp4'
    data = bytearray((work / 'three.mp4').read_bytes())
    def boxes(start, end):
        while start + 8 <= end:
            size = int.from_bytes(data[start:start + 4], 'big')
            if size < 8 or start + size > end: raise Failure('Unexpected generated MP4 box')
            yield data[start + 4:start + 8], start + 8, start + size
            start += size
    moov = next((a,b) for name,a,b in boxes(0,len(data)) if name == b'moov')
    traks = [(a,b) for name,a,b in boxes(*moov) if name == b'trak']
    trak = traks[0]
    tkhd = next(a for name,a,b in boxes(*trak) if name == b'tkhd')
    data[tkhd + 3] &= ~1
    next_tkhd = next(a for name,a,b in boxes(*traks[1]) if name == b'tkhd')
    data[next_tkhd + 3] |= 1
    disabled.write_bytes(data)
    catalog(disabled, 0, 3, 2)
    catalog(disabled, 1, 3, 1)
    if decode(disabled)[2] != decode(work / 'three.mp4', 2)[2]: raise Failure('Disabled MP4 default changed')
    # Menu ordinals must exist in all Ogg links, while the automatic ordinal
    # still names the first link's actually selected stream.
    unequal = work / 'unequal.ogg'
    unequal.write_bytes(speex.read_bytes() + (work / 'speex-opus-a2.ogg').read_bytes())
    catalog(unequal, 0, 1, 2)
    catalog(unequal, 2, 0, 0)
    # Ordinal 65 used to reject because mps_audio_seen retained only 64 IDs.
    # All 104 currently recognized IDs must fit, including unsupported ones.
    mp2, ac3 = work / 'catalog-65.mp2', work / 'catalog-104.ac3'
    ffmpeg('-i', work / 'two-a1.vob', '-map', '0:a:0', '-c', 'copy', '-f', 'mp2', mp2)
    ffmpeg('-i', work / 'two-a2.vob', '-map', '0:a:0', '-c', 'copy', '-f', 'ac3', ac3)
    mp2_pcm, ac3_pcm = decode(mp2)[2], decode(ac3)[2]
    if not mp2_pcm or not ac3_pcm: raise Failure('Wide program stream references are empty')
    for name, data, count, automatic, selected, reference, raw in (
            ('catalog-65.mpg', wide_program_stream(work / 'two.vob', mp2.read_bytes()),
             65, 65, 65, mp2_pcm, mp2),
            ('catalog-104.mpg', wide_program_stream(work / 'two.vob', mp2.read_bytes(), ac3.read_bytes()),
             104, 65, 104, mp2_pcm, mp2)):
        path = work / name
        path.write_bytes(data)
        default_pcm = ac3_pcm if count == 104 else mp2_pcm
        if decode(path)[2] != default_pcm or decode(path, selected)[2] != reference:
            raise Failure(f'{name}: Automatic or track {selected} differs from its raw stream')
        catalog(path, 0, count, automatic)
        catalog(path, selected, count, selected)
        catalog(path, 64, 0, 0)
        catalog(path, count + 1, 0, 0)
        rejected(chain, path, 64)
        rejected(chain, path, count + 1)
        if count == 104:
            for choice, expected in ((65, ac3_pcm), (73, mp2_pcm)):
                catalog(path, choice, count, choice)
                if decode(path, choice)[2] != expected:
                    raise Failure(f'{name}: track {choice} differs from its raw stream')
        reference_path = work / (name + '.raw.f32')
        reference_path.write_bytes(reference)
        wide_pcm_cases.append(dict(file=name, choice=selected, reference=reference_path.name,
                                   sha256=hashlib.sha256(data).hexdigest(),
                                   pcm_sha256=hashlib.sha256(reference).hexdigest()))
        checks.append(dict(test=name, result='exact', tracks=count, automatic=automatic,
                           selected=selected, comparator=raw.name,
                           note='64 synthetic unsupported private IDs; remaining audio payloads are independently encoded'))
        print(f'{name}: {count} IDs counted, automatic {automatic} and track {selected} exact', flush=True)
    (work / 'wide-pcm-cases.json').write_text(json.dumps(wide_pcm_cases, indent=2) + '\n')
    (work / 'catalog-cases.json').write_text(json.dumps(catalog_cases, indent=2) + '\n')
    write_report('tracks', {'result': 'passed', 'vorbis_fixture_encoder': fixture_vorbis_encoder(), 'checks': checks,
                            'speex_fixture_source': retained or 'generated with local FFmpeg',
                            'speex_fixture_sha256': hashlib.sha256(speex.read_bytes()).hexdigest(),
                            'catalog_checks': catalog_cases, 'sources': catalog_sources(),
                            'scope': 'lamp-cli --track N in Matroska, MP4, MPEG-TS/PS, AVI and Ogg (multiplexed '
                                     'and chained) against FFmpeg -map 0:a:N copies; queues; unsupported, '
                                     'missing and single tracks.'})
    print(f'Passed {len(checks)} track checks.')


if __name__ == '__main__':
    main_guard(main)
