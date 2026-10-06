#!/usr/bin/env python3
"""Runs LAMP's portable verification suites in order.

usage: python3 tests/run.py [--quick] [--skip-playback] [--skip-network]

--quick runs the build, smoke checks, table provenance and the 35 Opus
component suites, which need no FFmpeg fixtures. Without it, every FFmpeg-based
suite also runs. On Linux, playback checks use a private PulseAudio null sink
when PulseAudio is installed. Windows-only WASAPI/GUI checks stay in
tests/verify-engine.ps1 and tests/render-ui.ps1.
"""
from pathlib import Path
import subprocess
import sys

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))
from lamp_test import WINDOWS, Failure, audio_environment, build_lamp, main_guard, opus_reference

ENVIRONMENT = None


def step(*args):
    print('==', ' '.join(str(a) for a in args), flush=True)
    if subprocess.run([sys.executable if str(args[0]).endswith('.py') else 'node', *[str(a) for a in args]],
                      cwd=TESTS.parent, env=ENVIRONMENT).returncode:
        raise Failure(f'{Path(str(args[0])).name} failed')


def main():
    global ENVIRONMENT
    arguments = sys.argv[1:]
    playback = ['--skip-playback'] if '--skip-playback' in arguments else []
    if not playback and '--quick' not in arguments and not WINDOWS:
        # One private PulseAudio null sink serves every playback check.
        ENVIRONMENT = audio_environment()
        if ENVIRONMENT is None:
            print('PulseAudio is not installed; skipping playback checks.', flush=True)
            playback = ['--skip-playback']
    build_lamp()
    step(TESTS / 'smoke.js')
    reference = opus_reference()
    step(TESTS / 'generate-mp3-tables.js', '--check')
    step(TESTS / 'generate-aac-tables.py', '--check')
    step(TESTS / 'generate-sbr-tables.py', '--check')
    step(TESTS / 'generate-ac3-tables.py', '--check')
    step(TESTS / 'generate-wavpack-tables.py', '--check')
    for generator in ('celt-tables', 'celt-spectral-tables', 'celt-transform-tables', 'silk-stereo-tables',
                      'silk-resampler-tables', 'silk-lpc-tables', 'silk-nlsf-tables', 'silk-indices-tables',
                      'silk-parameters-tables'):
        step(TESTS / f'generate-{generator}.js', reference, '--check')
    step(TESTS / 'verify-opus-components.py')
    step(TESTS / 'verify-ogg-crc.py')
    if '--quick' in arguments:
        return
    step(TESTS / 'verify-pcm.py', *playback)
    step(TESTS / 'verify-mp3.py', *playback)
    step(TESTS / 'verify-mp2.py', *playback)
    step(TESTS / 'verify-vorbis.py', *playback)
    step(TESTS / 'verify-opus.py')
    step(TESTS / 'verify-opus-multichannel.py')
    step(TESTS / 'verify-seek.py')
    step(TESTS / 'verify-containers.py')
    step(TESTS / 'verify-resample.py')
    step(TESTS / 'verify-ogg-chain.py')
    step(TESTS / 'verify-matroska.py', *playback)
    step(TESTS / 'verify-mp4.py', *playback)
    step(TESTS / 'verify-aac.py', *playback)
    step(TESTS / 'verify-heaac.py', *playback)
    step(TESTS / 'verify-ac3.py', *playback)
    step(TESTS / 'verify-mpegts.py', *playback)
    step(TESTS / 'verify-wavpack.py', *playback)
    if not WINDOWS and not playback:
        step(TESTS / 'verify-playback.py')
    if '--skip-network' not in arguments:
        step(TESTS / 'verify-opus-conformance.py')
    print('All requested suites passed.')


if __name__ == '__main__':
    main_guard(main)
