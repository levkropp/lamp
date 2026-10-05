#!/usr/bin/env python3
"""Resampler checks: independent filter evaluation, restarts, tones and aliasing.

usage: python3 tests/verify-resample.py
For each rate pair, tests/resample-oracle.c compares every output frame of the
assembly resampler with a direct long-double evaluation of the specified
windowed-sinc filter and checks that restarts from later input frames
reproduce the continuous output exactly. Sine tones then measure the filter
itself: passband tones must match the ideal resampled sine, and tones above
the output Nyquist frequency must be removed. Writes <out>/resample-verification.json.
"""
import array
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import Failure, build_lamp, build_oracles, exe, main_guard, out_dir, run, scratch, write_report

PAIRS = [(44100, 48000), (48000, 44100), (8000, 48000), (48000, 8000), (22050, 44100), (96000, 44100),
         (192000, 8000), (11025, 48000), (32000, 48000), (44100, 44101), (48000, 47999)]
PASSBAND_DB = 85.0
STOPBAND_DB = 85.0


def write_f32(path, left, right):
    data = array.array('f')
    for a, b in zip(left, right):
        data.append(a)
        data.append(b)
    Path(path).write_bytes(data.tobytes())


def noise(frames, seed):
    state = seed
    values = []
    for _ in range(frames):
        state = (state * 1103515245 + 12345) & 0x7fffffff
        values.append((state / 0x7fffffff - 0.5) * 0.6)
    return values


def tone(frequency, rate, frames, amplitude=0.5, phase=0.0):
    return [amplitude * math.sin(2 * math.pi * frequency * n / rate + phase) for n in range(frames)]


def resample(oracle, work, name, rate_in, rate_out, left, right):
    source = work / f'{name}.f32'
    target = work / f'{name}.out.f32'
    write_f32(source, left, right)
    line = run([oracle, str(rate_in), str(rate_out), source, target]).strip().splitlines()[-1]
    data = array.array('f', target.read_bytes())
    return line, data[0::2], data[1::2]


def error_db(actual, ideal, reference_rms):
    power = sum((a - b) ** 2 for a, b in zip(actual, ideal)) / max(1, len(ideal))
    if power == 0:
        return math.inf
    return 10 * math.log10(reference_rms ** 2 / power)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'resample-oracle': 'resample-oracle.c'}, library)
    oracle = exe('resample-oracle')
    work = scratch('resample')
    checks = []
    for rate_in, rate_out in PAIRS:
        frames = max(2000, rate_in // 5)
        line, _, _ = resample(oracle, work, f'noise-{rate_in}-{rate_out}', rate_in, rate_out,
                              noise(frames, rate_in), noise(frames, rate_out + 7))
        checks.append({'test': f'{rate_in} -> {rate_out} reference and restarts', 'result': line})
        print(line, flush=True)
        # Tones: compare the middle, away from the zero-padded ends.
        lower = min(rate_in, rate_out) / 2
        half = -(-64 * rate_in // rate_out) if rate_in > rate_out else 64
        margin = -(-(half + 2) * rate_out // rate_in)      # outputs whose span reaches the padding
        for fraction in (0.05, 0.5, 0.88):
            frequency = fraction * lower
            _, left, right = resample(oracle, work, f'tone-{rate_in}-{rate_out}-{fraction}', rate_in, rate_out,
                                      tone(frequency, rate_in, frames), tone(frequency, rate_in, frames, 0.25, 1.0))
            ideal_left = tone(frequency, rate_out, len(left))
            ideal_right = tone(frequency, rate_out, len(right), 0.25, 1.0)
            window = slice(margin, len(left) - margin)
            db = min(error_db(left[window], ideal_left[window], 0.5 / math.sqrt(2)),
                     error_db(right[window], ideal_right[window], 0.25 / math.sqrt(2)))
            if db < PASSBAND_DB:
                raise Failure(f'Passband tone {frequency:.0f} Hz at {rate_in} -> {rate_out}: {db:.1f} dB')
            checks.append({'test': f'{rate_in} -> {rate_out} tone {frequency:.0f} Hz', 'result': 'matched',
                           'error_db': round(db, 1)})
        if rate_out < rate_in:
            # Above the output Nyquist frequency: the output must be silent.
            for fraction in (1.02, 1.5):
                frequency = fraction * rate_out / 2
                if frequency >= rate_in / 2:
                    continue
                _, left, right = resample(oracle, work, f'alias-{rate_in}-{rate_out}-{fraction}', rate_in, rate_out,
                                          tone(frequency, rate_in, frames), tone(frequency, rate_in, frames))
                window = slice(margin, len(left) - margin)
                db = error_db(left[window], [0.0] * len(left[window]), 0.5 / math.sqrt(2))
                if db < STOPBAND_DB:
                    raise Failure(f'Alias of {frequency:.0f} Hz at {rate_in} -> {rate_out}: only {db:.1f} dB down')
                checks.append({'test': f'{rate_in} -> {rate_out} rejects {frequency:.0f} Hz', 'result': 'rejected',
                               'attenuation_db': round(db, 1)})
        print(f'{rate_in} -> {rate_out}: tones and aliasing passed', flush=True)
    write_report('resample', {'result': 'passed', 'pairs': len(PAIRS), 'checks': checks,
                              'scope': 'Assembly windowed-sinc resampler: per-frame comparison with a direct long-double evaluation of the specified filter, exact restarts, passband tones within 0.88 of the lower Nyquist frequency at least 85 dB below the ideal sine, and tones above the output Nyquist frequency attenuated at least 85 dB. Pairs include exact-phase tables and interpolated tables for rates without a small common divisor.'})
    print(f'Passed {len(checks)} resampler checks.')


if __name__ == '__main__':
    main_guard(main)
