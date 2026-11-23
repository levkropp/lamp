"""Original test-only ISO BMFF layouts and rational timestamp expectations.

Model payloads are opaque bytes, never submitted to hardware. Encoded inputs
are generated separately by FFmpeg in the verification driver.
"""
from fractions import Fraction
import itertools
import random
import struct

NS = 10**9
I64_MAX = 2**63 - 1
CONFIG = bytes.fromhex('0142001effe10002674201000268ce')


def be(*values):
    return b''.join(struct.pack('>I', x) for x in values)


def box(kind, body=b'', large=False, rest=False):
    kind = kind.encode('ascii')
    if rest:
        return be(0) + kind + body
    if large:
        return be(1) + kind + struct.pack('>Q', len(body) + 16) + body
    return be(len(body) + 8) + kind + body


def full(kind, body=b'', version=0, flags=0):
    return box(kind, be((version << 24) | flags) + body)


def runs(values):
    return [(len(list(group)), value) for value, group in itertools.groupby(values)]


def headers(stbl, *, media_scale=1000, movie_scale=1000, version=0,
            edits=None, edit_version=0, enabled=True, track_id=1, codec='avc1',
            dataref=1, external=False, config=CONFIG, extra_tracks=b'', mvex=b''):
    # Full standard-size fixed headers. No encoder or implementation metadata
    # are used to calculate the independent timestamp expectations.
    matrix = be(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    clocks = struct.pack('>QQIQ', 0, 0, movie_scale, 0) if version else be(0, 0, movie_scale, 0)
    mvhd = full('mvhd', clocks + be(0x10000) + struct.pack('>H', 0x100) + bytes(10) + matrix + bytes(24) + be(2), version)
    track = struct.pack('>QQIIQ', 0, 0, track_id, 0, 0) if version else be(0, 0, track_id, 0, 0)
    tkhd = full('tkhd', track + bytes(16) + matrix + be(64 << 16, 64 << 16), version, 3 if enabled else 2)
    clocks = struct.pack('>QQIQ', 0, 0, media_scale, 0) if version else be(0, 0, media_scale, 0)
    mdhd = full('mdhd', clocks + bytes(4), version)
    hdlr = full('hdlr', be(0) + b'vide' + bytes(12) + b'Model\0')
    visual = bytes(6) + struct.pack('>H', dataref) + bytes(16) + struct.pack('>HH', 64, 64) + be(0x480000, 0x480000, 0) + struct.pack('>H', 1) + bytes(32) + struct.pack('>Hh', 24, -1)
    assert len(visual) == 78
    stsd = full('stsd', be(1) + box(codec, visual + box('avcC', config)))
    dref = full('dref', be(1) + full('url ', b'elsewhere\0' if external else b'', flags=0 if external else 1))
    minf = box('minf', box('dinf', dref) + box('stbl', stsd + stbl))
    edts = b''
    if edits is not None:
        entries = b''.join(struct.pack('>Qqh', duration, start, rate) + bytes(2) if edit_version else struct.pack('>Iih', duration, start, rate) + bytes(2) for duration, start, rate in edits)
        edts = box('edts', full('elst', be(len(edits)) + entries, edit_version))
    return box('moov', mvhd + box('trak', tkhd + edts + box('mdia', mdhd + hdlr + minf)) + extra_tracks + mvex)


def expected_packets(offsets, sizes, dts, deltas, cto, *, media_scale=1000,
                     movie_scale=1000, edits=None, sync=None):
    gap, start, end = 0, 0, I64_MAX
    if edits:
        active = [(duration, where) for duration, where, rate in edits if where != -1]
        gap = sum(duration for duration, where, rate in edits if where == -1)
        if active:
            duration, start = active[0]
            if duration:
                end = (gap + duration) * NS // movie_scale
        else:
            end = gap * NS // movie_scale
    origin = Fraction(gap, movie_scale) - Fraction(start, media_scale)
    stamp = lambda units: (Fraction(units, media_scale) + origin) * NS // 1
    pts = [int(stamp(a + b)) for a, b in zip(dts, cto)]
    decode = [int(stamp(a)) for a in dts]
    durations = [int(stamp(a + b)) - int(stamp(a)) for a, b in zip(dts, deltas)]
    display = list(durations)
    order = sorted(range(len(pts)), key=lambda i: (pts[i], i))
    for a, b in zip(order, order[1:]):
        display[a] = pts[b] - pts[a]
    result = []
    for i, size in enumerate(sizes):
        flags = (1 if sync is None or i + 1 in sync else 0) if size else 8
        if durations[i] == 0:
            flags |= 4
        show_pts = max(pts[i], gap * NS // movie_scale)
        show_duration = max(0, min(pts[i] + display[i], end) - show_pts) if size else 0
        if not show_duration:
            flags |= 2
        result.append(dict(index=i, offset=offsets[i], size=size, dts_ns=decode[i],
                           pts_ns=pts[i], decode_duration_ns=max(1, durations[i]),
                           flags=flags, show_pts_ns=show_pts,
                           show_duration_ns=show_duration, display_duration_ns=display[i]))
    return result


def classic(*, sizes=(3, 5, 7, 1, 2), deltas=None, cto=None, ctts_version=1,
            compact=0, constant=False, co64=False, chunks=None, mdats=1,
            faststart=False, large=False, rest=False, sync=None, **kw):
    expect = kw.pop('expect', True)
    sizes = list(sizes)
    deltas = list(deltas if deltas is not None else [40] * len(sizes))
    cto = list(cto if cto is not None else [0] * len(sizes))
    assert len(sizes) == len(deltas) == len(cto)
    chunks = list(chunks if chunks is not None else ([len(sizes)] if sizes else []))
    assert sum(chunks) == len(sizes) and all(chunks)
    ftyp = box('ftyp', b'isom' + be(0x200) + b'isomiso2avc1mp41')
    chunk_payloads, first = [], 0
    for n in chunks:
        chunk_payloads.append(b''.join(bytes([i % 251 + 1]) * sizes[i] for i in range(first, first+n)))
        first += n
    groups = [list(range(i, len(chunks), mdats)) for i in range(mdats)]

    def tables(offsets):
        if compact:
            if compact == 4:
                data = bytes((sizes[i] << 4) | (sizes[i+1] if i+1 < len(sizes) else 0) for i in range(0, len(sizes), 2))
            elif compact == 8:
                data = bytes(sizes)
            else:
                data = b''.join(struct.pack('>H', n) for n in sizes)
            sz = full('stz2', be(compact, len(sizes)) + data)
        else:
            sz = full('stsz', be(sizes[0] if constant and sizes else 0, len(sizes)) + (b'' if constant else be(*sizes)))
        entries = [(i+1, n, 1) for i, n in enumerate(chunks) if i == 0 or n != chunks[i-1]]
        sc = full('stsc', be(len(entries)) + b''.join(be(*v) for v in entries))
        offsets_table = b''.join(struct.pack('>Q' if co64 else '>I', n) for n in offsets)
        co = full('co64' if co64 else 'stco', be(len(offsets)) + offsets_table)
        ts = full('stts', be(len(runs(deltas))) + b''.join(be(n, v) for n, v in runs(deltas)))
        ct = full('ctts', be(len(runs(cto))) + b''.join(be(n, v & 0xffffffff) for n, v in runs(cto)), ctts_version)
        ss = b'' if sync is None else full('stss', be(len(sync), *sync))
        return sz + sc + co + ts + ct + ss

    def movie(offsets):
        return headers(tables(offsets), **kw)

    placeholder = movie([0] * len(chunks))
    base = len(ftyp) + (len(placeholder) if faststart else 0)
    offsets = [0] * len(chunks)
    media = b''
    for g, group in enumerate(groups):
        cursor = base + len(media) + (16 if large else 8)
        for index in group:
            offsets[index] = cursor
            cursor += len(chunk_payloads[index])
        media += box('mdat', b''.join(chunk_payloads[i] for i in group), large=large, rest=rest and g+1 == len(groups))
    moov = movie(offsets)
    data = ftyp + (moov + media if faststart else media + moov)
    sample_offsets, i = [], 0
    for offset, n in zip(offsets, chunks):
        for _ in range(n):
            sample_offsets.append(offset)
            offset += sizes[i]
            i += 1
    dts, clock = [], 0
    for delta in deltas:
        dts.append(clock)
        clock += delta
    times = {key: kw[key] for key in ('media_scale', 'movie_scale', 'edits') if key in kw}
    expected = expected_packets(sample_offsets, sizes, dts, deltas, cto, sync=sync, **times) if expect else None
    return data, expected


def fragmented(*, start=0, scale=1000, sizes=(3, 5, 7), deltas=(40, 40, 40),
               cto=(0, 80, -40), cto_version=1, base='moof', tfdt=True,
               per_sample=True, tfdt_version=1, edits=None, movie_scale=1000,
               first_flags=False):
    # Empty classic initialization followed by one fragment. Encoded multi-traf
    # interleaving is tested separately; this model isolates address/clock bounds.
    init, _ = classic(sizes=(), media_scale=scale, movie_scale=movie_scale, edits=edits,
                      mvex=box('mvex', full('trex', be(1, 1, deltas[0], sizes[0], 0))))
    flags = 0x020000 if base == 'moof' else 1
    tfhd_body = be(1) + (struct.pack('>Q', len(init)) if base == 'explicit' else b'')
    tfhd_box = full('tfhd', tfhd_body, flags=flags)
    dt = full('tfdt', struct.pack('>Q' if tfdt_version else '>I', start), tfdt_version) if tfdt else b''
    trun_flags = 1 | (0xf00 if per_sample else 0) | (4 if first_flags else 0)
    if first_flags:
        trun_flags &= ~0x400
    def fragment(offset):
        trun = be(len(sizes)) + struct.pack('>i', offset) + (be(0x10000) if first_flags else b'')
        if per_sample:
            for duration, size, comp in zip(deltas, sizes, cto):
                trun += be(duration, size) + (b'' if first_flags else be(0)) + be(comp & 0xffffffff)
        return box('moof', full('mfhd', be(1)) + box('traf', tfhd_box + dt + full('trun', trun, cto_version, trun_flags)))
    moof = fragment(0)
    moof = fragment(len(moof) + 8)
    payload = b''.join(bytes([i+1]) * size for i, size in enumerate(sizes))
    data = init + moof + box('mdat', payload)
    offsets, dts, cursor, clock = [], [], len(init)+len(moof)+8, start if tfdt else 0
    for size, duration in zip(sizes, deltas):
        offsets.append(cursor); cursor += size
        dts.append(clock); clock += duration
    actual_cto = cto if per_sample else [0]*len(sizes)
    sync = list(range(2, len(sizes)+1)) if first_flags else None
    return data, expected_packets(offsets, sizes, dts, deltas, actual_cto, media_scale=scale, movie_scale=movie_scale, edits=edits, sync=sync)


def cases():
    """Deterministic boundaries plus varied rational clocks, not random bytes."""
    yield 'classic', classic()
    for compact in (4, 8, 16):
        yield f'stz2-{compact}', classic(compact=compact, sizes=(0, 1, 15, 2, 3))
    yield 'stz2-wide', classic(compact=16, sizes=(256, 1, 4096))
    yield 'constant', classic(constant=True, sizes=(4,)*9)
    yield 'co64-chunks-mdats', classic(co64=True, chunks=(2, 1, 2), mdats=2, large=True)
    yield 'faststart', classic(faststart=True)
    yield 'mdat-rest', classic(faststart=True, rest=True)
    yield 'headers-v1', classic(version=1, edit_version=1, edits=[(5, -1, 1), (0, 1, 1)])
    yield 'fraction-carry', classic(media_scale=7, movie_scale=3, edits=[(2, -1, 1), (0, 1, 1)], deltas=(1,)*5)
    yield 'sync-empty', classic(sync=[])
    yield 'sync-sparse', classic(sync=[1, 4])
    yield 'avc3', classic(codec='avc3')
    yield 'zero-sizes', classic(sizes=(0, 0, 0))
    yield 'zero-durations', classic(deltas=(0, 0, 0, 0, 0))
    yield 'empty', classic(sizes=())
    yield 'unsigned-ctts', classic(ctts_version=0, cto=(0x80000000,)*5)
    yield 'signed-ctts', classic(cto=(-80, 40, -40, 0, -160))
    yield 'equal-pts', classic(cto=(0, -40, -80, -120, -160))
    for name, edits in [('clip', [(70, 35, 1)]), ('open', [(0, 80, 1)]),
                        ('gap-open', [(7, -1, 1), (13, -1, 1), (0, 80, 1)]),
                        ('all-empty', [(20, -1, 1)]), ('zero-empty', [(0, -1, 1)]),
                        ('empty-edit-list', [])]:
        yield name, classic(edits=edits, cto=(0, 80, -40, -40, 0))
    rng = random.Random(0x4d503434)
    scales = [1, 3, 7, 90000, 1000000001, 2**32-1]
    for i in range(144):
        n = rng.randrange(1, 21)
        sizes = [rng.randrange(16) for _ in range(n)]
        deltas = [rng.randrange(0, 91) for _ in range(n)]
        cto = [rng.randrange(-120, 121) for _ in range(n)]
        edits = [(rng.randrange(30), -1, 1), (rng.randrange(50), rng.randrange(90), 1)] if i % 3 else None
        yield f'rational-{i:03}', classic(sizes=sizes, deltas=deltas, cto=cto,
             media_scale=scales[i % 6], movie_scale=scales[(i//6) % 6],
             edits=edits, edit_version=i%2, compact=(0, 4, 8, 16)[i%4],
             co64=bool(i%2), chunks=[1]*n, mdats=3, faststart=bool(i%2))
    for base, dt, per in itertools.product(('moof', 'explicit'), (False, True), (False, True)):
        common = dict(sizes=(4,)*3, deltas=(40,)*3, cto=(0,)*3)
        yield f'fragment-{base}-{dt}-{per}', fragmented(base=base, tfdt=dt, per_sample=per, **common)
    yield 'fragment-ctts-signed', fragmented()
    yield 'fragment-ctts-unsigned', fragmented(cto=(0x80000000, 0, 0xffffffff), cto_version=0, scale=90000)
    yield 'fragment-first-flags', fragmented(first_flags=True)
    yield 'fragment-tfdt32', fragmented(start=0xffffffff, tfdt_version=0, scale=90000)
    yield 'fragment-negative-preroll', fragmented(start=0, edits=[(0, 800, 1)])
    yield 'fragment-u64-clock', fragmented(start=2**64-100, scale=0xffffffff, deltas=(1, 2, 3))
    yield 'fragment-65bit-composition', fragmented(start=2**64-100, scale=0xffffffff, deltas=(1, 2, 3), cto=(0x7fffffff,)*3)
    yield 'fragment-zero-sizes', fragmented(sizes=(0, 0, 0))
    yield 'fragment-zero-durations', fragmented(deltas=(0, 0, 0))


def replace_field(data, kind, offset, value):
    """Patch a known model field relative to its box's payload."""
    where = data.index(kind.encode('ascii')) + 4 + offset
    return data[:where] + value + data[where+len(value):]


def rejects():
    data, _ = classic(sync=[1, 4])
    fields = [
        ('stsz-overcap', 'stsz', 8, be(1048577), 3),
        ('size-overcap', 'stsz', 12, be(16777217), 3),
        ('outside-mdat', 'stco', 8, be(1), 1),
        ('range-crosses-mdat', 'stsz', 12, be(18), 1),
        ('co64-overflow', 'co64', 8, struct.pack('>Q', 2**64-1), 1),
        ('zero-run', 'stts', 8, be(0), 1),
        ('short-run', 'stts', 8, be(4), 1),
        ('long-run', 'stts', 8, be(6), 1),
        ('zero-stsc', 'stsc', 12, be(0), 1),
        ('stsc-start', 'stsc', 8, be(2), 1),
        ('stsc-description', 'stsc', 16, be(2), 2),
        ('ctts-version', 'ctts', 0, be(2 << 24), 2),
        ('ctts-long-run', 'ctts', 8, be(6), 1),
        ('stss-duplicate', 'stss', 12, be(1), 1),
        ('stss-zero', 'stss', 8, be(0), 1),
        ('stss-outside', 'stss', 12, be(6), 1),
        ('movie-zero-scale', 'mvhd', 12, be(0), 1),
        ('media-zero-scale', 'mdhd', 12, be(0), 1),
        ('zero-track-id', 'tkhd', 12, be(0), 1),
    ]
    for name, kind, offset, value, error in fields:
        original = classic(co64=True, sync=[1, 4])[0] if kind == 'co64' else data
        yield name, replace_field(original, kind, offset, value), error
    for name, kwargs in [('external', dict(external=True)), ('dataref', dict(dataref=2)),
                         ('unsupported-codec', dict(codec='hvc1')), ('disabled', dict(enabled=False)),
                         ('edit-rate', dict(edits=[(1, 0, 0)])),
                         ('edit-negative', dict(edits=[(1, -2, 1)])),
                         ('multiple-active', dict(edits=[(1, 0, 1), (1, 1, 1)])),
                         ('trailing-empty', dict(edits=[(1, 0, 1), (1, -1, 1)]))]:
        yield name, classic(**kwargs)[0], 2
    yield 'config-overcap', classic(config=bytes(8208))[0], 3
    yield 'box-size-small', be(7) + b'free', 1
    yield 'box-size-large', be(1) + b'free' + struct.pack('>Q', 0xffffffffffffffff), 1
    yield 'duplicate-moov', data + data[data.index(b'moov')-4:], 1
    yield 'decode-unit-overflow', fragmented(start=2**64-1)[0], 3
    yield 'clock-ns-overflow', fragmented(start=2**63, scale=1)[0], 3
    fragment = fragmented()[0]
    fields = [
        ('tfhd-flags', 'tfhd', 0, be(0x020004), 2),
        ('tfhd-unknown-track', 'tfhd', 4, be(2), 1),
        ('tfhd-empty-with-samples', 'tfhd', 0, be(0x030000), 1),
        ('tfdt-version', 'tfdt', 0, be(2 << 24), 2),
        ('trun-version', 'trun', 0, be(2 << 24 | 0xf01), 2),
        ('trun-flags', 'trun', 0, be(1 << 24 | 0xf03), 2),
        ('trun-both-flags', 'trun', 0, be(1 << 24 | 0xf05), 1),
        ('trun-overcap', 'trun', 4, be(1048577), 3),
        ('trun-workcap', 'trun', 4, be(16777217), 3),
        ('trun-count-length', 'trun', 4, be(2), 1),
        ('trun-offset-negative', 'trun', 8, be(0x80000000), 1),
        ('trun-offset-outside', 'trun', 8, be(0x7fffffff), 1),
        ('trun-size-crosses-mdat', 'trun', 16, be(16), 1),
        ('trex-unknown-track', 'trex', 4, be(2), 1),
        ('trex-zero-description', 'trex', 8, be(0), 1),
        ('trex-other-description', 'trex', 8, be(2), 2),
    ]
    for name, kind, offset, value, error in fields:
        yield name, replace_field(fragment, kind, offset, value), error


def children(data, kind):
    """Known model container extraction, not used by timestamp expectations."""
    start = data.index(kind.encode('ascii'))-4
    size = struct.unpack_from('>I', data, start)[0]
    return data[start:start+size]


def tracks_case(first=None):
    """Two video choices sharing the same bytes but different composition time."""
    first = first or {}
    data, expected1 = classic(**first)
    second, expected2 = classic(track_id=2, cto=(40,)*5)
    track2 = children(second, 'trak')
    movie = children(data, 'moov')
    return data[:-len(movie)] + box('moov', movie[8:] + track2), expected1, expected2
