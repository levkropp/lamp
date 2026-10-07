#!/usr/bin/env python3
"""Compare the recorded pre-metadata ASF binary with the current native one.

usage: LAMP_OUT=build-asf-meta-final python3 tests/verify-asf-metadata-negative.py BASELINE_CLI
The baseline must match reports/asf-verification.json from commit 8303b30.
Both fixture generation and a current metadata suite must have passed first.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import ROOT, Failure, lamp_cli, main_guard, out_dir, scratch, write_report


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(args):
    p = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    return p.returncode, p.stdout.decode('utf-8').strip()


def main():
    if len(sys.argv) != 2: raise Failure('Pass the recorded pre-metadata native ASF CLI')
    baseline = Path(sys.argv[1]).resolve(); current = lamp_cli(); work = scratch('asf-metadata')
    baseline_report = ROOT / 'reports/asf-verification.json'
    old = json.loads(baseline_report.read_text())
    if sha(baseline) != old['cli_sha256']: raise Failure('Baseline binary differs from the published ASF report')
    new_report = out_dir() / 'asf-metadata-verification.json'
    new = json.loads(new_report.read_text())
    if new['result'] != 'passed' or sha(current) != new['cli_sha256']:
        raise Failure('Current binary does not match a passed metadata suite')
    cases = []
    for name, choice in (('basic.asf', 0), ('cover-library.asf', 0), ('selected-stream-2.asf', 2)):
        source = work / name
        if sha(source) != new['fixture_hashes'][name]: raise Failure('Fixture changed: ' + name)
        options = ['--track', choice] if choice else []
        a = command([baseline, *options, '--tags', source]); b = command([current, *options, '--tags', source])
        expected = {'basic.asf': 'title=Tïtle 漢字 🎵\nartist=Ärtist\ncomment=Cömment',
                    'cover-library.asf': '', 'selected-stream-2.asf': 'title=Other stream\nartist=Global artist'}[name]
        if a != (0, '') or b != (0, expected): raise Failure(name + ': unexpected before/after tags')
        outputs = [work / ('negative-before-' + name + '.f32'), work / ('negative-after-' + name + '.f32')]
        for binary, target in zip((baseline, current), outputs):
            target.unlink(missing_ok=True)
            code, text = command([binary, *options, '--decode', source, target])
            if code: raise Failure(name + ': PCM decode failed: ' + text)
        if outputs[0].read_bytes() != outputs[1].read_bytes(): raise Failure(name + ': audio changed')
        picture = None
        if name == 'cover-library.asf':
            old_picture = work / 'negative-before-cover.bin'; new_picture = work / 'negative-after-cover.bin'
            old_picture.unlink(missing_ok=True); new_picture.unlink(missing_ok=True)
            old_cover = command([baseline, '--cover', source, old_picture])
            new_cover = command([current, '--cover', source, new_picture])
            if old_cover != (2, 'No embedded cover art.') or old_picture.exists() or new_cover[0] or \
                    new_picture.read_bytes() != (work / 'front.png').read_bytes():
                raise Failure('Unexpected before/after cover bytes')
            picture = dict(before_exit=old_cover[0], before=old_cover[1], after=new_cover[1], sha256=sha(new_picture))
        cases.append(dict(test=name, choice=choice, before_tags=a[1], after_tags=b[1],
                          unchanged_pcm_sha256=sha(outputs[1]), picture=picture, fixture_sha256=sha(source)))
    write_report('asf-metadata-negative-control', dict(result='passed', checks=cases,
                 baseline_commit='8303b30e5eb281b250c6ef604e3e6bf0f5357f48', baseline_cli_sha256=sha(baseline),
                 baseline_report_sha256=sha(baseline_report), baseline_runtime_sources=old['runtime_sources'],
                 current_cli_sha256=sha(current), current_report_sha256=sha(new_report),
                 current_runtime_sources=new['runtime_sources'], runner_sha256=sha(__file__)))
    print('Passed 3 before/after metadata checks with unchanged PCM.')


if __name__ == '__main__': main_guard(main)
