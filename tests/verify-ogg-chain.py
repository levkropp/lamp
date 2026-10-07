#!/usr/bin/env python3
"""Chained and multiplexed Ogg, FLAC-in-Ogg, and rate changes between links.

usage: python3 tests/verify-ogg-chain.py
Chains are byte concatenations of independently encoded links. The reference
for a chain is each link's own --decode output, passed through the assembly
resampler (checked by verify-resample.py) when the link's rate differs from
the first link's; the chained decode must match it exactly, continuously and
after seeks to every link boundary and inside every link. Seeks inside Opus
links use pre-roll, so they must equal a seek in the standalone link.
Multiplexed links must play their first Vorbis/Opus/FLAC stream, identical to
that stream alone. FLAC-in-Ogg must equal FFmpeg's lossless decode, or LAMP's
native decode of the same frames for multichannel downmixes. Malformed
chains and mappings must be rejected; cancellation must stop cleanly.
Writes <out>/ogg-chain-verification.json.
"""
import array
from pathlib import Path
import shutil
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, lamp_cli, main_guard, out_dir,
                       run, scratch, check_file, write_report)


def crc_table():
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04c11db7) & 0xffffffff if c & 0x80000000 else (c << 1) & 0xffffffff
        table.append(c)
    return table


CRC = crc_table()


def ogg_crc(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xffffffff) ^ CRC[((c >> 24) ^ b) & 0xff]
    return c


def pages(data):
    """Splits an Ogg file into page byte strings."""
    out, i = [], 0
    while i < len(data):
        n = data[i + 26]
        size = 27 + n + sum(data[i + 27:i + 27 + n])
        out.append(bytearray(data[i:i + size]))
        i += size
    return out


def seal(page):
    page[22:26] = b'\0\0\0\0'
    page[22:26] = struct.pack('<I', ogg_crc(page))
    return page


def packets(data):
    """(serial, packet, granule-of-page-if-last-on-page) for every packet."""
    out, partial = [], b''
    for page in pages(data):
        n = page[26]
        laces = page[27:27 + n]
        offset = 27 + n
        serial = struct.unpack_from('<I', page, 14)[0]
        granule = struct.unpack_from('<q', page, 6)[0]
        for j, lace in enumerate(laces):
            partial += bytes(page[offset:offset + lace])
            offset += lace
            if lace < 255:
                out.append([serial, partial, granule if j == n - 1 else None])
                partial = b''
    return out


