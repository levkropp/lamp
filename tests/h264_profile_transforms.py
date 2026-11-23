"""Original test-only header transforms of real encoded pictures, not codecs."""
from h264_file_fixtures import Writer, annex, units


def raw_bits(reader):
    return ''.join(f'{x:08b}' for x in reader.data)


def relocate_scaling(data, Bits, fallback=False):
    """Move PPS scaling syntax to SPS; optionally use PPS ruleB's absent flags."""
    nals = units(data); pic = next(n for n in nals if n[0]&31 == 8)
    p = Bits(pic); p.ue(); p.ue(); p.read(2); assert p.ue() == 0
    p.ue(); p.ue(); p.read(3); p.se(); p.se(); p.se(); p.read(3)
    assert p.read() == 1  # transform_8x8_mode_flag
    pic_flag = p.position; assert p.read() == 1; begin = p.position
    for i in range(8):
        if p.read():
            previous = following = 8
            for j in range(16 if i < 6 else 64):
                if following:
                    following = (previous+p.se()+256) % 256
                if following:
                    previous = following
    end = p.position; pp_bits = raw_bits(p); lists = pp_bits[begin:end]
    result = []
    for nal in nals:
        kind = nal[0]&31
        if kind == 7:
            b = Bits(nal); assert b.read(8) == 100; b.read(16); b.ue(); assert b.ue() == 1
            assert b.ue() == b.ue() == 0; assert b.read() == 0
            flag = b.position; assert b.read() == 0; bits = raw_bits(b)
            writer = Writer(); writer.bits = bits[:flag]+'1'+lists+bits[b.position:bits.rfind('1')]
            nal = writer.nal(nal[0])
        elif kind == 8:
            writer = Writer(); writer.bits = pp_bits[:pic_flag]+('1'+'0'*8 if fallback else '0')+pp_bits[end:pp_bits.rfind('1')]
            nal = writer.nal(nal[0])
        result.append(nal)
    return annex(*result)


def explicit_chroma(data, Bits):
    """Change P chroma offsets and preserve actual CABAC payload bytes.

    This intentionally changes decoded pixels; FFmpeg independently supplies the
    new image reference. The source uses Main, POC2, one slice and no B pictures.
    """
    nals = units(data); seq = Bits(next(n for n in nals if n[0]&31 == 7))
    assert seq.read(8) == 77; seq.read(16); seq.ue(); frame_bits = seq.ue()+4; assert seq.ue() == 2
    pic = Bits(next(n for n in nals if n[0]&31 == 8)); pic.ue(); pic.ue(); assert pic.read() == 1
    assert pic.read() == 0 and pic.ue() == 0; active = pic.ue()+1; pic.ue(); assert pic.read() == 1; pic.read(2)
    pic.se(); pic.se(); pic.se(); assert pic.read() == 1
    result = []
    for nal in nals:
        if nal[0]&31 != 1:
            result.append(nal); continue
        b = Bits(nal); assert b.ue() == 0; slice_type = b.ue() % 5
        if slice_type == 2:
            result.append(nal); continue
        assert slice_type == 0; b.ue(); b.read(frame_bits)
        count = b.ue()+1 if b.read() else active
        if b.read():
            for _ in range(33):
                operation = b.ue()
                if operation == 3:
                    break
                b.ue()
            else:
                raise AssertionError('Unbounded list modification in test input')
        begin = b.position; denom = b.ue(); b.ue(); weights = []
        for _ in range(count):
            value = (b.se(), b.se()) if b.read() else None
            if b.read():
                for _ in range(4):
                    b.se()
            weights.append(value)
        end = b.position; assert b.read() == 0  # no adaptive marking in this encode
        assert b.ue() <= 2; b.se()
        if b.ue() != 1:
            b.se(); b.se()
        header_end = b.position
        while b.position % 8:
            assert b.read() == 1
        entropy = b.position; bits = raw_bits(b)
        table = Writer(); table.ue(denom); table.ue(0)
        for value in weights:
            table.u(int(value is not None))
            if value is not None:
                table.se(value[0]); table.se(value[1])
            table.u(1); table.se(1); table.se(7); table.se(1); table.se(-7)
        writer = Writer(); writer.bits = bits[:begin]+table.bits+bits[end:header_end]
        while len(writer.bits) % 8:
            writer.u(1)
        writer.bits += bits[entropy:bits.rfind('1')]
        result.append(writer.nal(nal[0]))
    return annex(*result)
