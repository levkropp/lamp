#!/usr/bin/env python3
"""GSM 06.10 full-rate speech in WAVE, AIFF-C and raw .gsm files.

usage: python3 tests/verify-gsm.py [--skip-playback]
- FFmpeg's libgsm encoders write Microsoft's 65-byte blocks into WAVE (tag
  0x31) and 33-byte frames into raw .gsm files; the test wraps the frames
  in AIFF-C ("GSM "). Speech-like, tonal, noise, silent and clipping signals
  decode exactly as FFmpeg decodes them, with its native decoder and with
  libgsm.
- 32 streams of random frames (random bytes, the 0xD nibble set in raw
  frames) reach every log-area ratio, lag (out-of-range lags keep the last
  one), gain, grid position, block maximum and pulse; each decodes exactly
  as libgsm (the reference implementation, through FFmpeg) decodes it.
  FFmpeg's own decoder departs from libgsm on such frames: it clips lags
  outside 40-120 rather than keeping the last, and saturates differently
  at the extremes; neither occurs in encoded streams.
- Seeks (tests/seek-oracle.c) equal continuous decoding: the state runs on
  across frames, and a seek decodes three packets of 20 frames from a reset
  state, which converge on the continuous state in every case tested.
- Truncated data plays its whole frames; stereo GSM rejects as unsupported
  (decode_error 101); a cancelled open stops cleanly; one file plays.
Writes <out>/gsm-verification.json.
"""
import array
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard, out_dir, play,
                       playback_requested, run, scratch, write_report)

SIGNALS = {
    'speech': 'aevalsrc=0.4*sin(2*PI*(150+60*sin(2*PI*3*t))*t)*(0.6+0.4*sin(2*PI*2*t))+0.05*random(0):s=8000:d=4',
    'tone': 'sine=f=440:r=8000:d=3',
    'noise': 'anoisesrc=r=8000:d=3:a=0.3:seed=7',
    'silence': 'anullsrc=r=8000:cl=mono:d=2',
    'clipping': 'aevalsrc=1.2*sin(2*PI*300*t):s=8000:d=2',
}


