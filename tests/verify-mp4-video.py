#!/usr/bin/env python3
"""Verify the original assembly MP4 video index, without opening audio devices.

Model/malformed payloads stay CPU-only. --encoded-dir adds FFmpeg-generated
inputs with saved ffprobe packets; only separately verified, encoded HPA files
are suitable for the H.264 GPU oracle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from fractions import Fraction

from lamp_test import ROOT, WINDOWS, compile_c, out_dir
from mp4_video_fixtures import cases, rejects, classic, replace_field, be, box, tracks_case


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(oracle, source, destination, choice=None, timeout=60):
    args = [str(oracle), str(source), str(destination)]
    if choice is not None:
        args.append(str(choice))
    p = subprocess.run(args, capture_output=True, timeout=timeout,
                       **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    lines = [json.loads(line) for line in p.stdout.splitlines()]
    assert p.returncode in (0, 1), (source.name, p.returncode, p.stderr.decode(errors='replace'))
    assert lines, (source.name, p.stderr.decode(errors='replace'))
    return p.returncode, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--encoded-dir', action='append', default=[])
    parser.add_argument('--large', action='store_true', help='also check the 1,048,576-packet limit')
    parser.add_argument('--controls', action='store_true', help='prove selected tests reject isolated broken policies')
    args = parser.parse_args()
    out = out_dir()
    work = out / 'mp4-video'
    model = work / 'models'
    model.mkdir(parents=True, exist_ok=True)
    suffix = '.obj' if WINDOWS else '.o'
    assembly = out / ('obj/video_mp4' + suffix)
    oracle = work / ('mp4-video-oracle' + ('.exe' if WINDOWS else ''))
    memory = work / ('mp4-video-memory' + ('.exe' if WINDOWS else ''))
    platform = out / ('obj/platform.obj' if WINDOWS else 'obj/linux_platform.o')
    libraries = list((out / 'obj').glob('*.lib')) if WINDOWS else []
    compile_c(oracle, [ROOT/'tests/mp4-video-oracle.c'], objects=[assembly, platform], libraries=libraries)
    compile_c(memory, [ROOT/'tests/mp4-video-oracle.c'], objects=[assembly], defines=['LAMP_MEMORY_ORACLE'])
    report = dict(result='passed', platform=sys.platform, cpu_only=True,
                  object_sha256=sha(assembly), oracle_sha256=sha(oracle),
                  memory_oracle_sha256=sha(memory), sources={}, models=[], rejects=[],
                  allocations=[], guards=[], encoded=[], limits=[], tracks=[], api=[])
    for source in sorted((ROOT/'src').glob('video_mp4*')):
        report['sources'][source.relative_to(ROOT).as_posix()] = sha(source)
    for source in (ROOT/'tests/mp4-video-oracle.c', Path(__file__), ROOT/'tests/mp4_video_fixtures.py'):
        report['sources'][source.relative_to(ROOT).as_posix()] = sha(source)
    valid = list(cases())
    empty, expected = classic(sizes=(0, 0, 0))
    empty = replace_field(empty, 'stco', 8, be(0))
    for packet in expected:
        packet['offset'] = 0
    valid.append(('empty-offset-zero', (empty, expected)))
    for name, (data, expected) in valid:
        source = model / (name+'.mp4')
        source.write_bytes(data)
        code, actual = invoke(oracle, source, model/(name+'.hpa'))
        assert code == 0, (name, actual)
        assert actual[1:-1] == expected, (name, 'packet mismatch', actual[1:-1], expected)
        assert actual[0]['count'] == len(expected) and actual[-1]['packets'] == len(expected), name
        (model/(name+'.expected.json')).write_text(json.dumps(expected, indent=2)+'\n')
        report['models'].append(dict(name=name, sha256=sha(source), packets=len(expected), checks=actual[-1]['checks']))
    malformed = list(rejects()) + [('empty-offset-outside-file', replace_field(empty, 'stco', 8, be(len(empty)+1)), 1)]
    for name, data, expected_error in malformed:
        source = model/(name+'.mp4'); source.write_bytes(data)
        code, actual = invoke(oracle, source, model/(name+'.hpa'))
        assert code == 1 and actual == [dict(result='rejected', error=expected_error)], (name, code, actual, expected_error)
        report['rejects'].append(dict(name=name, sha256=sha(source), error=expected_error))
    for name, options in [('enabled', {}), ('disabled', dict(enabled=False)),
                          ('unsupported', dict(codec='hvc1')), ('external', dict(external=True))]:
        data, expected1, expected2 = tracks_case(options)
        source = model/('tracks-'+name+'.mp4'); source.write_bytes(data)
        for choice in (0, 1, 2, 3):
            code, actual = invoke(oracle, source, model/'track.hpa', choice)
            selected = 1 if choice == 0 and name == 'enabled' else 2 if choice == 0 else choice
            rejected = selected == 3 or selected == 1 and name in ('unsupported', 'external')
            if rejected:
                assert code == 1 and actual == [dict(result='rejected', error=2)], (name, choice, actual)
            else:
                assert code == 0 and actual[0]['video_tracks'] == 2 and actual[0]['track_id'] == selected, (name, choice, actual)
                assert actual[1:-1] == (expected1 if selected == 1 else expected2), (name, choice, actual)
            report['tracks'].append(dict(name=name, choice=choice, rejected=rejected, selected=0 if rejected else selected))
    # Allocation failure/cancel after every reservation/commit/allocation,
    # including one picture and growth beyond the initial 64 KiB commit.
    for name, n in [('one', 1), ('growth', 2000), ('empty', 0)]:
        source = model/(name+'-allocation.mp4')
        source.write_bytes(classic(sizes=(1,)*n)[0])
        code, actual = invoke(memory, source, '--alloc')
        assert code == 0 and actual[-1]['result'] == 'passed', (name, actual)
        report['allocations'].append(dict(name=name, **actual[-1]))
    for name in ('classic', 'empty', 'fragment-ctts-signed'):
        code, actual = invoke(memory, model/(name+'.mp4'), '--api')
        assert code == 0 and actual[-1]['result'] == 'passed', (name, actual)
        report['api'].append(dict(name=name, **actual[-1]))
    for name in ('classic', 'co64-chunks-mdats', 'fragment-ctts-signed', 'rational-010'):
        code, actual = invoke(memory, model/(name+'.mp4'), '--guard')
        assert code == 0 and actual[-1]['opens'] == 3074, (name, actual)
        report['guards'].append(dict(name=name, **actual[-1]))
    if args.large:
        # One MiB opaque bytes, zero-duration repeated timestamps. No JSON per
        # packet and no hardware; exercise exact record/sort caps and cleanup.
        source = model/'maximum.mp4'
        source.write_bytes(classic(sizes=(1,)*1048576, deltas=(0,)*1048576, constant=True, expect=False)[0])
        code, actual = invoke(memory, source, '--scan', timeout=120)
        assert code == 0 and actual[-1]['packets'] == 1048576, actual
        report['limits'].append(dict(name='maximum', sha256=sha(source), **actual[-1]))
        empty = classic(sizes=())[0]
        for n, expected_error in [(65536, None), (65537, 3)]:
            # The initialization already contains one empty mdat.
            source = model/('mdats-'+str(n)+'.mp4')
            source.write_bytes(empty + box('mdat')*(n-1))
            code, actual = invoke(memory, source, '--scan')
            if expected_error is None:
                assert code == 0 and actual[-1]['packets'] == 0, actual
            else:
                code, actual = invoke(oracle, source, model/'too-many-mdats.hpa')
                assert code == 1 and actual == [dict(result='rejected', error=expected_error)], actual
            report['limits'].append(dict(name=f'mdats-{n}', sha256=sha(source), **actual[-1]))
    for folder in args.encoded_dir:
        for source in sorted(Path(folder).glob('*.mp4')):
            probe_path = source.with_suffix('.probe.json')
            if not probe_path.exists():
                continue
            probe = json.loads(probe_path.read_text())
            stream = next(x for x in probe['streams'] if x['codec_type'] == 'video')
            packets = [x for x in probe['packets'] if x['stream_index'] == stream['index']]
            scale = Fraction(stream['time_base'])
            target = work/('encoded-'+source.stem+'.hpa')
            code, actual = invoke(oracle, source, target)
            assert code == 0 and len(actual[1:-1]) == len(packets), (source.name, actual)
            for a, b in zip(actual[1:-1], packets):
                assert (a['offset'], a['size']) == (int(b['pos']), int(b['size'])), (source.name, a, b)
                assert a['dts_ns'] == int(b['dts'])*scale*10**9//1, (source.name, 'dts', a, b)
                assert a['pts_ns'] == int(b['pts'])*scale*10**9//1, (source.name, 'pts', a, b)
                assert bool(a['flags'] & 1) == ('K' in b['flags']), (source.name, 'sync', a, b)
            (work/('encoded-'+source.stem+'.json')).write_text(json.dumps(actual, indent=2)+'\n')
            report['encoded'].append(dict(name=source.name, sha256=sha(source), packets=len(packets), hpa_sha256=sha(target)))
            if source.stem in ('main-b', 'interleave'):
                code, guarded = invoke(memory, source, '--guard')
                assert code == 0 and guarded[-1]['opens'] == 3074, (source.name, guarded)
                report['guards'].append(dict(name='encoded-'+source.stem, **guarded[-1]))
    if args.controls:
        from mp4_video_controls import check_controls
        report['sources']['tests/mp4_video_controls.py'] = sha(ROOT/'tests/mp4_video_controls.py')
        report['controls'] = check_controls(out, work, invoke, sha)
    path = out/'mp4-video-verification.json'
    path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(result='passed', models=len(report['models']), rejects=len(report['rejects']),
                         model_packets=sum(x['packets'] for x in report['models']),
                         encoded_packets=sum(x['packets'] for x in report['encoded']), report=str(path))))


if __name__ == '__main__':
    main()
