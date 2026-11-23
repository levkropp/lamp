"""Original CPU-only syntax fixtures. Synthetic coefficients never reach a GPU."""
from h264_file_fixtures import Writer, annex, picture


def rewrite_flat_marking(data, mode, Bits, frame_bits):
    """Change only headers of one-reference flat CAVLC pictures (no I_PCM).

    The independent decoder must reproduce every original pixel afterwards.
    Synthetic coefficient bodies from cases() are never used for these inputs.
    """
    from h264_file_fixtures import units
    changed = []; index = -1; counter = 0
    for nal in units(data):
        kind = nal[0]&31
        if kind not in (1, 5):
            changed.append(nal); continue
        b = Bits(nal); assert b.ue() == 0; slice_type = b.ue() % 5; b.ue()
        num_start = b.position; b.read(frame_bits); num_end = b.position
        if kind == 5:
            assert slice_type == 2; index = counter = 0; b.ue()
        else:
            assert slice_type == 0; index += 1; counter += 1
            if b.read():
                assert b.ue() == 0
            assert b.read() == 0  # one retained picture needs no list modification
        start = b.position
        if kind == 5:
            b.read(2)
        else:
            assert b.read() == 0  # original x264 stream uses sliding-window marking
        stop = b.position
        raw = ''.join(f'{x:08b}' for x in b.data); end = raw.rfind('1')
        writer = Writer(); writer.bits = raw[:num_start]; writer.u(counter % (1 << frame_bits), frame_bits)
        writer.bits += raw[num_end:start]
        if kind == 5:
            writer.u(0); writer.u(int(mode == 'long6'))
        else:
            writer.u(1)
            commands = [(6, 0)] if mode == 'long6' else ([(1, 0)] if index % 2 else [(4, 1), (3, 0, 0), (2, 0)])
            if mode == 'reset5':
                commands = [(5,)] if index % 10 == 0 else [(1, 0)]
            for command in commands:
                for value in command:
                    writer.ue(value)
            writer.ue(0)
            if mode == 'reset5' and index % 10 == 0:
                counter = 0
        writer.bits += raw[stop:end]; changed.append(writer.nal(nal[0]))
    return annex(*changed)


def rewrite_flat_intra(data, Bits, frame_bits):
    """Turn all but the first genuine flat IDR into non-IDR I pictures."""
    from h264_file_fixtures import units
    changed = []; index = 0
    for nal in units(data):
        if nal[0]&31 != 5:
            changed.append(nal); continue
        if index:
            b = Bits(nal); assert b.ue() == 0; assert b.ue() % 5 == 2; b.ue()
            start = b.position; b.read(frame_bits); b.ue(); b.read(2)
            raw = ''.join(f'{x:08b}' for x in b.data); stop = raw.rfind('1')
            writer = Writer(); writer.bits = raw[:start]; writer.u(index % (1 << frame_bits), frame_bits); writer.u(0)
            writer.bits += raw[b.position:stop]; nal = writer.nal((nal[0]&0xe0) | 1)
        changed.append(nal); index += 1
    return annex(*changed)


def sps(refs=3, poc=2):
    b = Writer()
    for value in (66, 0xc0, 30):
        b.u(value, 8)
    b.ue(0); b.ue(0); b.ue(poc)
    if poc == 0:
        b.ue(0)
    b.ue(refs); b.u(0); b.ue(3); b.ue(3); b.u(1); b.u(1); b.u(0); b.u(0)
    return b.nal(0x67)


def slice(num=0, idr=False, long=False, mmco=None, poc=None, ref=True, kind=0, mb=0):
    b = Writer(); b.ue(mb); b.ue(2 if idr else kind); b.ue(0); b.u(num, 4)
    if idr:
        b.ue(0)
    if poc is not None:
        b.u(poc, 4)
    if not idr and kind == 0:
        b.u(1); b.ue(0); b.u(0)  # one active reference, no list modification
    if ref:
        if idr:
            b.u(0); b.u(int(long))
        else:
            b.u(int(mmco is not None))
            if mmco is not None:
                for operation in mmco:
                    op, *values = operation; b.ue(op)
                    for value in values:
                        b.ue(value)
                b.ue(0)
    b.se(0); b.ue(1); b.u(0xdeadbeef, 32)
    return b.nal((0x60 if ref else 0) | (5 if idr else 1))


