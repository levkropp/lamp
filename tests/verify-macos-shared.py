#!/usr/bin/env python3
"""Record a current x86 corpus, then verify the native ARM64 decoder against it.

First run the ordinary format suites on Linux to generate their fixtures. On
Linux: --record --binary build/lamp-cli --corpus build/mac-corpus. Copy that
directory to the Mac, then run --corpus PATH --binary-directory build/macos.
Reference C and the comparison PCM are test artifacts, never player dependencies.
"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = ['aac-pce', 'gsm', 'mp4', 'latm', 'heaac', 'ac3',
          'caf-wave64', 'wav-codecs', 'mpegts']
EXTENSIONS = {'.aac', '.loas', '.latm', '.m4a', '.mp4', '.mov', '.mka', '.mkv',
              '.webm', '.wav', '.aiff', '.aifc', '.caf', '.w64', '.ac3', '.eac3',
              '.mp1', '.mp2', '.mp3', '.ts', '.m2ts', '.vob', '.mpg', '.gsm',
              '.ogg', '.opus', '.flac', '.wv', '.ape', '.au', '.flv', '.avi', '.asf'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def shared_identity():
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT/'src').iterdir())
            if p.suffix in ('.s', '.inc')}


def run(command, statuses=(0,), timeout=120):
    p = subprocess.run(list(map(str, command)), capture_output=True, timeout=timeout)
    if p.returncode not in statuses:
        raise RuntimeError(f'{command}: exit {p.returncode}: {p.stdout[-1000:]!r} {p.stderr[-1000:]!r}')
    return p.returncode, p.stdout.decode('utf-8', 'replace').strip()


def record(args):
    corpus = args.corpus.resolve()
    corpus.mkdir(parents=True, exist_ok=True)
    cases, guards = [], []
    for suite in args.suites:
        prior = json.loads((ROOT/'reports'/f'{suite}-verification.json').read_text())
        names = sorted({c.get('test', '') for c in prior['checks']
                        if Path(c.get('test', '')).suffix in EXTENSIONS
                        and (args.fixtures/suite/c.get('test', '')).is_file()})
        seeks = {}
        for c in prior['checks']:
            name = c.get('test', '')
            result = c if c.get('result') == 'passed' else c.get('result', '')
            if isinstance(result, str) and result.startswith('{'):
                result = json.loads(result)
            if not isinstance(result, dict) or result.get('checks') != 15: continue
            for suffix in (' exact seeks', ' seeks'):
                if name.endswith(suffix):
                    name = name[:-len(suffix)]
                    if (args.fixtures/suite/name).is_file():
                        seeks[name] = 127 if result.get('maximum_deviation', 0) else 0
                        names.append(name)
                    break
        names = sorted(set(names))
        if not names:
            raise RuntimeError(f'No generated fixtures for {suite}; run its original suite first')
        for name in names:
            source = args.fixtures/suite/name
            target = corpus/suite/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            pcm = Path(str(target) + '.x86.f32')
            pcm.unlink(missing_ok=True)
            code, stats = run([args.binary, '--decode', source, pcm], (0, 2))
            entry = dict(file=f'{suite}/{name}', input_sha256=sha(target), exit=code, stats=stats)
            if name in seeks: entry['seek_tolerance_units'] = seeks[name]
            if code == 0:
                entry.update(pcm_sha256=sha(pcm), frames=pcm.stat().st_size//8)
            else:
                pcm.unlink(missing_ok=True)
            cases.append(entry)
        print(suite, len(names), 'current x86 cases', flush=True)
        if suite == 'aac-pce':
            for name, oracle in [(n, 'pce-packet') for n in (
                    'stereo-tags-shuffled.packets', 'eight-single-shuffled.packets',
                    'he-eight-single-shuffled.packets', 'ps-mono-ordered.packets',
                    'ps-back-mono-ordered.packets')] + [(n, 'pce-latm') for n in (
                    'stereo-tags-shuffled-v0.loas', 'eight-single-shuffled-v1.loas',
                    'ps-mono-ordered.loas')]:
                target = corpus/suite/name
                shutil.copyfile(args.fixtures/suite/name, target)
                guards.append(dict(file=f'{suite}/{name}', input_sha256=sha(target), oracle=oracle))
    manifest = dict(platform=platform.platform(), binary_sha256=sha(args.binary),
                    shared_sources=shared_identity(), cases=cases, guards=guards)
    (corpus/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')


def compare(actual, reference):
    a, b = array.array('f', actual), array.array('f', reference)
    if len(a) != len(b) or not all(map(math.isfinite, a)) or not all(map(math.isfinite, b)):
        raise RuntimeError('PCM length or finite-sample mismatch')
    peak = max((abs(x-y) for x, y in zip(a, b)), default=0.)
    noise = sum((x-y)**2 for x, y in zip(a, b))
    power = sum(x*x for x in b)
    snr = 999. if noise == 0 else 10*math.log10(power/noise) if power else -999.
    # These retained fixtures reproduce the current x86 implementation exactly;
    # do not hide a translation regression behind codec-reference tolerances.
    if actual != reference:
        raise RuntimeError(f'PCM mismatch: peak {peak}, SNR {snr}')
    return dict(byte_exact=actual == reference, peak_error=peak, snr_db=snr)


def verify(args):
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise RuntimeError('Verification requires native Apple Silicon macOS')
    import os
    import lamp_test
    out = args.binary_directory.resolve()
    os.environ['LAMP_OUT'] = str(out)
    library = lamp_test.build_lamp() if not args.skip_build else out/'liblamp-test.dylib'
    lamp_test.build_oracles(out/'shared-oracles', {'seek': 'seek-oracle.c',
                            'chain': 'chain-oracle.c', 'pce-packet': 'aac-pce-packet-oracle.c',
                            'pce-latm': 'aac-pce-latm-oracle.c'}, library)
    manifest = json.loads((args.corpus/'manifest.json').read_text())
    if manifest['shared_sources'] != shared_identity():
        raise RuntimeError('The x86 corpus must use the same shared source files')
    report = dict(result='in_progress', platform=platform.platform(),
                  binary_sha256=sha(out/'lamp-cli'), baseline_binary_sha256=manifest['binary_sha256'],
                  shared_sources=manifest['shared_sources'], checks=[], scope=
                  'Byte-exact current x86 vs native ARM64 PCM/rejections on retained format-suite fixtures; '
                  'native continuous-PCM seek checks. Existing independent codec-reference reports '
                  'retain their original platforms and coverage.')
    report['seek_scope'] = ('The 15-target exact/IMA4-policy cases from the original suites. '
                            'HE-AAC approximate reconstruction seeks are outside these exact checks.')
    destination = out/'macos-shared-verification.json'
    def save(): destination.write_text(json.dumps(report, indent=2)+'\n')
    save()
    try:
        for c in manifest['cases']:
            if c['file'].split('/')[0] not in args.suites: continue
            path = args.corpus/c['file']
            if sha(path) != c['input_sha256']: raise RuntimeError('Input hash mismatch: '+c['file'])
            output = out/'cross-architecture.f32'
            output.unlink(missing_ok=True)
            code, stats = run([out/'lamp-cli', '--decode', path, output], (0, 2))
            entry = dict(file=c['file'], input_sha256=c['input_sha256'], exit=code, stats=stats)
            if code != c['exit']: raise RuntimeError(f'{c["file"]}: exit {code} != {c["exit"]}')
            if code == 0:
                reference = Path(str(path)+'.x86.f32')
                if sha(reference) != c['pcm_sha256']: raise RuntimeError('Reference hash mismatch')
                entry.update(compare(output.read_bytes(), reference.read_bytes()), frames=c['frames'])
                # IMA4 has the same near-exact packet-reset policy as the original
                # CAF/AIFF/QuickTime suites; all other requested seeks are exact.
                if args.seeks and c['frames'] and 'seek_tolerance_units' in c:
                    tolerance = c['seek_tolerance_units']
                    _, result = run([out/'shared-oracles/seek', path, output, 0, 0, tolerance], timeout=300)
                    entry['seeks'] = json.loads(result)
            report['checks'].append(entry)
            save()
            print(c['file'], 'rejected' if code else 'PCM passed', flush=True)
        report['guarded_checks'] = []
        for c in manifest.get('guards', []):
            if c['file'].split('/')[0] not in args.suites: continue
            path = args.corpus/c['file']
            if sha(path) != c['input_sha256']: raise RuntimeError('Guard input hash mismatch')
            _, result = run([out/'shared-oracles'/c['oracle'], path], timeout=300)
            report['guarded_checks'].append(dict(c, stats=json.loads(result)))
            save()
            print(c['file'], 'guarded checks passed', flush=True)
    except Exception as error:
        report.update(result='failed', failure=str(error)); save(); raise
    report['result'] = 'passed'
    save()
    print(destination)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--record', action='store_true')
    p.add_argument('--binary', type=Path, default=ROOT/'build/lamp-cli')
    p.add_argument('--fixtures', type=Path, default=ROOT/'tests/generated')
    p.add_argument('--corpus', type=Path, required=True)
    p.add_argument('--binary-directory', type=Path, default=ROOT/'build/macos')
    p.add_argument('--skip-build', action='store_true')
    p.add_argument('--seeks', action='store_true')
    p.add_argument('--suites', nargs='+', default=SUITES)
    args = p.parse_args()
    (record if args.record else verify)(args)


if __name__ == '__main__':
    main()