def build(serial, items, bos_packets=1):
    """Writes each (packet, granule) on its own page; the first bos_packets are headers."""
    out = []
    for sequence, (packet, granule) in enumerate(items):
        laces = [255] * (len(packet) // 255) + [len(packet) % 255]
        flags = 2 if sequence == 0 else 0
        if sequence == len(items) - 1:
            flags |= 4
        header = bytearray(b'OggS\0' + bytes([flags]) + struct.pack('<qIII', granule, serial, sequence, 0) +
                           bytes([len(laces)]) + bytes(laces))
        out.append(bytes(seal(header + packet)))
    return b''.join(out)


def flac_block_size(packet):
    code = packet[2] >> 4
    lead = packet[4]
    width = 1 if lead < 0x80 else 8 - (lead ^ 0xff).bit_length()
    after = 4 + width
    if code == 1:
        return 192
    if 2 <= code <= 5:
        return 576 << (code - 2)
    if code == 6:
        return packet[after] + 1
    if code == 7:
        return (packet[after] << 8 | packet[after + 1]) + 1
    if code >= 8:
        return 256 << (code - 8)
    raise Failure('Reserved FLAC block size in fixture')


def flac_items(data):
    """FLAC-in-Ogg packets with exact end-sample granules, one packet per page."""
    items = [(p[1], 0) for p in packets(data)]
    if items and not items[-1][0]:
        items.pop()                       # FFmpeg's optional empty EOS marker
    position = 0
    for k in range(2, len(items)):
        position += flac_block_size(items[k][0])
        items[k] = (items[k][0], position)
    return items


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'chain-oracle': 'chain-oracle.c', 'resample-oracle': 'resample-oracle.c'}, library)
    chain, resampler = exe('chain-oracle'), exe('resample-oracle')
    work = scratch('ogg-chain')
    shutil.rmtree(work)
    work.mkdir(parents=True)
    checks = []

    def encode(name, source, *coding, rate=48000, channels=2, layout=None):
        path = work / name
        if not path.exists():
            args = ['-f', 'lavfi', '-i', source]
            if layout:
                args += ['-af', f'aformat=channel_layouts={layout}']
            else:
                args += ['-ac', str(channels)]
            ffmpeg(*args, '-ar', str(rate), *coding, path)
        return path

    def pcm(path):
        target = Path(str(path) + '.f32')
        if not target.exists():
            decode_f32(path, target)
        return target.read_bytes()

    def resampled(link, rate_in, rate_out):
        target = Path(f'{link}.{rate_out}.f32')
        line = run([resampler, str(rate_in), str(rate_out), Path(str(link) + '.f32'), target])
        return target.read_bytes()

    def rate_of(path):
        code, stats = check_file(path)
        if code:
            raise Failure(f'Fixture link does not decode: {path} {stats}')
        return int(stats.split(' rate=')[1].split()[0])

    def verify_chain(name, links, multiplexed_references=None):
        """links: files concatenated in order. Reference = each link's PCM at the first link's rate."""
        path = work / name
        path.write_bytes(b''.join(Path(link).read_bytes() for link in links))
        rates = [rate_of(link) for link in links]
        parts = []
        for k, link in enumerate(links):
            source = multiplexed_references[k] if multiplexed_references else link
            data = pcm(source)
            if rates[k] != rates[0]:
                data = resampled(source, rates[k], rates[0])
            parts.append(data)
        reference = work / (name + '.reference.f32')
        reference.write_bytes(b''.join(parts))
        ours = work / (name + '.f32')
        if ours.exists():
            ours.unlink()
        decode_f32(path, ours)
        if ours.read_bytes() != reference.read_bytes():
            raise Failure(f'Chained decode differs from its links: {name}')
        line = run([chain, 'check', path, reference]).strip().splitlines()[-1]
        # Opus links: a chain seek must equal a seek in the standalone link.
        starts, total = [], 0
        for part in parts:
            starts.append(total)
            total += len(part) // 8
        dumps = 0
        for k, link in enumerate(links):
            standalone = multiplexed_references[k] if multiplexed_references else link
            if Path(standalone).suffix != '.opus' or rates[k] != rates[0]:
                continue
            length = len(parts[k]) // 8
            for rel in (length // 3, length // 2 + 101, length - 1000):
                if rel <= 0:
                    continue
                a, b = work / 'dump-chain.f32', work / 'dump-link.f32'
                count = str(min(2000, length - rel))           # stay inside the link
                run([chain, 'dump', path, str(starts[k] + rel), count, a])
                run([chain, 'dump', standalone, str(rel), count, b])
                if a.read_bytes() != b.read_bytes():
                    raise Failure(f'Seek into Opus link {k} of {name} differs from the standalone link')
                dumps += 1
        checks.append({'test': name, 'result': 'passed', 'links': len(links), 'rates': rates,
                       'oracle': line, 'opus_seek_dumps': dumps})
        print(f'{name}: {line}', flush=True)
        return path

    noise = lambda seed, rate=48000, d=1.1: f'anoisesrc=r={rate}:d={d}:a=0.25:seed={seed}'
    tone = lambda f, rate=48000, d=0.9: f'sine=frequency={f}:sample_rate={rate}:duration={d}'
    vorbis_a = encode('va.ogg', noise(1), '-c:a', 'libvorbis', '-q:a', '5')
    vorbis_b = encode('vb.ogg', tone(660), '-c:a', 'libvorbis', channels=1)
    vorbis_c = encode('vc.ogg', noise(3, d=0.8), '-c:a', 'libvorbis', layout='5.1')
    opus_a = encode('oa.opus', noise(4, d=0.7), '-c:a', 'libopus', '-b:a', '96k')
    opus_c = encode('oc.opus', noise(5, d=0.6), '-c:a', 'libopus', '-mapping_family', '1', '-b:a', '256k', layout='5.1')
    flac_a = encode('fa.oga', noise(6, d=0.75), '-c:a', 'flac')
    vorbis_44 = encode('v44.ogg', noise(7, 44100), '-c:a', 'libvorbis', rate=44100)
    vorbis_22 = encode('v22.ogg', tone(440, 22050), '-c:a', 'libvorbis', rate=22050, channels=1)
    flac_96 = encode('f96.oga', noise(8, 96000, 0.6), '-c:a', 'flac', '-sample_fmt', 's32', rate=96000)
    vorbis_32 = encode('v32.ogg', noise(9, 32000, 0.5), '-c:a', 'libvorbis', rate=32000)

    verify_chain('vorbis-chain.ogg', [vorbis_a, vorbis_b, vorbis_c])
    verify_chain('same-serial-chain.ogg', [vorbis_a, vorbis_a])
    verify_chain('mixed-codec-chain.ogg', [vorbis_a, opus_a, flac_a, opus_c, vorbis_b])
    verify_chain('opus-first-chain.ogg', [opus_a, vorbis_a, flac_96])
    verify_chain('rate-change-chain.ogg', [vorbis_44, vorbis_a, flac_96, opus_a, vorbis_22, vorbis_32])
    # Many short links exercise the link table and the seek search.
    small = []
    for k in range(48):
        small.append(encode(f'small-{k}.oga', tone(200 + 37 * k, 48000, 0.05 + 0.01 * (k % 5)), '-c:a', 'flac'))
    verify_chain('many-links.ogg', small)

    # Multiplexed links: the first supported stream plays.
    def mux(name, *inputs):
        path = work / name
        args = []
        for item in inputs:
            args += ['-i', item]
        for k in range(len(inputs)):
            args += ['-map', str(k)]
        ffmpeg(*args, '-c', 'copy', path)
        return path
    speex = encode('sp.spx.ogg', noise(10, 16000, 0.7), '-c:a', 'libspeex', rate=16000, channels=1)
    opus_vorbis = mux('mux-opus-vorbis.ogg', opus_a, vorbis_b)
    speex_vorbis = mux('mux-speex-vorbis.ogg', speex, vorbis_a)
    vorbis_flac = mux('mux-vorbis-flac.ogg', vorbis_b, flac_a)
    video = work / 'video.ogv'
    ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=96x64:rate=12:duration=1.2', '-i', vorbis_a, '-map', '0', '-map', '1',
           '-c:v', 'libtheora', '-c:a', 'copy', video)
    verify_chain('mux-chain.ogg', [opus_vorbis, speex_vorbis, vorbis_flac, video],
                 multiplexed_references=[opus_a, vorbis_a, vorbis_b, vorbis_a])

    # FLAC-in-Ogg against FFmpeg, and against the same frames in native FLAC.
    flac_cases = [('flac-16-44100-2.oga', noise(11, 44100, 0.8), ['-c:a', 'flac'], 44100, 2, None),
                  ('flac-24-96000-2.oga', noise(12, 96000, 0.4), ['-c:a', 'flac', '-sample_fmt', 's32'], 96000, 2, None),
                  ('flac-16-8000-1.oga', tone(300, 8000, 1.0), ['-c:a', 'flac'], 8000, 1, None),
                  ('flac-16-192000-2.oga', noise(13, 192000, 0.3), ['-c:a', 'flac', '-frame_size', '1152'], 192000, 2, None),
                  ('flac-16-48000-2-small.oga', noise(14, 48000, 0.3), ['-c:a', 'flac', '-frame_size', '256',
                                                                      '-compression_level', '12'], 48000, 2, None),
                  ('flac-24-48000-5.1.oga', noise(15, 48000, 0.4), ['-c:a', 'flac', '-sample_fmt', 's32'], 48000, 6, '5.1'),
                  ('flac-16-48000-7.1.oga', noise(16, 48000, 0.4), ['-c:a', 'flac'], 48000, 8, '7.1'),
                  ('flac-16-48000-3.oga', noise(17, 48000, 0.4), ['-c:a', 'flac'], 48000, 3, None)]
    for name, source, coding, rate, channels, layout in flac_cases:
        path = encode(name, source, *coding, rate=rate, channels=channels, layout=layout)
        ours = pcm(path)
        if channels <= 2:
            reference = work / (name + '.ffmpeg.f32')
            upmix = ['-af', 'pan=stereo|c0=c0|c1=c0'] if channels == 1 else ['-ac', '2']
            ffmpeg('-i', path, *upmix, '-f', 'f32le', reference)
            if ours != reference.read_bytes():
                raise Failure(f'FLAC-in-Ogg differs from FFmpeg: {name}')
            comparator = 'FFmpeg lossless decode'
        else:
            native = work / (name + '.flac')
            ffmpeg('-i', path, '-c', 'copy', native)
            if ours != pcm(native):
                raise Failure(f'FLAC-in-Ogg differs from native FLAC with the same frames: {name}')
            comparator = 'native FLAC with identical frames'
        line = run([chain, 'check', path, Path(str(path) + '.f32')]).strip().splitlines()[-1]
        checks.append({'test': name, 'result': 'exact', 'comparator': comparator, 'frames': len(ours) // 8,
                       'oracle': line})
        print(f'{name}: exact against {comparator}; {line}', flush=True)

    # Malformed chains and mappings.
    base = flac_a.read_bytes()
    rejections = []

    def reject(name, data):
        path = work / name
        path.write_bytes(data)
        line = run([chain, 'reject', path]).strip().splitlines()[-1]
        rejections.append(name)
        checks.append({'test': name, 'result': 'rejected', 'oracle': line})

    two = vorbis_a.read_bytes() + vorbis_b.read_bytes()
    reject('chain-junk-between.ogg', vorbis_a.read_bytes() + b'junk' + vorbis_b.read_bytes())
    reject('chain-truncated-link.ogg', two[:len(two) - 300])
    corrupt = bytearray(two)
    corrupt[len(vorbis_a.read_bytes()) + 200] ^= 0x40
    reject('chain-second-link-crc.ogg', bytes(corrupt))
    reject('chain-unsupported-link.ogg', vorbis_a.read_bytes() + speex.read_bytes())
    reject('chain-unsupported-only.ogg', speex.read_bytes())
    first = pages(vorbis_b.read_bytes())
    reject('chain-missing-bos.ogg', vorbis_a.read_bytes() + b''.join(bytes(p) for p in first[1:]))
    reject('chain-after-eos.ogg', vorbis_a.read_bytes() + bytes(pages(vorbis_a.read_bytes())[-1]))
    serial = struct.unpack_from('<I', base, 14)[0]
    items = flac_items(base)

    def flac_variant(name, edit):
        changed = [list(item) for item in items]
        edit(changed)
        reject(name, build(serial, [tuple(item) for item in changed]))

    def set_byte(k, offset, value):
        return lambda c: c[k].__setitem__(0, c[k][0][:offset] + bytes([value]) + c[k][0][offset + 1:])
    flac_variant('flac-ogg-mapping-version.ogg', set_byte(0, 5, 2))
    flac_variant('flac-ogg-header-count.ogg', set_byte(0, 8, 3))
    flac_variant('flac-ogg-no-fLaC.ogg', set_byte(0, 9, ord('x')))
    flac_variant('flac-ogg-streaminfo-type.ogg', set_byte(0, 13, 1))
    flac_variant('flac-ogg-second-streaminfo.ogg', set_byte(1, 0, 0))
    flac_variant('flac-ogg-two-frames.ogg', lambda c: (c[2].__setitem__(0, c[2][0] + c[3][0]),
                                                       c[2].__setitem__(1, c[3][1]), c.pop(3)))
    flac_variant('flac-ogg-missing-frame.ogg', lambda c: c.pop(4))
    flac_variant('flac-ogg-frame-crc.ogg', set_byte(3, 40, items[3][0][40] ^ 1))
    flac_variant('flac-ogg-empty-packet.ogg', lambda c: c.insert(3, [b'', c[2][1]]))
    print(f'Rejected {len(rejections)} malformed chains/mappings', flush=True)

    # The valid rebuild itself must pass, so the rejections test only their edits.
    rebuilt = work / 'flac-ogg-rebuilt.ogg'
    rebuilt.write_bytes(build(serial, items))
    if pcm(rebuilt) != pcm(flac_a):
        raise Failure('Rebuilt FLAC-in-Ogg fixture differs')
    terminated = work / 'flac-ogg-empty-eos.ogg'
    terminated.write_bytes(build(serial, items + [(b'', items[-1][1])]))
    if pcm(terminated) != pcm(flac_a):
        raise Failure('Empty FLAC EOS marker changes the decoded samples')
    result = run([chain, 'check', terminated, Path(str(terminated) + '.f32')])
    checks.append({'test': 'FLAC empty EOS', 'result': 'exact PCM and seeks', 'oracle': result})
    reject('flac-ogg-empty-eos-wrong-granule.ogg', build(serial, items + [(b'', items[-1][1] + 1)]))
    # Frame headers, not granules, place FLAC samples: rounded granules from a
    # remux must not change the output.
    shifted = [list(item) for item in items]
    for item in shifted[2:]:
        item[1] = max(0, item[1] - 20)
    rounded = work / 'flac-ogg-rounded-granules.ogg'
    rounded.write_bytes(build(serial, [tuple(item) for item in shifted]))
    if pcm(rounded) != pcm(flac_a):
        raise Failure('FLAC-in-Ogg with rounded granules decodes differently')
    checks.append({'test': rounded.name, 'result': 'exact'})

    for mode in ('cancel-open', 'cancel-read'):
        line = run([chain, mode, work / 'rate-change-chain.ogg']).strip().splitlines()[-1]
        checks.append({'test': f'{mode} rate-change-chain.ogg', 'result': 'cancelled', 'oracle': line})
    print('Cancelled open and read stop cleanly', flush=True)

    write_report('ogg-chain', {'result': 'passed', 'checks': checks, 'rejections': len(rejections),
                               'scope': 'Chained Ogg links of Vorbis, Opus and FLAC, including rate changes resampled to the first link, same-serial chains and 48 links; multiplexed links with Opus, Vorbis, FLAC, Speex and Theora streams; exact continuous and seek PCM against the links\' own decodes; Opus-link seeks equal standalone seeks; FLAC-in-Ogg exact against FFmpeg or native FLAC; malformed chains/mappings and cancellation.'})
    print(f'Passed {len(checks)} Ogg chain checks.')


if __name__ == '__main__':
    main_guard(main)
