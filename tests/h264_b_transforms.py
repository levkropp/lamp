"""Original test-only real-stream B explicit-weight transform. No codec implementation."""
from h264_file_fixtures import Writer, annex, units
from h264_profile_transforms import raw_bits


def explicit_b(data, Bits):
    """Insert nonidentity luma/chroma tables in real CAVLC B slices.

    Input is x264 Main, 4:2:0, POC0, no CABAC, implicit B weights. Compressed
    coefficient/motion payload bits remain intact. FFmpeg decodes the changed
    stream independently to provide the new reference (pixels may change).
    """
    nals=units(data);s=Bits(next(n for n in nals if n[0]&31==7))
    assert s.read(8)==77;s.read(16);s.ue();frame_bits=s.ue()+4;assert s.ue()==0;poc_bits=s.ue()+4
    p=Bits(next(n for n in nals if n[0]&31==8));p.ue();p.ue();assert p.read()==p.read()==p.ue()==0
    active=(p.ue()+1,p.ue()+1);p.read();flag=p.position;assert p.read(2)==2
    result=[];changed=0
    for nal in nals:
        kind=nal[0]&31
        if kind==8:
            b=Bits(nal);bits=raw_bits(b);w=Writer();w.bits=bits[:flag]+'01'+bits[flag+2:bits.rfind('1')];nal=w.nal(nal[0])
        elif kind==1:
            b=Bits(nal);b.ue();typ=b.ue()%5
            if typ==1:
                b.ue();b.read(frame_bits);b.read(poc_bits);b.read();counts=active
                if b.read():counts=(b.ue()+1,b.ue()+1)
                for _ in range(2):
                    if b.read():
                        for _ in range(33):
                            if b.ue()==3:break
                            b.ue()
                        else:raise AssertionError('Unbounded test list')
                bits=raw_bits(b);w=Writer();w.bits=bits[:b.position];w.ue(2);w.ue(2)
                for li,n in enumerate(counts):
                    for _ in range(n):
                        w.u(1);w.se(4);w.se(3 if li==0 else -2)
                        w.u(1);w.se(4);w.se(7);w.se(4);w.se(-5)
                w.bits+=bits[b.position:bits.rfind('1')];nal=w.nal(nal[0]);changed+=1
        result.append(nal)
    assert changed>0
    return annex(*result)
