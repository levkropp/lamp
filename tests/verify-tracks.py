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
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, exe, ffmpeg, lamp_cli, main_guard, out_dir, run, scratch,
                       write_report)

SOURCES = ['-f', 'lavfi', '-i', 'sine=f=440:d=2', '-f', 'lavfi', '-i', 'anoisesrc=r=44100:d=2:a=0.2:seed=3',
           '-f', 'lavfi', '-i', 'sine=f=880:d=2:sample_rate=48000']
VIDEO = ['-f', 'lavfi', '-i', 'testsrc=size=96x64:rate=10:duration=2']


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


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'chain-oracle': 'chain-oracle.c'}, library)
    chain = exe('chain-oracle')
    work = scratch('tracks')
    checks = []
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
        'three.ogg': (SOURCES, ['-map', '0', '-map', '1', '-map', '2', '-c:a:0', 'libvorbis', '-c:a:1', 'libopus',
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
        if len(set(tracks)) != count:
            raise Failure(f'{name}: tracks decode alike')
        code, stats, default = decode(path)
        if default != tracks[automatic - 1]:
            raise Failure(f'{name}: the automatic choice is not track {automatic}')
        checks.append({'test': name, 'result': 'exact', 'tracks': count, 'automatic': automatic,
                       'comparator': 'FFmpeg -map 0:a:N -c copy'})
        print(f'{name}: {count} tracks exact, automatic choice track {automatic}', flush=True)
        rejected(chain, path, count + 1)

    # Chained Ogg: the track is chosen in every link.
    links = []
    for k in range(2):
        link = work / f'link{k}.ogg'
        ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'libopus', '-c:a:1', 'libvorbis', '-ar', '48000',
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

    # Speex counts as a track: Opus second in its link plays automatically.
    speex = work / 'speex-opus.ogg'
    ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'libspeex', '-ar:a:0', '16000', '-c:a:1', 'libopus', speex)
    single = work / 'speex-opus-a2.ogg'
    ffmpeg('-i', speex, '-map', '0:a:1', '-c', 'copy', single)
    reference = decode(single)[2]
    if decode(speex)[2] != reference or decode(speex, 2)[2] != reference:
        raise Failure('speex-opus.ogg: the Opus track does not play as its own file')
    rejected(chain, speex, 1)
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
    eac3 = work / 'eac3.ts'
    ffmpeg(*SOURCES[:8], '-map', '0', '-map', '1', '-c:a:0', 'ac3', '-c:a:1', 'eac3', eac3)
    single = work / 'eac3-a2.ts'
    ffmpeg('-i', eac3, '-map', '0:a:1', '-c', 'copy', single)
    code, stats, pcm = decode(eac3, 2)
    if code or pcm != decode(single)[2]:
        raise Failure(f'E-AC-3 track 2: {stats}')
    checks.append({'test': 'eac3.ts track 2', 'result': 'exact', 'comparator': 'isolated E-AC-3 track'})
    singles = []
    for name, coding in (('one.wav', ['-c:a', 'pcm_s16le']), ('one.mp3', ['-c:a', 'libmp3lame']),
                         ('one.flv', ['-c:a', 'libmp3lame'])):
        path = work / name
        ffmpeg(*SOURCES[:4], *coding, path)
        code, stats, data = decode(path, 1)
        if code or data != decode(path)[2]:
            raise Failure(f'{name} --track 1: {stats}')
        rejected(chain, path, 2)
        singles.append(name)
    checks.append({'test': 'unsupported and missing tracks', 'result': 'rejected',
                   'files': ['wma.mkv track 2'] + [f'{n} track 2' for n in singles] +
                   [f'{n} track {files[n][2] + 1}' for n in files]})
    print('Missing and unsupported tracks reject; --track 1 plays single-track files', flush=True)
    write_report('tracks', {'result': 'passed', 'checks': checks,
                            'scope': 'lamp-cli --track N in Matroska, MP4, MPEG-TS/PS, AVI and Ogg (multiplexed '
                                     'and chained) against FFmpeg -map 0:a:N copies; queues; unsupported, '
                                     'missing and single tracks.'})
    print(f'Passed {len(checks)} track checks.')


if __name__ == '__main__':
    main_guard(main)
