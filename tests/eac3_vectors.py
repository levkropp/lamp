"""Test-only E-AC-3 streams sized by the independent decoder model.

Covers 1/2/3/6 blocks, both exponent syntaxes, optional fields and reuse.
Conventional and AHT mantissas are supported; enhanced coupling is rejected.
"""
import copy
import random
import ac3_model as ac3
import ac3_vectors
import eac3_model as model


class Writer(ac3_vectors.Writer):
    def choose(self, n, label, context):
        c, r = self.c, self.r
        if label == 'addbsi':
            # Opaque metadata must not advertise an object extension without
            # its mandatory complexity byte (a one-byte field is possible).
            return r.getrandbits(n) & ~(1 << (n-8))
        if label=='ahtinu':return int(context[0] in c.get('aht_channels',range(7))) if c.get('ahtinu') else 0
        if label=='gaqmod':return c.get(label,r.randrange(4))
        if label in ('gaqgain','ahtlarge'):return r.getrandbits(n)
        if label=='gaqgroup':return c.get(label,r.randrange(27))
        if label=='ahtvq':
            if c.get('aht_vq_cycle'):
                indices=c.setdefault('_vq_indices',{})
                bap=context[0];index=indices.get(bap,0)
                indices[bap]=index+1
                return index%(1<<n)
            return c.get(label,r.randrange(1<<n))
        if label in ('csnroffst','frmcsnroffst') and 'csnroffst' in c:return c['csnroffst']
        if label=='chbwcod' and label in c:return c[label]
        if label=='ahtmant':
            # Include escape tags as well as small and sign extremes.
            return 1<<(n-1) if r.random()<c.get('gaq_escape',0.4) else r.getrandbits(n)
        if label in ('spxstrtf','spxbegf','spxendf','spxbndstrce','spxbndstrc','spxcoe',
                     'spxblnd','mstrspxco','spxcoexp','spxcomant','spxattencod','spxattencode'):
            return c[label] if label in c else r.getrandbits(n)
        if label == 'chinspx':
            return int(context[0] in c.get('spx_channels',range(1,6)))
        if label == 'spxinu':
            value = c.get(label,0)
            return value[context[0]%len(value)] if isinstance(value,list) else value
        if label == 'spxstre' and c.get('spxinu'):
            return c.get(label,1)
        if label == 'cplbegf' and c.get('spxinu'):
            begin = c.get('spxbegf',4)+2
            if begin > 7: begin = 2*begin-7
            return r.randrange(begin-1)
        if label == 'snroffste' and c.get('snr_reuse'):
            return 0
        if label in ('expstre', 'ahte', 'snroffststr', 'transproce', 'blkswe', 'dithflage', 'bamode',
                     'frmfgaincode', 'dbaflde', 'skipflde', 'spxattene', 'frmchexpstr'):
            value = c.get(label, 0)
            return value[c.get('_index',0)%len(value)] if isinstance(value,list) else value
        if label in ('spxinu', 'ecplinu', 'ahtinu'):
            return c.get(label, 0)
        if label in ('spxstre', 'fgaincode', 'cplbndstrce', 'convsnroffste', 'pgmscle', 'extpgmscle',
                     'paninfoe', 'frmmixcfginfoe', 'blkmixcfginfoe', 'chintransproc', 'spxattencode',
                     'blkstrtinfoe', 'convexpstre', 'lfemixlevcode'):
            return r.randrange(2)
        if label in ('frame_expstr', 'frame_lfe_expstr'):
            channel=context[1] if len(context)>1 else ac3.CHANNELS[c['acmod']]+1
            if c.get('ahtinu') and channel in c.get('aht_channels',range(7)):
                return (1 if n==1 else r.randrange(1,4)) if context[0]==0 else 0
            if c.get('spxinu') and c.get('expstre',1):
                return 1 if n == 1 else r.randrange(1,4)
            blk = context[0]
            new = len(context) > 2 and context[2]
            if blk == 0 or new:
                return 1 if n == 1 else r.randrange(1, 4)
            return 0 if self.chance('reuse') else (1 if n == 1 else r.randrange(1, 4))
        if label == 'frame_cplstre':
            # LUT rows may reuse exponents; a new coupling range in such a
            # block would leave uncoded spectral gaps. Keep one range/frame.
            return self.chance('cplstre') if c.get('expstre',1) else 0
        if label == 'frame_cplinu':
            if c.get('late_coupling'):
                self.cpl_call = getattr(self,'cpl_call',0)+1
                return int(self.cpl_call>1)
            value = self.chance('coupling')
            if hasattr(self,'initial_cpl'):
                return value if self.initial_cpl else 0
            self.initial_cpl = value
            return value
        if label in ('mixmdate', 'infomdate'):
            return self.chance('metadata')
        if label == 'frmcsnroffst':
            return self.choose(6, 'csnroffst', ())
        if label == 'frmfsnroffst':
            return r.randrange(16)
        if label == 'mixdef':
            return c.get('mixdef', r.randrange(4))
        if label == 'mixdeflen':
            return r.randrange(8)
        if label == 'frmsizecod':
            return r.randrange(38)
        if label in ('dmixmod', 'center_mix', 'surround_mix', 'lfemixlevcod', 'pgmscl', 'extpgmscl',
                     'mixdata', 'paninfo', 'blkmixcfginfo', 'bsmod_copyright', 'surround_headphone',
                     'dsurexmod', 'sourcefscod', 'convsync', 'blkid', 'convexpstr', 'convsnroffst',
                     'transproc', 'spxattencod', 'blkstrtinfo'):
            return r.getrandbits(n)
        return super().choose(n, label, context)


