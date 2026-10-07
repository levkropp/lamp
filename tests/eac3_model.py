"""Test-only E-AC-3 conventional-mantissa parser atop the AC-3 DSP model.

ATSC A/52:2018 Annex E syntax. Labels allow eac3_vectors to generate independent
coverage of fields that FFmpeg's encoder does not exercise. Unsupported AHT,
SPX and enhanced coupling are rejected; metadata does not override LAMP's
shared speaker weights. No reference decoder is linked into the player.
"""
import importlib.util
from pathlib import Path
import ac3_model as ac3

_spec = importlib.util.spec_from_file_location('generate_eac3', Path(__file__).with_name('generate-eac3-tables.py'))
_gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gen)
EXPSTR, DEFAULT_CPL = _gen.tables()


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

    def __init__(self, check_crc=True):
        super().__init__(check_crc)
        self.enhanced = True

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
        if ahte:
            for ch in range(sum(self.cplinu) != 6, self.channels + 1):
                if all(self.frame_expstr[b][ch] == 0 and (ch or not self.cplstre[b]) for b in range(1, 6)):
                    if g.get(1, 'ahtinu'):
                        raise ac3.DecodeError('AHT unsupported')
        if self.snr_strategy == 0:
            snr = ((g.get(6, 'frmcsnroffst') - 15)*16 + g.get(4, 'frmfsnroffst'))*4
            self.snr_offset = [snr]*7
        if transient:
            for ch in range(1, nf + 1):
                if g.get(1, 'chintransproc'):
                    g.get(18, 'transproc')
        if atten:
            for ch in range(1, nf + 1):
                if g.get(1, 'spxattencode'):
                    g.get(5, 'spxattencod')
        if blocks > 1 and g.get(1, 'blkstrtinfoe'):
            g.get((blocks-1)*(4+(h['bytes']-2).bit_length()-1), 'blkstrtinfo')
        self.first_cpl_coords, self.first_cpl_leak = [1]*7, True
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


def decode(data):
    decoder = Decoder()
    out = None
    for frame in frames(data):
        channels = decoder.frame(frame)
        if out is None:
            out = [[] for _ in channels]
        for ch, samples in enumerate(channels):
            out[ch].extend(samples)
    return out, decoder