def cases():
    # Expected tuples: (surface,frame_num,full_poc,[(surface,num_or_long,poc,long?)...]).
    sliding = [(0, 0, 0, []), (1, 1, 2, [(0, 0, 0, False)]),
               (2, 2, 4, [(0, 0, 0, False), (1, 1, 2, False)]),
               (3, 3, 6, [(0, 0, 0, False), (1, 1, 2, False), (2, 2, 4, False)]),
               (0, 4, 8, [(1, 1, 2, False), (2, 2, 4, False), (3, 3, 6, False)])]
    yield 'sliding', annex(sps(), picture(), slice(idr=True), *[slice(i) for i in range(1, 5)]), sliding
    yield 'non-idr-intra', annex(sps(), picture(), slice(idr=True), slice(1, kind=2), slice(2, kind=2)), sliding[:3]
    marking = [slice(idr=True), slice(1, mmco=[(4, 3), (3, 0, 1), (6, 2)]),
               slice(2, mmco=[(2, 1), (4, 2)]), slice(3, mmco=[(1, 0)]),
               slice(4, mmco=[(5,)]), slice(1)]
    expected = [(0, 0, 0, []), (1, 1, 2, [(0, 0, 0, False)]),
                (2, 2, 4, [(0, 1, 0, True), (1, 2, 2, True)]),
                (0, 3, 6, [(2, 2, 4, False)]),
                (1, 4, 8, [(0, 3, 6, False)]), (0, 1, 2, [(1, 0, 0, False)])]
    yield 'marking-1-through-6', annex(sps(), picture(), *marking), expected
    yield 'idr-long', annex(sps(), picture(), slice(idr=True, long=True), slice(1, mmco=[(2, 0)])), [
        (0, 0, 0, []), (1, 1, 2, [(0, 0, 0, True)])]
    expected = []
    for i in range(21):
        expected.append((i % 4, i % 16, i*2,
                         [(j % 4, j % 16, j*2, False) for j in range(max(0, i-3), i)]))
    yield 'frame-number-wrap', annex(sps(), picture(), slice(idr=True), *[slice(i % 16) for i in range(1, 21)]), expected
    lsbs = [0, 6, 12, 2, 8]; full = [0, 6, 12, 18, 24]
    expected = [(i % 4, i, full[i], [(j % 4, j, full[j], False) for j in range(max(0, i-3), i)]) for i in range(5)]
    yield 'poc-lsb-wrap', annex(sps(poc=0), picture(), *[slice(i, idr=i == 0, poc=lsb) for i, lsb in enumerate(lsbs)]), expected
    # Non-reference pictures do not enter the retained list or update PrevRefFrameNum.
    yield 'non-reference', annex(sps(), picture(), slice(idr=True), slice(1, ref=False), slice(1)), [
        (0, 0, 0, []), (1, 1, 1, [(0, 0, 0, False)]), (1, 1, 2, [(0, 0, 0, False)])]
    for name, body, sequence in [
        ('gap', [slice(idr=True), slice(3)], sps()),
        ('missing-idr', [slice(1)], sps()),
        ('missing-short', [slice(idr=True), slice(1, mmco=[(1, 2)])], sps()),
        ('missing-long', [slice(idr=True), slice(1, mmco=[(2, 0)])], sps()),
        ('long-outside-bound', [slice(idr=True), slice(1, mmco=[(6, 0)])], sps()),
        ('duplicate-mmco5', [slice(idr=True), slice(1, mmco=[(5,), (5,)])], sps()),
        ('max-long-outside-refs', [slice(idr=True), slice(1, mmco=[(4, 4)])], sps()),
        ('mmco6-then5', [slice(idr=True), slice(1, mmco=[(4, 2), (6, 1), (5,)])], sps()),
        ('mmco1-then5', [slice(idr=True), slice(1, mmco=[(1, 0), (5,)])], sps()),
        ('mmco5-then1', [slice(idr=True), slice(1, mmco=[(5,), (1, 0)])], sps()),
        ('mmco6-then4', [slice(idr=True), slice(1, mmco=[(4, 3), (6, 2), (4, 1)])], sps()),
        ('mmco6-then2', [slice(idr=True), slice(1, mmco=[(4, 3), (6, 2), (2, 2)])], sps()),
        ('duplicate-reference-frame-num', [slice(idr=True), slice(1), slice(1)], sps()),
        ('too-many-commands', [slice(idr=True), slice(1, mmco=[(4, 0)]*65)], sps()),
        ('adaptive-overflow', [slice(idr=True), slice(1), slice(2), slice(3, mmco=[])], sps()),
        ('poc-reorder', [slice(idr=True, poc=0), slice(1, poc=4), slice(2, poc=2)], sps(poc=0)),
        ('slice-marking-mismatch', [slice(idr=True), slice(1, mmco=[(4, 2)]), slice(1, mmco=[(4, 1)], mb=1)], sps()),
        ('all-long-sliding', [slice(idr=True, long=True), slice(1, mmco=[(4, 3), (6, 1)]), slice(2, mmco=[(6, 2)]), slice(3)], sps()),
    ]:
        yield name, annex(sequence, picture(), *body), None
