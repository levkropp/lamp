"""Original CPU-only Main/High header fixtures; synthetic bodies never reach GPU."""
from h264_file_fixtures import Writer, annex

DEFAULT4I = [6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42]
DEFAULT4P = [10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34]
DEFAULT8I = [6,10,10,13,11,13,16,16,16,16,18,18,18,18,18,23,23,23,23,23,23,25,25,25,25,25,25,25,27,27,27,27,27,27,27,27,29,29,29,29,29,29,29,31,31,31,31,31,31,33,33,33,33,33,36,36,36,36,38,38,38,40,40,42]
DEFAULT8P = [9,13,13,15,13,15,17,17,17,17,19,19,19,19,19,21,21,21,21,21,21,22,22,22,22,22,22,22,24,24,24,24,24,24,24,24,25,25,25,25,25,25,25,27,27,27,27,27,27,28,28,28,28,28,30,30,30,30,32,32,32,33,33,35]
DEFAULT = DEFAULT4I*3+DEFAULT4P*3+DEFAULT8I+DEFAULT8P


def scaling(b, value):
    b.u(int(value is not None))
    if value is None:
        return
    if value == 'default':
        b.se(-8)
    elif value == 'repeat':
        b.se(8); b.se(-16)
    elif isinstance(value, tuple):
        b.se(value[0])  # Deliberately out-of-range signed delta.
    else:
        previous = 8
        for number in value:
            b.se((number-previous+128) % 256-128); previous = number


def sps(profile=100, lists=None, chroma=1, depth=0, bypass=0):
    b = Writer(); b.u(profile, 8); b.u(0, 8); b.u(30, 8); b.ue(0)
    if profile == 100:
        b.ue(chroma)
        if chroma == 3:
            b.u(0)
        b.ue(depth); b.ue(depth); b.u(bypass); b.u(int(lists is not None))
        if lists is not None:
            for value in lists:
                scaling(b, value)
    b.ue(0); b.ue(2); b.ue(3); b.u(0); b.ue(3); b.ue(3); b.u(1); b.u(1); b.u(0); b.u(0)
    return b.nal(0x67)


def pps(entropy=0, weighted=0, transform=0, lists=None):
    b = Writer(); b.ue(0); b.ue(0); b.u(entropy); b.u(0); b.ue(0); b.ue(0); b.ue(0)
    b.u(weighted); b.u(0, 2); b.se(0); b.se(0); b.se(0); b.u(1); b.u(0); b.u(0)
    b.u(transform); b.u(int(lists is not None))
    if lists is not None:
        for value in lists:
            scaling(b, value)
    b.se(0)
    return b.nal(0x68)


def slice(num=0, entropy=0, weighted=0, denom=0, weights=None, active=1, cabac=0, bad_align=False, deblock=None):
    b = Writer(); b.ue(0); b.ue(2 if num == 0 else 0); b.ue(0); b.u(num, 4)
    if num == 0:
        b.ue(0); b.u(0); b.u(0)
    else:
        b.u(1); b.ue(active-1); b.u(0)
        if weighted:
            b.ue(denom); b.ue(denom)
            for _ in range(active):
                b.u(int(weights is not None))
                if weights is not None:
                    b.se(weights[0]); b.se(weights[1])
                b.u(int(weights is not None))
                if weights is not None:
                    for value in weights[2:]:
                        b.se(value)
        b.u(0)  # sliding-window marking
        if entropy:
            b.ue(cabac)
    b.se(0); b.ue(1 if deblock is None else 0)
    if deblock is not None:
        b.se(deblock[0]); b.se(deblock[1])
    if entropy:
        first = True
        while len(b.bits) % 8:
            b.u(0 if first and bad_align else 1); first = False
    b.u(0xacc01ade, 32)
    return b.nal(0x65 if num == 0 else 0x61)


