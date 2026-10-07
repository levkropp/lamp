"""Test-only E-AC-3 parser atop the AC-3 DSP model.

ATSC A/52:2018 Annex E syntax. Labels allow eac3_vectors to generate independent
coverage of fields that FFmpeg's encoder does not exercise. Enhanced
coupling is rejected; metadata does not override LAMP's
shared speaker weights. No reference decoder is linked into the player.
"""
import importlib.util
import math
from pathlib import Path
import ac3_model as ac3

_spec = importlib.util.spec_from_file_location('generate_eac3', Path(__file__).with_name('generate-eac3-tables.py'))
_gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gen)
EXPSTR, DEFAULT_CPL, DEFAULT_SPX, SPX_ATTEN = _gen.tables()
_spec = importlib.util.spec_from_file_location('generate_aht',Path(__file__).with_name('generate-eac3-aht-tables.py'))
_aht = importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_aht)
HEBAP, AHT_BITS, AHT_VQ, AHT_REMAP, AHT_COS = _aht.tables()


def idct6(values):
    # Symmetric six-point factorization in Q23. Keep each multiplication's
    # arithmetic shift before the final sums, matching integer reconstruction.
    x0,x1,x2,x3,x4,x5=values
    c0,c1,c2=AHT_COS
    middle=(x4*c1)>>23
    centre=x0-middle
    side=x0+(middle>>1)
    spread=(x2*c0)>>23
    edge=((x1+x5)*c2)>>23
    odd=[edge+x1+x3,x1-x3-x5,edge+x5-x3]
    even=[side+spread,centre,side-spread]
    return [ac3._i32(even[i]+odd[i]) for i in range(3)]+[ac3._i32(even[i]-odd[i]) for i in (2,1,0)]


def header(data):
    if len(data) < 8 or data[:2] != b'\x0b\x77' or not 11 <= data[5] >> 3 <= 16:
        return None
    typ, sub = data[2] >> 6, data[2] >> 3 & 7
    rate = data[4] >> 6
    if typ not in (0, 2) or sub or rate == 3:
        return None
    size = 2 * (((data[2] & 7) << 8 | data[3]) + 1)
    return dict(bytes=size, fscod=rate, shift=0, acmod=data[4] >> 1 & 7, lfe=data[4] & 1,
                blocks=[1, 2, 3, 6][data[4] >> 4 & 3], typ=typ, bsid=data[5] >> 3)


def frames(data):
    while data:
        h = header(data)
        if h is None or len(data) < h['bytes']:
            return
        yield data[:h['bytes']]
        data = data[h['bytes']:]


