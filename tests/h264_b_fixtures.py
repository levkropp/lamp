"""Original CPU-only B-header and level/VUI fixtures; synthetic bodies never reach GPU."""
from h264_file_fixtures import Writer, annex


def sps(profile=77, constraints=0, refs=3, level=30, restriction=(2, 3), width=4, height=4):
    b=Writer();b.u(profile,8);b.u(constraints,8);b.u(level,8);b.ue(0)
    if profile==100:
        b.ue(1);b.ue(0);b.ue(0);b.u(0);b.u(0)
    b.ue(0);b.ue(0);b.ue(0);b.ue(refs);b.u(0);b.ue(width-1);b.ue(height-1);b.u(1);b.u(1);b.u(0)
    b.u(int(restriction is not None))
    if restriction is not None:
        for _ in range(8):b.u(0) # aspect,overscan,signal,chroma,timing,2HRD,pic_struct
        b.u(1);b.u(1)
        for x in (0,0,10,10,*restriction):b.ue(x)
    return b.nal(0x67)


def pps(bipred=0, entropy=0):
    b=Writer();b.ue(0);b.ue(0);b.u(entropy);b.u(0);b.ue(0);b.ue(0);b.ue(0);b.u(0);b.u(bipred,2)
    b.se(0);b.se(0);b.se(0);b.u(1);b.u(0);b.u(0)
    return b.nal(0x68)


def slice(kind=2,num=0,poc=0,ref=True,idr=True,spatial=1,active=(1,1),mods=((),()),bipred=0,entropy=0,denom=0,weights=False,cabac=0,discard=0,mb=0):
    b=Writer();b.ue(mb);b.ue(kind);b.ue(0);b.u(num,4)
    if idr:b.ue(0)
    b.u(poc,4)
    if kind!=2:
        if kind==1:b.u(spatial)
        b.u(1);b.ue(active[0]-1)
        if kind==1:b.ue(active[1]-1)
        for commands in mods[:2 if kind==1 else 1]:
            b.u(bool(commands))
            if commands:
                for op,value in commands:b.ue(op);b.ue(value)
                b.ue(3)
        if kind==1 and bipred==1:
            b.ue(denom);b.ue(denom)
            for n in active:
                for _ in range(n):
                    b.u(weights)
                    if weights:b.se(1);b.se(-7)
                    b.u(weights)
                    if weights:
                        for x in (1,4,1,-5):b.se(x)
    if ref:
        if idr:b.u(discard);b.u(0)
        else:b.u(0)
    if entropy and kind!=2:b.ue(cabac)
    b.se(0);b.ue(1)
    if entropy:
        while len(b.bits)%8:b.u(1)
    b.u(0xdeadbeef,32)
    return b.nal((0x60 if ref else 0)|(5 if idr else 1))


def cases():
    for name,params in [('direct-spatial',{}),('direct-temporal',dict(spatial=0)),('two-lists',dict(mods=(((0,0),(2,0)),((1,0),(2,0))))),
                        ('active-16',dict(active=(16,16))),('b-reference',dict(ref=True)),('cabac-b',dict(entropy=1)),
                        ('implicit-weights',dict(bipred=2)),('explicit-weights',dict(bipred=1,weights=True)),
                        ('explicit-defaults',dict(bipred=1)),('explicit-denom7',dict(bipred=1,denom=7,weights=True))]:
        entropy=params.get('entropy',0);bipred=params.get('bipred',0)
        header=pps(bipred,entropy)
        body=[slice(entropy=entropy),slice(0,1,6,idr=False,entropy=entropy),slice(1,2,2,idr=False,ref=False,**params)] if 'ref' not in params else [slice(),slice(0,1,6,idr=False),slice(1,2,2,idr=False,**params)]
        yield name,annex(sps(),header,*body),True,(2,3)
    for name,params in [('active-l0-17',dict(active=(17,1))),('active-l1-17',dict(active=(1,17))),
                        ('weight-denom8',dict(bipred=1,denom=8)),('cabac-init3',dict(entropy=1,cabac=3)),
                        ('list0-too-long',dict(mods=(((0,0),)*33,()))),('list1-too-long',dict(mods=((),((1,0),)*33)))]:
        entropy=params.get('entropy',0);bipred=params.get('bipred',0)
        yield name,annex(sps(),pps(bipred,entropy),slice(entropy=entropy),slice(1,1,2,idr=False,ref=False,**params)),False,None
    yield 'baseline-b',annex(sps(profile=66),pps(),slice(),slice(1,1,2,idr=False,ref=False)),False,None
    yield 'idr-discard-mismatch',annex(sps(),pps(),slice(),slice(discard=1,mb=1)),False,None
    for name,params,accepted,order in [('no-vui-main',dict(restriction=None),True,(16,16)),
                                    ('no-vui-high',dict(profile=100,restriction=None),True,(16,16)),
                                    ('high-intra-default',dict(profile=100,constraints=16,refs=0,restriction=None),True,(0,0)),
                                    ('reorder-above-buffer',dict(restriction=(4,3)),False,None),
                                    ('buffer-above-level',dict(restriction=(16,17)),False,None),
                                    ('buffer-below-refs',dict(restriction=(1,2)),False,None),
                                    ('level10-default',dict(level=10,restriction=None),True,(16,16)),
                                    ('level11-default',dict(level=11,width=20,height=15,restriction=None),True,(3,3)),
                                    ('level1b-main',dict(level=11,constraints=16,refs=1,width=20,height=15,restriction=None),True,(1,1)),
                                    ('level1b-high',dict(profile=100,level=9,refs=1,width=20,height=15,restriction=None),True,(1,1)),
                                    ('unknown-level',dict(level=8),False,None),
                                    ('zero-level-capacity',dict(level=10,width=25,height=25),False,None)]:
        yield name,annex(sps(**params),pps(),slice()),accepted,order