def cases():
    flat = [16]*224
    explicit = [[17]*16, [19]*16, [23]*16, [29]*16, [31]*16, [37]*16, [41]*64, [43]*64]
    good = [
        ('baseline', dict(profile=66), dict(), dict(), flat),
        ('main-cabac', dict(profile=77), dict(entropy=1), dict(entropy=1), flat),
        ('high-eight', dict(), dict(entropy=1, transform=1), dict(entropy=1, cabac=2), flat),
        ('cabac-deblock-offsets', dict(profile=77), dict(entropy=1), dict(entropy=1, deblock=(-3, 6)), flat),
        ('cavlc-deblock-offsets', dict(profile=77), dict(), dict(deblock=(6, -6)), flat),
        ('sps-absent-defaults', dict(lists=[None]*8), dict(transform=1), dict(), DEFAULT),
        ('sps-custom-inherit', dict(lists=explicit), dict(transform=1), dict(), sum(explicit, [])),
        ('pps-fallback-a', dict(), dict(transform=1, lists=[None]*8), dict(), DEFAULT),
        ('pps-fallback-b', dict(lists=explicit), dict(transform=1, lists=[None]*8), dict(), [17]*48+[29]*48+[41]*64+[43]*64),
        ('pps-explicit-default', dict(lists=explicit), dict(transform=1, lists=['default', None, None, None, None, None, 'default', None]), dict(), DEFAULT4I*3+[29]*48+DEFAULT8I+[43]*64),
        ('early-zero-repeat', dict(lists=['repeat']*8), dict(transform=1), dict(), flat),
        ('scale-255', dict(lists=[[255]*16]*6+[[255]*64]*2), dict(transform=1), dict(), [255]*224),
        ('weights-endpoints', dict(profile=77), dict(entropy=1, weighted=1), dict(entropy=1, weighted=1, denom=7, weights=(-128,127,127,-128,-128,127)), flat),
        ('weights-implicit128', dict(profile=77), dict(weighted=1), dict(weighted=1, denom=7), flat),
        ('weights-sixteen', dict(profile=77), dict(weighted=1), dict(weighted=1, active=16), flat),
    ]
    for name, seq, pic, frame, matrix in good:
        yield name, annex(sps(**seq), pps(**pic), slice(entropy=pic.get('entropy', 0)), slice(1, **frame)), matrix, pic
    for name, seq, pic, frame in [
        ('baseline-cabac', dict(profile=66), dict(entropy=1), dict(entropy=1)),
        ('baseline-weight', dict(profile=66), dict(weighted=1), dict(weighted=1)),
        ('main-eight', dict(profile=77), dict(transform=1), dict()),
        ('main-matrix', dict(profile=77), dict(lists=[None]*6), dict()),
        ('chroma422', dict(chroma=2), dict(), dict()),
        ('ten-bit', dict(depth=2), dict(), dict()),
        ('bypass', dict(bypass=1), dict(), dict()),
        ('scale-delta128', dict(lists=[(128,)]+[None]*7), dict(), dict()),
        ('scale-delta-minus129', dict(lists=[(-129,)]+[None]*7), dict(), dict()),
        ('weight-denom8', dict(profile=77), dict(weighted=1), dict(weighted=1, denom=8)),
        ('weight128', dict(profile=77), dict(weighted=1), dict(weighted=1, weights=(128,0,1,0,1,0))),
        ('weight-minus129', dict(profile=77), dict(weighted=1), dict(weighted=1, weights=(-129,0,1,0,1,0))),
        ('chroma-offset128', dict(profile=77), dict(weighted=1), dict(weighted=1, weights=(1,0,1,128,1,0))),
        ('active-seventeen', dict(profile=77), dict(weighted=1), dict(weighted=1, active=17)),
        ('cabac-init3', dict(profile=77), dict(entropy=1), dict(entropy=1, cabac=3)),
        ('cabac-align-zero', dict(profile=77), dict(entropy=1), dict(entropy=1, cabac=1, bad_align=True)),
        ('beta-seven', dict(profile=77), dict(), dict(deblock=(0,7))),
        ('beta-minus-seven', dict(profile=77), dict(), dict(deblock=(0,-7))),
    ]:
        yield name, annex(sps(**seq), pps(**pic), slice(entropy=pic.get('entropy', 0)), slice(1, **frame)), None, pic