def recrc(frame):
    frame = bytearray(frame)
    c = ac3.crc16(frame[2:-2])
    frame[-2:] = c.to_bytes(2, 'big')
    assert ac3.crc16(frame[2:]) == 0
    return bytes(frame)


def assemble(h, bits):
    frame = bytearray(h['bytes'])
    frame[:2] = b'\x0b\x77'
    words = h['bytes']//2-1
    frame[2] = h['typ'] << 6 | words >> 8
    frame[3] = words & 255
    frame[4] = h['fscod'] << 6 | [1, 2, 3, 6].index(h['blocks']) << 4 | h['acmod'] << 1 | h['lfe']
    value, count = 0, 0
    for v, n in bits:
        value = value << n | v
        count += n
    assert 40+count <= len(frame)*8-18
    frame[5:] = (value << ((len(frame)-5)*8-count)).to_bytes(len(frame)-5, 'big')
    return recrc(frame)


def stream(seed, frames=12, acmod=2, lfe=0, blocks=6, fscod=0, typ=0, size=4096, **options):
    r = random.Random(seed)
    config = dict(acmod=acmod, lfe=lfe, bsid=16, short=0, dither=0.7, drc=0.3, cplstre=0.25,
                  coupling=0.8, chincpl=0.75, cplcoe=0.4, rematstr=0.4, baie=0.3, snroffste=1.0,
                  cplleake=0.3, reuse=0.5, dba=0.25, skip=0.15, addbsi=0.2, metadata=0.7,
                  expstre=1, snroffststr=2, blkswe=1, dithflage=1, bamode=1, frmfgaincode=1,
                  dbaflde=1, skipflde=1, transproce=1, spxattene=1)
    config.update(options)
    decoder = model.Decoder()
    out = bytearray()
    snr = 40
    for index in range(frames):
        config['_index'] = index
        nb = blocks[index % len(blocks)] if isinstance(blocks, (list, tuple)) else blocks
        h = dict(fscod=fscod, acmod=acmod, lfe=lfe, bsid=16, bytes=size, shift=0, blocks=nb, typ=typ)
        vq_indices=dict(config.get('_vq_indices',{}))
        for attempt in range(100):
            # A rejected oversized attempt must not skip codebook entries
            # in the accepted stream used for exhaustive VQ coverage.
            if config.get('aht_vq_cycle'):config['_vq_indices']=dict(vq_indices)
            trial = copy.deepcopy(decoder)
            writer = Writer(r, config, snr, index == 0)
            trial.decode_frame(writer, h, strict=True)
            if writer.pos <= size*8-18:
                break
            snr = max(0, snr-3)
        else:
            raise AssertionError('E-AC-3 frame overflow')
        decoder = trial
        out += assemble(h, writer.bits)
        if writer.pos < size*6:
            snr = min(63, snr+2)
    return bytes(out), decoder.used


def unsupported(tool):
    config = dict(acmod=2, lfe=0, bsid=16, expstre=0, ahte=1, snroffststr=0,
                  coupling=1, cplstre=0, frmchexpstr=0, metadata=0, addbsi=0, drc=0,
                  **{tool: 1})
    if tool == 'late_coupling':config.update(expstre=1,cplstre=1)
    if tool == 'snr_reuse':config.update(snroffststr=2)
    decoder = model.Decoder()
    writer = Writer(random.Random(19), config, 20, True)
    h = dict(acmod=2, lfe=0, bsid=16, bytes=1024, fscod=0, blocks=6, typ=0, shift=0)
    try:
        decoder.decode_frame(writer, h, strict=True)
    except ac3.DecodeError as error:
        assert 'unsupported' in str(error), error
    else:
        raise AssertionError('unsupported tool did not raise')
    return assemble(h, writer.bits)