def ffmpeg_mono(path, decoder=None):
    """FFmpeg's float decode (native, or decoder), doubled into two channels."""
    args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y']
    if decoder:
        args += ['-c:a', decoder]
    result = subprocess.run(args + ['-i', str(path), '-f', 'f32le', '-'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    text = [line for line in result.stderr.decode('utf-8', 'replace').splitlines()
            if 'Missing GSM magic' not in line]
    if result.returncode or text:
        raise Failure(f'FFmpeg on {Path(path).name}: {text[:3]}')
    mono = array.array('f', result.stdout)
    stereo = array.array('f', [0.0]) * (2 * len(mono))
    stereo[0::2] = mono
    stereo[1::2] = mono
    return stereo.tobytes()


def aifc(frames, rate=8000, channels=1):
    """An AIFF-C file of 33-byte GSM frames ("GSM " compression)."""
    count = len(frames) // 33
    exponent, mantissa = 16383 + rate.bit_length() - 1, rate << (64 - rate.bit_length())
    comm = struct.pack('>hIh', channels, count, 16) + struct.pack('>HQ', exponent, mantissa) + b'GSM ' + \
        bytes([3]) + b'GSM' + b'\0'
    if len(comm) & 1:
        comm += b'\0'
    ssnd = struct.pack('>II', 0, 0) + frames
    body = b'AIFC' + b'FVER' + struct.pack('>II', 4, 0xA2805140) + b'COMM' + struct.pack('>I', len(comm) - 0) + comm \
        + b'SSND' + struct.pack('>I', len(ssnd)) + ssnd
    if len(ssnd) & 1:
        body += b'\0'
    return b'FORM' + struct.pack('>I', len(body)) + body


def wave(blocks, rate=8000, channels=1):
    """A WAVE file of 65-byte Microsoft GSM blocks (tag 0x31)."""
    fmt = struct.pack('<HHIIHHHH', 0x31, channels, rate, rate * 65 // 320, 65, 0, 2, 320)
    data = blocks
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
    if len(data) & 1:
        body += b'\0'
    return b'RIFF' + struct.pack('<I', len(body)) + body


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c'}, library)
    seek, chain = exe('seek-oracle'), exe('chain-oracle')
    work = scratch('gsm')
    checks = []

    def exact(path, note=None, native=True):
        """LAMP's decode equals libgsm's (through FFmpeg), and FFmpeg's own
        decoder's when native."""
        ours = Path(str(path) + '.f32')
        stats = decode_f32(path, ours)
        pcm = ours.read_bytes()
        libgsm = ffmpeg_mono(path, 'libgsm_ms' if path.suffix == '.wav' else 'libgsm')
        if pcm != libgsm:
            raise Failure(f'{path.name}: differs from libgsm ({stats})')
        entry = {'test': path.name, 'result': 'exact', 'comparator': 'libgsm', 'stats': stats}
        if native:
            if ffmpeg_mono(path) != libgsm:
                raise Failure(f'{path.name}: FFmpeg and libgsm disagree')
            entry['comparator'] = 'libgsm and FFmpeg'
        if note:
            entry['note'] = note
        checks.append(entry)
        return stats

    # FFmpeg's libgsm encodes.
    for name, source in SIGNALS.items():
        wav = work / f'{name}.wav'
        ffmpeg('-f', 'lavfi', '-i', source, '-ac', '1', '-c:a', 'libgsm_ms', wav)
        exact(wav)
        raw = work / f'{name}.gsm'
        ffmpeg('-f', 'lavfi', '-i', source, '-ac', '1', '-c:a', 'libgsm', '-f', 'gsm', raw)
        if 'codec=19 ' not in exact(raw):
            raise Failure(f'{raw.name}: not opened as raw GSM')
        aiff = work / f'{name}.aifc'
        aiff.write_bytes(aifc(raw.read_bytes()))
        exact(aiff)
    print(f'{3 * len(SIGNALS)} FFmpeg-encoded WAVE, raw and AIFF-C files: exact against FFmpeg and libgsm',
          flush=True)

    # Random frames.
    r = random.Random(6)
    for k in range(16):
        frames = bytearray(r.randbytes(33 * 300))
        for i in range(0, len(frames), 33):
            frames[i] = 0xd0 | frames[i] & 15
        path = work / f'random-{k}.gsm'
        path.write_bytes(bytes(frames))
        exact(path, native=False)
        path = work / f'random-{k}.wav'
        path.write_bytes(wave(r.randbytes(65 * 150)))
        exact(path, native=False)
    native = ffmpeg_mono(work / 'random-0.gsm')
    checks.append({'test': 'FFmpeg native decoder on random frames', 'result': 'differs from libgsm',
                   'note': 'it clips lags outside 40-120 rather than keeping the last (GSM 06.10 4.3.2) and '
                           'saturates differently at extremes; encoders write neither, and its decodes of every '
                           'encoded file above equal libgsm',
                   'equal': native == ffmpeg_mono(work / 'random-0.gsm', 'libgsm')})
    print('32 random frame streams: exact against libgsm', flush=True)

    # Truncation: whole frames play, as libgsm decodes the whole-frame prefix
    # (FFmpeg's raw demuxer reports the cut).
    data = (work / 'speech.gsm').read_bytes()
    wav = (work / 'speech.wav').read_bytes()
    wav = wav[wav.index(b'data') + 8:]
    for name, cut, whole in (('cut.gsm', data[:len(data) - 20], data[:len(data) - 33]),
                             ('cut.wav', wave(wav[:65 * 100 + 40]), wave(wav[:65 * 100]))):
        path, prefix = work / name, work / ('whole-' + name)
        path.write_bytes(cut)
        prefix.write_bytes(whole)
        ours = Path(str(path) + '.f32')
        decode_f32(path, ours)
        if ours.read_bytes() != ffmpeg_mono(prefix, 'libgsm_ms' if name.endswith('.wav') else 'libgsm'):
            raise Failure(f'{name}: differs from libgsm on its whole frames')
        checks.append({'test': name, 'result': 'exact', 'comparator': f'libgsm on {prefix.name}',
                       'note': 'a cut last frame or block is dropped'})

    # Seeks.
    for name in ('speech.wav', 'noise.gsm', 'speech.aifc', 'random-3.wav'):
        path = work / name
        line = run([seek, path, Path(str(path) + '.f32'), '0']).strip().splitlines()[-1]
        checks.append({'test': f'{name} seeks', 'result': line})
        print(f'{name} seeks: {line}', flush=True)

    # Rejections.
    rejected = 0
    for name, data in (('stereo.wav', wave(r.randbytes(65 * 10), channels=2)),
                       ('stereo.aifc', aifc(bytes([0xd0] + [0] * 32) * 20, channels=2))):
        path = work / name
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        code = json.loads(line).get('decode_error')
        if code not in (101,) and not (name.endswith('.aifc') and code):
            raise Failure(f'{name}: expected a rejection, got {line}')
        rejected += 1
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})
    line = run([chain, 'cancel-open', work / 'speech.wav']).strip().splitlines()[-1]
    checks.append({'test': 'cancel-open speech.wav', 'result': line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test': 'GSM playback', 'result': 'played', 'stats': play(work / 'speech.gsm')})
    write_report('gsm', {'result': 'passed', 'checks': checks, 'rejections': rejected,
                         'scope': 'GSM 06.10 in WAVE (Microsoft blocks), AIFF-C and raw .gsm files: FFmpeg libgsm '
                                  'encodes and random frames exact against FFmpeg and libgsm; truncation; seeks; '
                                  'stereo rejections; cancellation.'})
    print(f'Passed {len(checks)} GSM checks.')


if __name__ == '__main__':
    main_guard(main)
