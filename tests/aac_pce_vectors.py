"""Original PCE/ASC/raw_data_block writers; no decoder implementation. MIT."""
import random
import struct
from aac_vectors import Bits, adts
from sbr_vectors import element


def pce(bits, groups, rate=3, *, tag=0, comment=b'', mixdowns=False, assoc=(), coupling=(), object_type=1):
    """Append a PCE at the current ASC or raw-block bit position."""
    front, side, back, lfe = groups
    assert len(comment) <= 255
    for value, width in ((tag,4),(object_type,2),(rate,4),(len(front),4),(len(side),4),
                         (len(back),4),(len(lfe),2),(len(assoc),3),(len(coupling),4)):
        bits.put(value,width)
    for width in (4,4,3):
        bits.put(int(mixdowns),1)
        if mixdowns: bits.put(1,width)
    for group in groups[:3]:
        for kind, ident in group:
            bits.put(kind,1); bits.put(ident,4)
    for _, ident in lfe: bits.put(ident,4)
    for ident in assoc: bits.put(ident,4)
    for independent, ident in coupling: bits.put(independent,1);bits.put(ident,4)
    bits.put(0,-bits.count % 8)
    bits.put(len(comment),8)
    for byte in comment: bits.put(byte,8)


def asc(groups, rate=3, *, sbr=False, ps=False, **options):
    bits=Bits()
    for value,width in ((29 if ps else 5 if sbr else 2,5),(rate,4),(0,4)): bits.put(value,width)
    if sbr:
        for value,width in ((rate-3,4),(2,5)):bits.put(value,width)
    bits.put(0,3)
    pce(bits,groups,rate,**options)
    return bits.data()


def blocks(cores, groups, rate=3, *, reordered=False, repeat=0, leading=False, vary_comments=False, **options):
    """Distinct encoder elements retain their identity across permutations."""
    descriptors=sum((list(g) for g in groups),[])
    assert len(cores)==len(descriptors)
    result=[];rng=random.Random(1907)
    for frame in range(min(map(len,cores))):
        bits=Bits()
        if frame==0 or repeat and frame%repeat==0:
            if leading:
                for value,width in ((4,3),(7,4),(1,1),(3,8),(0xabcdef,24),  # aligned DSE
                                    (6,3),(2,4),(0,16)):bits.put(value,width)  # non-SBR fill
            current=dict(options)
            if vary_comments:current['comment']=f'frame {frame}'.encode()
            bits.put(5,3);pce(bits,groups,rate,**current)
        order=list(range(len(cores)))
        if reordered:rng.shuffle(order)
        for n in order:
            value,width=element(cores[n][frame]);kind,tag=descriptors[n]
            value=(value & ((1<<(width-7))-1)) | ((kind<<4|tag)<<(width-7))
            bits.put(value,width)
        bits.put(7,3);result.append(bits.data())
    return result


def adts_stream(packets,rate=3):
    return b''.join(adts(packet,rate,0) for packet in packets)


def packet_file(config, packets):
    """Little-endian lengths for the guarded C packet oracle."""
    return struct.pack('<II',len(config),len(packets))+config+b''.join(struct.pack('<I',len(p))+p for p in packets)


def describe_lc_asc(data):
    """Independent field dump for inspecting an encoder's explicit LC PCE."""
    value=int.from_bytes(data,'big');position=0
    def get(width):
        nonlocal position
        result=(value>>(len(data)*8-position-width))&((1<<width)-1);position+=width;return result
    assert get(5)==2
    rate=get(4);assert get(4)==0 and get(3)==0
    tag,object_type,pce_rate=get(4),get(2),get(4)
    counts=[get(n) for n in (4,4,4,2,3,4)]
    for width in (4,4,3):
        if get(1):get(width)
    groups=[[(get(1),get(4)) for _ in range(count)] for count in counts[:3]]
    groups.append([(3,get(4)) for _ in range(counts[3])])
    return dict(rate=rate,pce_rate=pce_rate,tag=tag,object_type=object_type,groups=groups)