class Decoder(ac3.Decoder):
    default_cpl_bands = DEFAULT_CPL
    aht_bap_table = HEBAP

    def __init__(self, check_crc=True, ffmpeg_vq4=False):
        super().__init__(check_crc)
        self.enhanced = True
        # FFmpeg 5.1/6.1/9.0 omit Table E4.4 row zero, shifting indices
        # 0..30 and zero-initializing index 31. Only the test comparator
        # enables this known deviation; normative output keeps all 32 rows.
        self.ffmpeg_vq4 = ffmpeg_vq4
        self.spx_noise, self.spx_signal = [[0.0]*17 for _ in range(7)], [[0.0]*17 for _ in range(7)]

    def frame(self, data):
        h = header(data)
        if not h or len(data) < h['bytes']:
            return None
        return self.decode_frame(ac3.Reader(data[:h['bytes']], 40), h,
                                 self.check_crc and ac3.crc16(data[2:h['bytes']]) != 0)

    def decode_frame(self, g, h, err=False, strict=False):
        self.acmod, self.lfe = h['acmod'], h['lfe']
        self.nfchans = nf = ac3.CHANNELS[self.acmod]
        self.channels = nf + self.lfe
        self.lfe_ch = nf + 1 if self.lfe else -1
        self.params['sr_shift'], self.params['sr_code'] = 0, h['fscod']
        self.typ, blocks = h['typ'], h['blocks']
        acmod = self.acmod
        self.used.update({f'blocks {blocks}', f'frame type {self.typ}', f'acmod {acmod}'})
        g.get(5, 'bsid')
        programs = 2 if acmod == 0 else 1
        for i in range(programs):
            g.get(5, 'dialnorm')
            if g.get(1, 'compre'):
                g.get(8, 'compr')
        if g.get(1, 'mixmdate'):
            if acmod > 2:
                g.get(2, 'dmixmod')
                if acmod & 1:
                    g.get(6, 'center_mix')
                if acmod & 4:
                    g.get(6, 'surround_mix')
            if self.lfe and g.get(1, 'lfemixlevcode'):
                g.get(5, 'lfemixlevcod')
            if self.typ == 0:
                for i in range(programs):
                    if g.get(1, 'pgmscle'):
                        g.get(6, 'pgmscl')
                if g.get(1, 'extpgmscle'):
                    g.get(6, 'extpgmscl')
                mix = g.get(2, 'mixdef')
                if mix in (1, 2):
                    g.get(5 if mix == 1 else 12, 'mixdata')
                elif mix == 3:
                    g.get(8 * (g.get(5, 'mixdeflen') + 2), 'mixdata')
                if acmod < 2:
                    for i in range(programs):
                        if g.get(1, 'paninfoe'):
                            g.get(14, 'paninfo')
                if g.get(1, 'frmmixcfginfoe'):
                    for blk in range(blocks):
                        if blocks == 1 or g.get(1, 'blkmixcfginfoe'):
                            g.get(5, 'blkmixcfginfo')
        if g.get(1, 'infomdate'):
            g.get(5, 'bsmod_copyright')
            if acmod == 2:
                g.get(4, 'surround_headphone')
            if acmod >= 6:
                g.get(2, 'dsurexmod')
            for i in range(programs):
                if g.get(1, 'audprodie'):
                    g.get(8, 'audprod')
            g.get(1, 'sourcefscod')
        if self.typ == 0 and blocks != 6:
            g.get(1, 'convsync')
        if self.typ == 2 and (blocks == 6 or g.get(1, 'blkid')):
            g.get(6, 'frmsizecod')
        if g.get(1, 'addbsie'):
            g.get(8 * (g.get(6, 'addbsil') + 1), 'addbsi')
        expstre, ahte = (g.get(1, 'expstre'), g.get(1, 'ahte')) if blocks == 6 else (1, 0)
        self.used.add('per-block exponents' if expstre else 'LUT exponents')
        self.snr_strategy = g.get(2, 'snroffststr')
        self.used.add(f'SNR strategy {self.snr_strategy}')
        if self.snr_strategy == 3:
            raise ac3.DecodeError('reserved SNR strategy')
        transient = g.get(1, 'transproce')
        self.switch_syntax = g.get(1, 'blkswe')
        self.dither_syntax = g.get(1, 'dithflage')
        self.ba_syntax = g.get(1, 'bamode')
        self.gain_syntax = g.get(1, 'frmfgaincode')
        self.dba_syntax = g.get(1, 'dbaflde')
        self.skip_syntax = g.get(1, 'skipflde')
        atten = g.get(1, 'spxattene')
        for name in ('switch_syntax','dither_syntax','ba_syntax','gain_syntax','dba_syntax','skip_syntax'):
            self.used.add(f'{name} {getattr(self,name)}')
        self.params.update(slow_decay=19, fast_decay=83, slow_gain=1240, db_per_bit=2304, floor=-2048)
        self.cplstre, self.cplinu = [0]*blocks, [0]*blocks
        if acmod > 1:
            for blk in range(blocks):
                self.cplstre[blk] = 1 if blk == 0 else g.get(1, 'frame_cplstre', blk)
                self.cplinu[blk] = g.get(1, 'frame_cplinu', acmod) if self.cplstre[blk] else self.cplinu[blk-1]
        if not self.cplinu[0] and any(self.cplinu):
            raise ac3.DecodeError('late coupling unsupported')
        self.frame_expstr = [[0]*7 for _ in range(blocks)]
        if expstre:
            for blk in range(blocks):
                for ch in range(not self.cplinu[blk], nf + 1):
                    self.frame_expstr[blk][ch] = g.get(2, 'frame_expstr', blk, ch, self.cplstre[blk])
        else:
            for ch in range(not any(self.cplinu), nf + 1):
                code = g.get(5, 'frmchexpstr', ch)
                self.used.add(f'frame exponent row {code}')
                row = EXPSTR[code]
                for blk in range(6):
                    self.frame_expstr[blk][ch] = row[blk]
        if self.lfe:
            for blk in range(blocks):
                self.frame_expstr[blk][self.lfe_ch] = g.get(1, 'frame_lfe_expstr', blk)
        if self.typ == 0 and (blocks == 6 or g.get(1, 'convexpstre')):
            g.get(5 * nf, 'convexpstr')
        self.channel_in_aht=[0]*7
        self.aht_pre=[[[0]*6 for _ in range(256)] for _ in range(7)]
        if ahte:
            for ch in range(sum(self.cplinu) != 6, self.channels + 1):
                if all(self.frame_expstr[b][ch] == 0 and (ch or not self.cplstre[b]) for b in range(1, 6)):
                    self.channel_in_aht[ch]=g.get(1,'ahtinu',ch)
                    if self.channel_in_aht[ch]:self.used.add(f'AHT channel {ch}')
        if self.snr_strategy == 0:
            snr = ((g.get(6, 'frmcsnroffst') - 15)*16 + g.get(4, 'frmfsnroffst'))*4
            self.snr_offset = [snr]*7
        if transient:
            for ch in range(1, nf + 1):
                if g.get(1, 'chintransproc'):
                    g.get(18, 'transproc')
        self.spx_atten = [-1]*7
        if atten:
            for ch in range(1, nf + 1):
                if g.get(1, 'spxattencode'):
                    self.spx_atten[ch] = g.get(5, 'spxattencod', ch)
                    self.used.add(f'SPX attenuation {self.spx_atten[ch]}')
        if blocks > 1 and g.get(1, 'blkstrtinfoe'):
            g.get((blocks-1)*(4+(h['bytes']-2).bit_length()-1), 'blkstrtinfo')
        self.first_cpl_coords, self.first_cpl_leak = [1]*7, True
        self.cpl_band_struct = list(DEFAULT_CPL) + [0]*4
        self.ecpl_in_use = False
        if hasattr(self, 'ecpl_reset_bands'): self.ecpl_reset_bands()
        self.spx_in_use = False
        self.channel_in_spx = [0]*7
        self.first_spx_coords = [1]*7
        self.spx_struct = DEFAULT_SPX[:]
        if self.lfe:
            self.start_freq[self.lfe_ch] = 0
            self.end_freq[self.lfe_ch] = 7
            self.num_exp_groups[self.lfe_ch] = 2
            self.channel_in_cpl[self.lfe_ch] = 0
        out = [[] for _ in range(self.channels)]
        self.dba_sent = set()
        for blk in range(blocks):
            g.mark('block', blk)
            if not err:
                try:
                    block = self.block(g, blk)
                    if g.data and g.pos > h['bytes']*8-16:
                        raise ac3.DecodeError('truncated block')
                    if hasattr(self, 'block_accepted'): self.block_accepted(blk)
                except (ac3.DecodeError, IndexError):
                    if strict:
                        raise
                    err = True
                    self.used.add('block error')
            if err:
                block = self.last if self.last is not None else [[0.0]*256 for _ in out]
            for ch in range(self.channels):
                out[ch].extend(block[ch])
            self.last = block
        g.mark('end')
        return out

    def aht_mantissas(self,g,ch,coeffs):
        begin,end=self.start_freq[ch],self.end_freq[ch]
        if self.current_block==0:
            mode=g.get(2,'gaqmod',ch)
            self.used.add(f'GAQ mode {mode}')
            upper=12 if mode<2 else 17
            gains=[]
            count=sum(8<=self.bap[ch][b]<upper for b in range(begin,end))
            if mode in (1,2):gains=[g.get(1,'gaqgain')<<(mode-1) for _ in range(count)]
            elif mode==3:
                for i in range(0,count,3):
                    code=g.get(5,'gaqgroup')
                    if code>26:self.used.add('GAQ clamped group')
                    code=min(code,26)
                    gains.extend([code//9,(code//3)%3,code%3])
            gain_index=0
            for b in range(begin,end):
                bap=self.bap[ch][b]
                self.used.add(f'hebap {bap}')
                bits=AHT_BITS[bap]
                if bap==0:
                    mant=[(self.random_word()&0x7fffff)-0x400000 for _ in range(6)]
                    self.used.add('AHT dither')
                elif bap<8:
                    code=g.get(bits,'ahtvq',bap)
                    self.used.add(f'AHT VQ {bap} index {code}')
                    row = AHT_VQ[bap-1][code]
                    if self.ffmpeg_vq4 and bap==4:
                        row=AHT_VQ[3][code+1] if code<31 else [0]*6
                    mant=[v*256 for v in row]
                else:
                    gain=gains[gain_index] if mode and bap<upper else 0
                    if mode and bap<upper:gain_index+=1
                    self.used.add(f'GAQ gain {gain}')
                    small=bits-gain
                    mant=[]
                    for blk in range(6):
                        value=g.signed(small,'ahtmant',bap,gain)
                        if gain and value==-(1<<(small-1)):
                            width=bits-2+gain
                            value=g.signed(width,'ahtlarge',bap,gain)<<(24-width)
                            a=AHT_REMAP[bap-8][gain]
                            bias=1<<(23-gain) if value>=0 else AHT_REMAP[bap-8][gain+2]*256
                            value+=((a*value)>>15)+bias
                            self.used.add(f'GAQ large gain {gain} '+('negative' if value<0 else 'positive'))
                        else:
                            value*=1<<(24-bits)
                            if not gain:value+=(AHT_REMAP[bap-8][0]*value)>>15
                            self.used.add('GAQ small')
                        mant.append(ac3._i32(value))
                self.aht_pre[ch][b]=idct6(mant)
        for b in range(begin,end):coeffs[b]=self.aht_pre[ch][b][self.current_block]>>self.dexps[ch][b]

    def spx_block(self, g, blk):
        f = ac3.f32
        if blk == 0 or g.get(1, 'spxstre', blk):
            self.spx_in_use = g.get(1, 'spxinu', blk)
            self.used.add(f'SPX active {self.spx_in_use}')
            if self.spx_in_use:
                for ch in range(1, self.nfchans+1):
                    self.channel_in_spx[ch] = 1 if self.acmod == 1 else g.get(1, 'chinspx', ch, blk)
                self.spx_copy = 12*g.get(2, 'spxstrtf')+25
                begin, end = g.get(3, 'spxbegf')+2, g.get(3, 'spxendf')+5
                if begin > 7: begin = 2*begin-7
                if end > 7: end = 2*end-7
                self.spx_start, self.spx_end = 12*begin+25, 12*end+25
                if begin >= end or self.spx_copy >= self.spx_start:
                    raise ac3.DecodeError('invalid SPX range')
                if g.get(1, 'spxbndstrce', blk):
                    for b in range(begin+1,end):
                        self.spx_struct[b] = g.get(1, 'spxbndstrc', b)
                    self.used.add('SPX explicit bands')
                else:
                    self.used.add('SPX default/reused bands')
                self.spx_sizes = [12]
                for b in range(begin+1,end):
                    if self.spx_struct[b]: self.spx_sizes[-1] += 12
                    else: self.spx_sizes.append(12)
                self.used.add('SPX partial channels' if sum(self.channel_in_spx) < self.nfchans else 'SPX all channels')
            else:
                self.channel_in_spx = [0]*7
        for ch in range(1,self.nfchans+1):
            if not self.channel_in_spx[ch]:
                self.first_spx_coords[ch] = 1
                continue
            if self.first_spx_coords[ch] or g.get(1, 'spxcoe', ch, blk):
                self.first_spx_coords[ch] = 0
                blend, master = g.get(5,'spxblnd',ch)/32, 3*g.get(2,'mstrspxco')
                self.used.add(f'SPX blend {int(blend*32)}')
                self.used.add(f'SPX master {master//3}')
                pos = self.spx_start
                for b,size in enumerate(self.spx_sizes):
                    ratio = min(1.0,max(0.0,f(f((pos+size//2)/self.spx_end)-blend)))
                    exp, mant = g.get(4,'spxcoexp'), g.get(2,'spxcomant')
                    self.used.add(f'SPX exponent {exp}')
                    self.used.add(f'SPX mantissa {mant}')
                    coord = (2*mant if exp == 15 else mant+4)*2.0**(2-exp-master)
                    self.spx_noise[ch][b] = f(f(math.sqrt(f(3*ratio)))*coord)
                    self.spx_signal[ch][b] = f(f(math.sqrt(f(1-ratio)))*coord)
                    pos += size
            else:
                self.used.add('SPX coordinate reuse')

    def spx_apply(self, ch, coeffs):
        f = ac3.f32
        source, out = self.spx_copy, self.spx_start
        borders, energies = [], []
        for size in self.spx_sizes:
            wrap = source+size > self.spx_start
            if wrap: source = self.spx_copy
            borders.append(wrap or out == self.spx_start)
            for i in range(size):
                if source == self.spx_start: source = self.spx_copy
                coeffs[out+i] = coeffs[source]
                source += 1
            total = 0.0
            for x in coeffs[out:out+size]: total = f(total+f(x*x))
            energies.append(f(math.sqrt(f(total/size))))
            out += size
        out = self.spx_start
        if self.spx_atten[ch] >= 0:
            a = [f(x) for x in SPX_ATTEN[self.spx_atten[ch]]]
            for size,border in zip(self.spx_sizes,borders):
                if border:
                    for i,gain in enumerate(a+a[1::-1]): coeffs[out-2+i] = f(coeffs[out-2+i]*gain)
                out += size
        out = self.spx_start
        for b,size in enumerate(self.spx_sizes):
            noise = f(f(self.spx_noise[ch][b]*energies[b])*(-2.0**-31))
            for i in range(size):
                v = ac3._i32(self.random_word())
                coeffs[out] = f(f(coeffs[out]*self.spx_signal[ch][b])+f(noise*f(float(v))))
                out += 1

    def block_snr(self, g, blk, stages):
        first = 0 if self.cpl_in_use else 1
        if blk == 0 and self.snr_strategy:
            if not g.get(1, 'snroffste', 0):
                raise ac3.DecodeError('unsupported older-frame SNR reuse')
            coarse = (g.get(6, 'csnroffst')-15)*16
            for ch in range(first, self.channels+1):
                if ch == first or self.snr_strategy == 2:
                    snr = (coarse + g.get(4, 'fsnroffst'))*4
                self.snr_offset[ch] = snr
        if self.gain_syntax and g.get(1, 'fgaincode', blk):
            for ch in range(first, self.channels+1):
                gain = ac3.T['fast_gain'][g.get(3, 'fgaincod')]
                if self.fast_gain[ch] != gain:
                    stages[ch] = max(stages[ch], 2)
                self.fast_gain[ch] = gain
        elif blk == 0:
            for ch in range(first, self.channels+1):
                self.fast_gain[ch] = 640
        if self.typ == 0 and g.get(1, 'convsnroffste'):
            g.get(10, 'convsnroffst')


def decode(data, ffmpeg_vq4=False):
    decoder = Decoder(ffmpeg_vq4=ffmpeg_vq4)
    out = None
    for frame in frames(data):
        channels = decoder.frame(frame)
        if out is None:
            out = [[] for _ in channels]
        for ch, samples in enumerate(channels):
            out[ch].extend(samples)
    return out, decoder
