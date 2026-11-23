#!/usr/bin/env python3
"""Selected Matroska SeekPreRoll: independent restart points and suffix PCM."""
import argparse
from bisect import bisect_right
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import ROOT, WINDOWS, compile_c


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def run(args, timeout=180):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout,
                            **({'creationflags': subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} ({result.returncode}): {result.stdout[-1600:]} {result.stderr[-1600:]}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', type=Path, default=ROOT / ('bin/mkv-preroll-check' if WINDOWS else 'build/mkv-preroll-check'))
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--probe', action='store_true', help='run only a marked muted native Windows playback probe')
    parser.add_argument('--case', help='debug a filename prefix; writes a separate partial report')
    args = parser.parse_args()
    out = args.bin.resolve()
    work = out / 'matroska-preroll'
    work.mkdir(parents=True, exist_ok=True)
    extension = '.exe' if WINDOWS else ''
    cli = out / ('lamp-cli' + extension)
    mkv = module('mkv_helpers', ROOT / 'tests/verify-matroska.py')
    shared = {p.stem for p in (ROOT / 'src').glob('*.s')} | {'platform', 'linux_platform'}
    objects = [p for p in sorted((out / 'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared]
    libraries = list((out / 'obj').glob('*.lib')) if WINDOWS else ['-no-pie', '-Wl,-z,noexecstack']
    source_oracle=out/('matroska-preroll-source'+extension)
    compile_c(source_oracle,[ROOT/'tests/track-source-oracle.c'],objects=objects,libraries=libraries)

    def decode(path):
        target = work / 'scratch.f32'
        target.unlink(missing_ok=True)
        run([source_oracle, path, 0, target])
        return target.read_bytes()

    if args.fixtures:
        source = args.fixtures.resolve()
        manifest = json.loads((source / 'fixtures.json').read_text(encoding='utf-8'))
        if source != work:
            for name in manifest['files']:
                shutil.copyfile(source / name, work / name)
    else:
        manifest = {'cases': [], 'bad': [], 'files': [], 'ffmpeg': run(['ffmpeg', '-version']).splitlines()[0]}

        def save(name, data):
            (work / name).write_bytes(data)
            manifest['files'].append(name)

        def make(track, lengths, ns=None, padded=False, extra=False, early=False, raw_element=None, duplicate=False):
            entry = mkv.uint(0xD7, 7) + mkv.uint(0x83, 2) + mkv.uint(0x88, 1)
            timing = raw_element if raw_element is not None else (mkv.uint(0x56BB, ns) if ns is not None else b'')
            if duplicate:
                timing += mkv.uint(0x56BB, 0)
            if early:
                entry += timing
            entry += mkv.element(0x86, track['codec'].encode())
            if track.get('private'):
                entry += mkv.element(0x63A2, track['private'])
            entry += mkv.element(0xE1, track['audio'])
            if not early:
                entry += timing
            if padded:
                entry += mkv.uint(0x56AA, 6500000)
            other = mkv.element(0xAE, mkv.uint(0xD7, 91) + mkv.uint(0x83, 2) + mkv.element(0x86, b'A_DTS') + mkv.uint(0x56BB, (1 << 64) - 1)) if extra else b''
            groups = mkv.blocks_of(track['frames'], 3 if padded else 0, 3)
            blocks, removed, raw, packet, presented = [], [], 0, 0, 0
            head = (6500000 * track['rate'] + 500000000) // 1000000000 if padded else int.from_bytes(track['private'][10:12], 'little') if track['codec'] == 'A_OPUS' else 0
            for index, group in enumerate(groups):
                count = sum(lengths[packet:packet + len(group)])
                packet += len(group)
                amount = (min(count, [1, 17, count, count // 2][index % 4]) * (-1 if index % 2 == 0 else 1)) if padded else 0
                first=max(raw+max(-amount,0),head);end=raw+count-max(amount,0)
                coded=presented+head-(first-raw) if first<end else raw
                pts=(abs(coded)*1000000000+track['rate']//2)//track['rate'];pts=-pts if coded<0 else pts
                ticks=(abs(pts)+500)//1000;ticks=-ticks if pts<0 else ticks
                cluster=max(0,ticks);relative=ticks-cluster
                payload = mkv.size_bytes(7) + struct.pack('>h',relative) + bytes([0x86 if len(group) > 1 else 0x80])
                payload += mkv.lace(group, 3) if len(group) > 1 else group[0]
                body = mkv.element(0xA1, payload)
                if amount:
                    value = (abs(amount) * 1000000000 + track['rate'] // 2) // track['rate']
                    body += mkv.sint(0x75A2, -value if amount < 0 else value)
                    removed.append((raw, raw - amount) if amount < 0 else (raw + count - amount, raw + count))
                blocks.append(mkv.element(0x1F43B675,mkv.uint(0xE7,cluster)+mkv.element(0xA0, body),padded))
                if first<end:presented+=end-first
                raw += count
            head = (6500000 * track['rate'] + 500000000) // 1000000000 if padded else int.from_bytes(track['private'][10:12], 'little') if track['codec'] == 'A_OPUS' else 0
            visibility = bytearray(b'\1' * raw)
            visibility[:head] = bytes(head)
            for a, b in removed:
                visibility[a:b] = bytes(b - a)
            visible = [i for i, included in enumerate(visibility) if included]
            data = mkv.element(0x1A45DFA3, mkv.element(0x4282, b'matroska')) + mkv.element(0x18538067, mkv.element(0x1549A966,mkv.uint(0x2AD7B1,1000))+mkv.element(0x1654AE6B, other + mkv.element(0xAE, entry)) + b''.join(blocks), padded)
            return data, visible

        sources = []
        for rate in [8000, 11025, 44100, 48000, 96000, 192000]:
            lengths = [1] * 128
            while sum(lengths) < rate * 1.2:
                lengths.extend([97, 257, 31, 127, 511, 13])
            frames, raw, sample = [], bytearray(), 0
            for count in lengths:
                packet = bytearray()
                for _ in range(count):
                    a, b = sample * 91 % 60001 - 30000, (sample * 157 + 47) % 56001 - 28000
                    packet += struct.pack('<hh', a, b)
                    raw += struct.pack('<ff', a / 32768, b / 32768)
                    sample += 1
                frames.append(bytes(packet))
            track = {'codec': 'A_PCM/INT/LIT', 'private': None, 'audio': mkv.element(0xB5, struct.pack('>d', float(rate))) + mkv.uint(0x9F, 2) + mkv.uint(0x6264, 16), 'frames': frames, 'discard': 0, 'rate': rate}
            sources.append((f'pcm-{rate}', track, lengths, bytes(raw)))
        for label, encoder, rate in [('flac', 'flac', 48000), ('opus', 'libopus', 48000), ('mp2', 'mp2', 48000), ('mp3', 'libmp3lame', 48000), ('aac', 'aac', 48000), ('alac', 'alac', 48000), ('speex', 'libspeex', 16000), ('vorbis', 'libvorbis', 48000)]:
            path = work / (label + '-encoder.mka')
            run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s={rate}:d=1.2', '-c:a', encoder, path])
            track = mkv.parse(path)
            track.update(rate=rate, discard=0)
            track.pop('codec_delay', None)
            clean = dict(track)
            if label == 'opus':
                private = bytearray(track['private']);private[10:12] = b'\0\0';clean['private'] = bytes(private)
            base = work / (label + '-clean.mka');base.write_bytes(mkv.mux(clean));raw = decode(base)
            if label == 'opus':
                def samples(packet):
                    config, code = packet[0] >> 3, packet[0] & 3
                    per = (480, 960, 1920, 2880)[config & 3] if config < 12 else (480 << (config & 1)) if config < 16 else 120 << (config & 3)
                    return per * (1 if code == 0 else packet[1] & 63 if code == 3 else 2)
                lengths = [samples(packet) for packet in track['frames']]
            elif label in ['mp2', 'mp3', 'aac', 'speex']:
                lengths = [{'mp2': 1152, 'mp3': 1152, 'aac': 1024, 'speex': 320}[label]] * len(track['frames'])
            else:
                prefix = dict(clean)
                if label == 'flac':
                    private = bytearray(clean['private']);private[21] &= 0xf0;private[22:26] = bytes(4);prefix['private'] = bytes(private)
                lengths, before = [], 0
                for n in range(1, len(track['frames']) + 1):
                    prefix['frames'] = track['frames'][:n];base.write_bytes(mkv.mux(prefix));count = len(decode(base)) // 8
                    lengths.append(count - before);before = count
            assert sum(lengths) * 8 == len(raw), label
            sources.append((label, track, lengths, raw))
        save('control.mka', make(sources[0][1], sources[0][2])[0])
        suffix_pcm = {}
        for label, track, lengths, raw in sources:
            starts, at = [], 0
            for n in lengths:
                starts.append(at);at += n
            patterns = [('absent', None, False), *[(str(ns), ns, False) for ns in [0, 1, 79999999, 80000000, 80000001, 125000001, 250000001, (1 << 64) - 1]], ('padded-laced', 250000001, True)]
            if label == 'pcm-8000':
                patterns += [(str(ns), ns, False) for ns in [124999, 125000, 125001]]
            for kind, ns, padded in patterns:
                # Two late cases check selected ordinals and field ordering.
                extra = label == 'pcm-8000' and kind in ['0', '250000001']
                data, visible = make(track, lengths, ns, padded, extra=extra, early=kind == '250000001')
                frame_count = len(visible);name = label + '-' + kind + '.mka';reference = name + '.f32';model = name + '.model'
                save(name, data);save(reference, b''.join(raw[i * 8:i * 8 + 8] for i in visible))
                targets = [(1 << 64) - 1, 0, 1, 127, 128, 511, 4095, 4096, frame_count // 3, frame_count // 2 + 1, frame_count - 1, frame_count, (1 << 64) - 1, 0, frame_count // 2]
                blob = bytearray(struct.pack('<QIII', ns or 0, track['rate'], 2, len(targets)))
                restarts = []
                for request in targets:
                    target = min(request, frame_count);raw_target = visible[target] if target < frame_count else at
                    history = ((ns or 0) * track['rate'] + 999999999) // 1000000000
                    chosen = max(0, bisect_right(starts, max(0, raw_target - history)) - 1)
                    if label == 'opus':
                        chosen = min(chosen, max(0, bisect_right(starts, max(0, raw_target - 3840)) - 1))
                    decode_start = chosen
                    if label in ['aac', 'vorbis']:
                        decode_start = max(0, chosen - 1)
                    elif label in ['mp2', 'mp3']:
                        chosen = max(0, chosen - 2)
                        if label == 'mp3':
                            total = 0
                            while chosen and total < 2048:
                                chosen -= 1;total += len(track['frames'][chosen])
                        decode_start = chosen
                    if label == 'speex' or request == 0:
                        chosen = decode_start = 0
                    resume = bisect_right(visible, starts[chosen] - 1)
                    wanted = min(4096, frame_count - target)
                    if label in ['opus', 'aac'] and decode_start:
                        key = (label, decode_start)
                        if key not in suffix_pcm:
                            suffix = dict(track, frames=track['frames'][decode_start:])
                            if label == 'opus':
                                private = bytearray(suffix['private']);private[10:12] = b'\0\0';suffix['private'] = bytes(private)
                            path = work / 'suffix.mka';path.write_bytes(mkv.mux(suffix));suffix_pcm[key] = decode(path)
                        comparator = suffix_pcm[key];offset = starts[decode_start]
                    else:
                        comparator = raw;offset = 0
                    expected = b''.join(comparator[(p - offset) * 8:(p - offset + 1) * 8] for p in visible[target:target + wanted])
                    assert len(expected) == wanted * 8
                    blob += struct.pack('<QQQI', request, resume, target, wanted) + expected
                    restarts.append({'request': request, 'target': target, 'resume': resume, 'decoded_from_packet': decode_start, 'minimum_history_samples': history})
                save(model, blob)
                manifest['cases'].append({'file': name, 'reference': reference, 'model': model, 'rate': track['rate'], 'ns': ns, 'padded_laced': padded, 'track_choice': 2 if extra and kind == '250000001' else 0, 'frames': frame_count, 'restarts': restarts})
        track, lengths = sources[0][1:3]
        for name, options in [('long', {'raw_element': mkv.element(0x56BB, bytes(9))}), ('duplicate', {'ns': 0, 'duplicate': True})]:
            filename = 'bad-' + name + '.mka';save(filename, make(track, lengths, **options)[0]);manifest['bad'].append(filename)
        data, _ = make(track, lengths, raw_element=mkv.element(0x56BB, b''));save('zero-length.mka', data)
        manifest['zero_length'] = 'zero-length.mka'
        path = work / 'lifecycle-encoder.mka'
        run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'aevalsrc=0.2*sin(2*PI*317*t)|0.13*sin(2*PI*733*t):s=48000:d=24', '-c:a', 'libopus', path])
        track = mkv.parse(path);track.update(rate=48000, discard=0)
        save('lifecycle.mka', make(track, [samples(packet) for packet in track['frames']], 250000001, padded=True)[0])
    (work / 'fixtures.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    shared = {p.stem for p in (ROOT / 'src').glob('*.s')} | {'platform', 'linux_platform'}
    objects = [p for p in sorted((out / 'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared]
    libraries = list((out / 'obj').glob('*.lib')) if WINDOWS else ['-no-pie', '-Wl,-z,noexecstack']
    oracle, chain, guard = [out / ('matroska-preroll-' + name + extension) for name in ['oracle', 'chain', 'guard']]
    for target, source in [(oracle, 'matroska-preroll-oracle.c'), (chain, 'chain-oracle.c'), (guard, 'speex-matroska-oracle.c')]:
        compile_c(target, [ROOT / 'tests' / source], objects=objects, libraries=libraries)
    checks = []
    for case in manifest['cases']:
        if args.case and not case['file'].startswith(args.case):
            continue
        detail = json.loads(run([oracle, work / case['file'], work / case['reference'], work / case['model'], case['track_choice'], work / 'control.mka']).strip().splitlines()[-1])
        checks.append({**case, 'result': 'exact modeled restart and PCM', 'oracle': detail, 'fixture_sha256': hashlib.sha256((work / case['file']).read_bytes()).hexdigest()})
        print(case['file'] + ': exact restart, PCM, repeated rewind and cancellation', flush=True)
    bounds = []
    if not args.case:
        for name in ['pcm-8000-18446744073709551615.mka', 'pcm-8000-250000001.mka', 'opus-padded-laced.mka']:
            case = next(c for c in manifest['cases'] if c['file'] == name)
            detail = json.loads(run([guard, work / name, work / case['reference'], case['rate'], 2, case['track_choice'], int(name.startswith('pcm-8000-184'))]).strip().splitlines()[-1])
            bounds.append({'file': name, **detail})
    rejected = [] if args.case else [{'file': name, **json.loads(run([chain, 'reject', work / name]).strip().splitlines()[-1])} for name in manifest['bad']]
    if not args.case:
        assert decode(work / manifest['zero_length']) == decode(work / 'control.mka')
    lifecycle = []
    if args.probe:
        if not WINDOWS or args.case:
            raise RuntimeError('Full native Windows suite required')
        probe = out / 'engine-probe.exe'
        assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
        detail = run([probe, work / 'lifecycle.mka'], timeout=75)
        assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail
        lifecycle.append({'file': 'lifecycle.mka', 'details': detail.splitlines(), 'probe_sha256': hashlib.sha256(probe.read_bytes()).hexdigest()})
    sources = ['src/mkv.s', 'src/track.s', 'src/track_cuts.s', 'src/track_time.s', 'src/aac.s', 'src/vorbis.s', 'src/vorbis_decode.inc', 'tests/track-source-oracle.c', 'tests/matroska-preroll-oracle.c', 'tests/speex-matroska-oracle.c', 'tests/verify-matroska-preroll.py', 'tests/verify-matroska.py']
    report = {'result': 'passed', 'platform': platform.platform(), 'ffmpeg': manifest['ffmpeg'], 'scope': 'Selected-track SeekPreRoll with coherent compressed-presentation clocks, ceil conversion, codec history minima, coded/presented mapping through delay and signed laced padding, independent source/suffix PCM for Opus/AAC, repeated zero rewinds, malformed metadata, ignored unselected values, cancellation and clear/reopen. Mutation reads are capped at128, with a midpoint seek at64; damaged PCM correctness and A/V synchronization are not established.', 'checks': checks, 'guarded': bounds, 'rejections': rejected, 'zero_length_unsigned': 'accepted as zero' if not args.case else 'not run', 'native_lifecycle': lifecycle, 'sources': {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources}, 'binaries': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [cli, oracle, chain, guard,source_oracle]}}
    (out / ('matroska-preroll-debug.json' if args.case else 'matroska-preroll-verification.json')).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('Passed', len(checks), 'files and', sum(c['oracle']['seeks'] for c in checks), 'modeled seeks.')


if __name__ == '__main__':
    main()
