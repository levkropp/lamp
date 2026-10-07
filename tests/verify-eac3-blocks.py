#!/usr/bin/env python3
"""Deferred synthesis: CRC-valid failures in every block and frame recovery.

The sequential model remains independent of the assembly's snapshot pipeline.
SPX draws noise after each block, interleaved with conventional/AHT dither.
Prepared references are hash checked before Linux or native Windows execution.
"""
import array
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ac3_model as ac3
import eac3_model as model
import eac3_vectors as vectors
from lamp_test import (ROOT, Failure, build_lamp, decode_f32, main_guard, out_dir,
                       run, scratch, stereo_view, write_report)

spec = importlib.util.spec_from_file_location('verify_ac3', Path(__file__).with_name('verify-ac3.py'))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)


class Positions(ac3.Reader):
    def __init__(self, data):
        super().__init__(data, 40)
        self.block = -1
        self.fields = {}

    def mark(self, event, *context):
        if event == 'block': self.block = context[0]

    def get(self, n, label=None, *context):
        if label in ('spxbegf', 'spxendf'):
            self.fields[self.block, label] = (self.pos, n)
        return super().get(n, label, *context)


def pcm(data):
    channels, decoder = model.decode(data)
    count = len(channels)
    interleaved = array.array('f', [0.0]) * (len(channels[0]) * count)
    for ch, position in enumerate(base.CHANNEL_MAP[(decoder.acmod, decoder.lfe)]):
        interleaved[position::count] = array.array('f', channels[ch])
    mask = base.MASKS[decoder.acmod] | (8 if decoder.lfe else 0)
    return stereo_view(interleaved.tobytes(), count, mask), decoder


def set_field(data, field, value):
    position, width = field
    for i in range(width):
        at = position + i
        mask = 1 << (7 - at % 8)
        data[at // 8] = (data[at // 8] & ~mask) | (((value >> (width-1-i)) & 1) * mask)


def prepare(work):
    fixtures = []
    for aht in (False, True):
        profile = 'aht-spx' if aht else 'spx'
        clean, _ = vectors.stream(8400 + aht, frames=4, acmod=7, lfe=1,
            coupling=1, cplstre=0, spxinu=1, spxstre=1, spxbegf=4, spxendf=7,
            spxstrtf=0, spxcoe=1, spxbndstrce=0, short=0.3, ahte=int(aht),
            ahtinu=int(aht), metadata=0)
        frames = list(model.frames(clean))
        positions = Positions(frames[1])
        decoder = model.Decoder()
        decoder.frame(frames[0])
        decoder.decode_frame(positions, model.header(frames[1]), strict=True)
        reference, _ = pcm(clean)
        for bad in (None, *range(6)):
            payload = clean
            if bad is not None:
                damaged = bytearray(frames[1])
                set_field(damaged, positions.fields[bad, 'spxbegf'], 7)
                set_field(damaged, positions.fields[bad, 'spxendf'], 0)
                payload = frames[0] + vectors.recrc(damaged) + b''.join(frames[2:])
            expected, decoder = pcm(payload)
            if bad is None and 'block error' in decoder.used:
                raise Failure(profile + ': valid fixture failed')
            if bad is not None:
                if 'block error' not in decoder.used:
                    raise Failure(profile + ': corrupted strategy did not fail')
                boundary = (6 + bad) * 256 * 8
                if expected[:boundary] != reference[:boundary]:
                    raise Failure(profile + ': valid prefix changed')
                last = expected[boundary-256*8:boundary]
                for block in range(bad, 6):
                    at = (6 + block) * 256 * 8
                    if expected[at:at+256*8] != last:
                        raise Failure(profile + ': concealment did not repeat the last block')
                recovery = expected[12*256*8:13*256*8]
                if recovery == last:
                    raise Failure(profile + ': next frame did not recover')
            name = profile + ('-clean' if bad is None else f'-bad-block-{bad}') + '.ec3'
            files = {name: payload, name+'.model.f32': expected}
            for filename, contents in files.items(): (work/filename).write_bytes(contents)
            fixtures.append(dict(name=name, failed_block=bad,
                files={filename: hashlib.sha256(contents).hexdigest() for filename, contents in files.items()}))
            print('Prepared ' + name, flush=True)
    manifest = dict(fixtures=fixtures, model_environment=dict(python=sys.version),
        scope='Sequential normative model; CRC-valid bad SPX ranges in each of six blocks, AHT/SPX dither and recovery')
    (work/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    return manifest


def main():
    work = scratch('eac3-blocks')
    if '--wine-only' in sys.argv: return windows_checks(work)
    manifest = json.loads((work/'manifest.json').read_text()) if '--prepared' in sys.argv else prepare(work)
    if '--prepare-only' in sys.argv: return
    build_lamp()
    checks = []
    for fixture in manifest['fixtures']:
        for name, digest in fixture['files'].items():
            if hashlib.sha256((work/name).read_bytes()).hexdigest() != digest:
                raise Failure('fixture changed: ' + name)
        path = work/fixture['name']
        output = Path(str(path)+'.f32')
        stats = decode_f32(path, output)
        if output.read_bytes() != Path(str(path)+'.model.f32').read_bytes():
            raise Failure(path.name + ': differed from sequential model')
        checks.append(dict(test=path.name, result='byte-exact sequential model PCM',
                           failed_block=fixture['failed_block'], stats=stats))
        print('Verified ' + path.name, flush=True)
    write_report('eac3-blocks', dict(result='passed', checks=checks,
        scope=manifest['scope'], fixture_model_environment=manifest['model_environment']))
    print(f'Passed {len(checks)} deferred-block checks.', flush=True)


def windows_checks(work):
    report = json.loads((out_dir()/'eac3-blocks-verification.json').read_text())
    if report['result'] != 'passed': raise Failure('native block checks must pass before Wine')
    run([sys.executable, ROOT/'tools/build-windows.py'], capture=False)
    env = dict(os.environ, WINEDEBUG=os.environ.get('WINEDEBUG', '-all'))
    checks = []
    for check in report['checks']:
        path = work/check['test']
        output = work/'windows.f32'; output.unlink(missing_ok=True)
        with tempfile.TemporaryFile() as log:
            result = subprocess.run(['wine', str(ROOT/'bin/lamp-cli.exe'), '--decode', str(path), str(output)],
                stdout=log, stderr=subprocess.STDOUT, env=env, timeout=120)
            if result.returncode:
                log.seek(0)
                raise Failure(f'Wine {path.name}: exit {result.returncode}: {log.read()[-1024:]}')
        if output.read_bytes() != Path(str(path)+'.f32').read_bytes():
            raise Failure('Windows ' + path.name + ': PCM differs')
        checks.append(dict(test=path.name, result='exact Linux PCM'))
    write_report('eac3-blocks-wine', dict(result='passed', checks=checks,
                                        scope='Shipping PE vs native PCM for every concealment boundary'))
    print(f'Passed {len(checks)} Windows block checks.', flush=True)


if __name__ == '__main__': main_guard(main)
