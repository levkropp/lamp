"""Test-only AC-3 (ATSC A/52) decoder model.

Mirrors FFmpeg 6.1's float AC-3 decoder, the reference for tests/verify-ac3.py:
24-bit fixed-point mantissas shifted by their exponents, coupling and
rematrixing in integers, coefficients scaled to floats with the dynamic range
gain, then a half-length IMDCT, KBD windowing and overlap. Dither noise comes
from FFmpeg's lagged Fibonacci generator, and blocks that fail to decode
repeat the previous block, as FFmpeg's error concealment does. The tables are
those of tests/generate-ac3-tables.py. The model also serves the stream writer
(tests/ac3_vectors.py), which runs the same bit allocation.
"""
import cmath
import importlib.util
import math
from pathlib import Path
import struct

_SPEC = importlib.util.spec_from_file_location('generate_ac3_tables', Path(__file__).with_name('generate-ac3-tables.py'))
_GEN = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_GEN)
T = _GEN.tables()

CPL = 0
EXP_REUSE, EXP_D15, EXP_D25, EXP_D45 = 0, 1, 2, 3
DBA_REUSE, DBA_NEW, DBA_NONE, DBA_RESERVED = 0, 1, 2, 3
CHANNELS = [2, 1, 2, 3, 3, 4, 4, 5]                      # full-bandwidth channels by acmod
RATES = [48000, 44100, 32000]
REMATRIX_BANDS = [13, 25, 37, 61, 253]


class DecodeError(Exception):
    pass


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


class Reader:
    """MSB-first bit reader. Reads carry a label and context, which the stream
    writer (tests/ac3_vectors.py) uses to choose valid values."""

    def __init__(self, data, position=0):
        self.data = data
        self.pos = position                            # bit position

    def get(self, n, label=None, *context):
        if n == 0:
            return 0
        value = 0
        for _ in range(n):
            byte = self.pos >> 3
            bit = (self.data[byte] >> (7 - (self.pos & 7))) & 1 if byte < len(self.data) else 0
            value = (value << 1) | bit
            self.pos += 1
        return value

    def signed(self, n, label=None):
        v = self.get(n, label)
        return v - (1 << n) if v >> (n - 1) else v

    def mark(self, event, *context):
        pass


def crc16(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xffff) ^ T['crc'][((c >> 8) ^ b) & 0xff]
    return c


def header(data):
    """Sync information and the start of the bit stream information:
    a dict, or None when the data does not start with a valid AC-3 frame."""
    if len(data) < 7 or data[0] != 0x0b or data[1] != 0x77:
        return None
    fscod, frmsizecod = data[4] >> 6, data[4] & 0x3f
    bsid, acmod = data[5] >> 3, data[6] >> 5
    if fscod == 3 or frmsizecod > 37 or bsid > 10:
        return None
    return dict(fscod=fscod, frmsizecod=frmsizecod, bsid=bsid, acmod=acmod,
                bytes=T['frame_words'][fscod * 38 + frmsizecod] * 2, shift=max(bsid, 8) - 8)


# Bit allocation (A/52 7.2, FFmpeg ac3.c).

def calc_psd(exps, start, end):
    psd = [0] * 256
    band_psd = [0] * 50
    for b in range(start, end):
        psd[b] = 3072 - (exps[b] << 7)
    b = start
    band = T['bin_band'][start]
    while True:
        v = psd[b]
        b += 1
        band_end = min(T['band_start'][band + 1], end)
        while b < band_end:
            m = max(v, psd[b])
            adr = min(m - ((v + psd[b] + 1) >> 1), 255)
            v = m + T['latab'][adr]
            b += 1
        band_psd[band] = v
        band += 1
        if end <= T['band_start'][band]:
            break
    return psd, band_psd


def _lowcomp1(a, b0, b1, c):
    if b0 + 256 == b1:
        return c
    if b0 > b1:
        return max(a - 64, 0)
    return a


def _lowcomp(a, b0, b1, band):
    if band < 7:
        return _lowcomp1(a, b0, b1, 384)
    if band < 20:
        return _lowcomp1(a, b0, b1, 320)
    return max(a - 128, 0)


def calc_mask(p, band_psd, start, end, fast_gain, is_lfe, dba_mode, dba):
    """p: slow_decay, fast_decay, slow_gain, db_per_bit, sr_shift, sr_code,
    cpl_fast_leak, cpl_slow_leak. dba: (offsets, lengths, values)."""
    if end <= 0:
        raise DecodeError('empty bit allocation range')
    excite = [0] * 50
    mask = [0] * 50
    band_start = T['bin_band'][start]
    band_end = T['bin_band'][end - 1] + 1
    if band_start == 0:
        lowcomp = _lowcomp1(0, band_psd[0], band_psd[1], 384)
        excite[0] = band_psd[0] - fast_gain - lowcomp
        lowcomp = _lowcomp1(lowcomp, band_psd[1], band_psd[2], 384)
        excite[1] = band_psd[1] - fast_gain - lowcomp
        begin = 7
        for band in range(2, 7):
            if not (is_lfe and band == 6):
                lowcomp = _lowcomp1(lowcomp, band_psd[band], band_psd[band + 1], 384)
            fastleak = band_psd[band] - fast_gain
            slowleak = band_psd[band] - p['slow_gain']
            excite[band] = fastleak - lowcomp
            if not (is_lfe and band == 6):
                if band_psd[band] <= band_psd[band + 1]:
                    begin = band + 1
                    break
        for band in range(begin, min(band_end, 22)):
            if not (is_lfe and band == 6):
                lowcomp = _lowcomp(lowcomp, band_psd[band], band_psd[band + 1], band)
            fastleak = max(fastleak - p['fast_decay'], band_psd[band] - fast_gain)
            slowleak = max(slowleak - p['slow_decay'], band_psd[band] - p['slow_gain'])
            excite[band] = max(fastleak - lowcomp, slowleak)
        begin = 22
    else:
        begin = band_start
        fastleak = (p['cpl_fast_leak'] << 8) + 768
        slowleak = (p['cpl_slow_leak'] << 8) + 768
    for band in range(begin, band_end):
        fastleak = max(fastleak - p['fast_decay'], band_psd[band] - fast_gain)
        slowleak = max(slowleak - p['slow_decay'], band_psd[band] - p['slow_gain'])
        excite[band] = max(fastleak, slowleak)
    for band in range(band_start, band_end):
        tmp = p['db_per_bit'] - band_psd[band]
        if tmp > 0:
            excite[band] += tmp >> 2
        mask[band] = max(T['hth'][p['sr_code'] * 50 + (band >> p['sr_shift'])], excite[band])
    if dba_mode in (DBA_REUSE, DBA_NEW):
        offsets, lengths, values = dba
        if len(offsets) > 8:
            raise DecodeError('too many delta bit allocation segments')
        band = band_start
        for seg in range(len(offsets)):
            band += offsets[seg]
            if band >= 50 or lengths[seg] > 50 - band:
                raise DecodeError('delta bit allocation out of range')
            delta = (values[seg] - 3 if values[seg] >= 4 else values[seg] - 4) * 128
            for _ in range(lengths[seg]):
                mask[band] += delta
                band += 1
    return mask


def calc_bap(mask, psd, start, end, snr_offset, floor):
    bap = [0] * 256
    if snr_offset == -960:
        return bap
    b = start
    band = T['bin_band'][start]
    while True:
        m = (max(mask[band] - snr_offset - floor, 0) & 0x1fe0) + floor
        band += 1
        band_end = min(T['band_start'][band], end)
        while b < band_end:
            address = min(max((psd[b] - m) >> 5, 0), 63)
            bap[b] = T['baptab'][address]
            b += 1
        if end <= band_end:
            break
    return bap


def _dba_fits(dba, band):
    """Whether delta segments stay inside the 50 bands from band."""
    for offset, length in zip(dba[0], dba[1]):
        band += offset
        if band >= 50 or length > 50 - band:
            return False
        band += length
    return True


# Transform.

def dct4(x):
    """DCT-IV: Y[k] = sum x[n] cos(pi/M (n + 1/2)(k + 1/2)), by an M/2-point FFT."""
    m = len(x)
    h = m // 2
    z = [complex(x[2 * n], x[m - 1 - 2 * n]) * cmath.exp(-1j * math.pi * (n + 0.25) / m) for n in range(h)]
    z = _fft(z)
    y = [0.0] * m
    for k in range(h):
        c = z[k] * cmath.exp(-1j * math.pi * k / m)
        y[2 * k] = c.real
        y[m - 1 - 2 * k] = -c.imag
    return y


def _fft(a):
    n = len(a)
    if n == 1:
        return a
    even, odd = _fft(a[0::2]), _fft(a[1::2])
    out = [0j] * n
    for k in range(n // 2):
        t = cmath.exp(-2j * math.pi * k / n) * odd[k]
        out[k] = even[k] + t
        out[k + n // 2] = even[k] - t
    return out


def imdct_half(x):
    """FFmpeg's inverse MDCT with scale 1: the middle half of the N = 2M
    output, which is the DCT-IV reversed."""
    y = dct4(x)
    m = len(x)
    return [y[m - 1 - j] for j in range(m)]


def window_overlap(delay, cur, window):
    """FFmpeg vector_fmul_window with 128-sample halves -> 256 samples."""
    out = [0.0] * 256
    for k in range(128):
        s0, s1 = delay[k], cur[127 - k]
        wi, wj = window[k], window[255 - k]
        out[k] = s0 * wj - s1 * wi
        out[255 - k] = s0 * wi + s1 * wj
    return out


class Decoder:
    def __init__(self, check_crc=True):
        self.enhanced = False
        self.check_crc = check_crc
        self.lfg = list(T['lfg'])
        self.lfg_index = 0
        self.delay = [[0.0] * 128 for _ in range(6)]
        self.last = None                                # last block's output, for concealment
        self.dexps = [[0] * 256 for _ in range(7)]
        self.start_freq = [0] * 7
        self.end_freq = [0] * 7
        self.exp_strategy = [0] * 7
        self.num_exp_groups = [0] * 7
        self.cpl_in_use = 0
        self.channel_in_cpl = [0] * 7
        self.first_cpl_coords = [1] * 7
        self.phase_flags_in_use = 0
        self.phase_flags = [0] * 18
        self.cpl_coords = [[0] * 18 for _ in range(7)]
        self.cpl_band_struct = [0] * 22
        self.num_cpl_bands = 0
        self.cpl_band_sizes = [0] * 18
        self.num_rematrixing_bands = 0
        self.rematrixing_flags = [0] * 4
        self.params = dict(slow_decay=0, fast_decay=0, slow_gain=0, db_per_bit=0, floor=0,
                           cpl_fast_leak=0, cpl_slow_leak=0, sr_shift=0, sr_code=0)
        self.snr_offset = [0] * 7
        self.fast_gain = [0] * 7
        self.dba_mode = [DBA_NONE] * 7
        self.dba = [([], [], []) for _ in range(7)]
        self.dynamic_range = [1.0, 1.0]
        self.block_switch = [0] * 7
        self.dither_flag = [0] * 7
        self.bap = [[0] * 256 for _ in range(7)]
        self.psd = [[0] * 256 for _ in range(7)]
        self.band_psd = [[0] * 50 for _ in range(7)]
        self.mask = [[0] * 50 for _ in range(7)]
        self.used = set()                               # coverage tags

    def dither(self):
        i = self.lfg_index
        v = (self.lfg[(i - 24) & 63] + self.lfg[(i - 55) & 63]) & 0xffffffff
        self.lfg[i & 63] = v
        self.lfg_index = i + 1
        return (((v >> 8) * 181) >> 8) - 5931008

    def frame(self, data):
        """One frame -> list of channels (AC-3 order, LFE last) of 1536 floats,
        or None when FFmpeg would drop the frame."""
        h = header(data)
        if h is None or len(data) < h['bytes']:
            return None
        data = data[:h['bytes']]
        err = self.check_crc and crc16(data[2:]) != 0
        if err:
            self.used.add('CRC error')
        return self.decode_frame(Reader(data, 40), h, err)

    def decode_frame(self, g, h, err=False, strict=False):
        """Bit stream information and six audio blocks from reader g (after the
        sync information). strict raises on errors instead of concealing."""
        bsid = g.get(5, 'bsid')
        g.get(3, 'bsmod')
        acmod = g.get(3, 'acmod')
        nfchans = CHANNELS[acmod]
        if acmod == 2:
            g.get(2, 'dsurmod')
        else:
            if acmod & 1 and acmod != 1:
                g.get(2, 'cmixlev')
            if acmod & 4:
                g.get(2, 'surmixlev')
        lfe = g.get(1, 'lfeon')
        self.acmod, self.nfchans, self.lfe = acmod, nfchans, lfe
        self.channels = nfchans + lfe
        self.lfe_ch = nfchans + 1 if lfe else -1
        self.params['sr_shift'] = h['shift']
        self.params['sr_code'] = h['fscod']
        self.used.add(f'acmod {acmod}' + (' with LFE' if lfe else ''))
        if h['shift']:
            self.used.add(f'bsid {bsid}')
        for i in range(2 if acmod == 0 else 1):
            g.get(5, 'dialnorm')
            if g.get(1, 'compre'):
                g.get(8, 'compr')
            if g.get(1, 'langcode'):
                g.get(8, 'langcod')
            if g.get(1, 'audprodie'):
                g.get(7, 'audprod')
        g.get(2, 'copyright')
        if bsid != 6:
            if g.get(1, 'timecod1e'):
                g.get(14, 'timecod1')
            if g.get(1, 'timecod2e'):
                g.get(14, 'timecod2')
        else:
            self.used.add('alternate bit stream syntax')
            if g.get(1, 'xbsi1e'):
                g.get(14, 'xbsi1')
            if g.get(1, 'xbsi2e'):
                g.get(14, 'xbsi2')
        if g.get(1, 'addbsie'):
            n = g.get(6, 'addbsil')
            g.get(8 * (n + 1), 'addbsi')
            self.used.add('additional bit stream information')
        if lfe:
            self.start_freq[self.lfe_ch] = 0
            self.end_freq[self.lfe_ch] = 7
            self.num_exp_groups[self.lfe_ch] = 2
            self.channel_in_cpl[self.lfe_ch] = 0
        out = [[] for _ in range(self.channels)]
        self.dba_sent = set()
        for blk in range(6):
            g.mark('block', blk)
            if not err:
                try:
                    block = self.block(g, blk)
                except (DecodeError, IndexError):
                    if strict:
                        raise
                    err = True
                    self.used.add('block error')
            if err:
                block = self.last if self.last is not None and len(self.last) == self.channels else \
                    [[0.0] * 256 for _ in range(self.channels)]
            for ch in range(self.channels):
                out[ch].extend(block[ch])
            self.last = block
        g.mark('end')
        return out

    def exponents(self, g, strategy, ngrps, absexp, target, start):
        group = strategy + (strategy == EXP_D45)
        dexp = []
        prev = absexp
        for _ in range(ngrps):
            acc = g.get(7, 'exp', prev)
            if acc >= 125:
                raise DecodeError('exponent group out of range')
            dexp += [acc // 25, acc % 25 // 5, acc % 5]
            prev += acc // 25 + acc % 25 // 5 + acc % 5 - 6
        prev = absexp
        j = start
        for d in dexp:
            prev += d - 2
            if not 0 <= prev <= 24:
                raise DecodeError('exponent out of range')
            for _ in range(group):
                target[j] = prev
                j += 1

    def block(self, g, blk):
        nf, acmod = self.nfchans, self.acmod
        stages = [0] * 7
        for ch in range(1, nf + 1):
            self.block_switch[ch] = g.get(1, 'blksw', blk, ch) if not self.enhanced or self.switch_syntax else 0
            if self.block_switch[ch]:
                self.used.add('short blocks')
        if nf > 1 and len(set(self.block_switch[1:nf + 1])) > 1:
            self.used.add('mixed transforms')
        for ch in range(1, nf + 1):
            self.dither_flag[ch] = g.get(1, 'dithflag') if not self.enhanced or self.dither_syntax else 1
            self.used.add(f'dither {self.dither_flag[ch]}')
        for i in (1, 0) if acmod == 0 else (0,):
            if g.get(1, 'dynrnge'):
                self.dynamic_range[i] = T['dynrng'][g.get(8, 'dynrng')]
                self.used.add('dynamic range' + (' dual mono' if acmod == 0 else ''))
            elif blk == 0:
                self.dynamic_range[i] = 1.0
        # Coupling strategy.
        if self.enhanced:
            if (blk == 0 or g.get(1, 'spxstre')) and g.get(1, 'spxinu'):
                raise DecodeError('spectral extension unsupported')
            new = self.cplstre[blk] if acmod > 1 else 1
        else:
            new = g.get(1, 'cplstre', blk)
        if new:
            stages = [3] * 7
            self.cpl_in_use = self.cplinu[blk] if self.enhanced else g.get(1, 'cplinu', acmod)
            if self.cpl_in_use:
                if acmod < 2:
                    raise DecodeError('coupling in mono or dual mono')
                if self.enhanced and g.get(1, 'ecplinu'):
                    raise DecodeError('enhanced coupling unsupported')
                for ch in range(1, nf + 1):
                    self.channel_in_cpl[ch] = 1 if self.enhanced and acmod == 2 else \
                        g.get(1, 'chincpl', ch, nf, sum(self.channel_in_cpl[1:ch]))
                if acmod == 2:
                    self.phase_flags_in_use = g.get(1, 'phsflginu')
                begin = g.get(4, 'cplbegf')
                end = g.get(4, 'cplendf', begin) + 3
                if begin >= end:
                    raise DecodeError('invalid coupling range')
                self.start_freq[CPL] = begin * 12 + 37
                self.end_freq[CPL] = end * 12 + 37
                if blk == 0:
                    self.cpl_band_struct = list(self.default_cpl_bands) + [0]*4 if self.enhanced else [0] * 22
                n = end - begin
                if not self.enhanced or g.get(1, 'cplbndstrce'):
                    for s in range(n - 1):
                        self.cpl_band_struct[begin + 1 + s] = g.get(1, 'cplbndstrc')
                sizes = [12]
                for s in range(1, n):
                    if self.cpl_band_struct[begin + s]:
                        sizes[-1] += 12
                    else:
                        sizes.append(12)
                self.num_cpl_bands = len(sizes)
                self.cpl_band_sizes = sizes
                self.used.add('coupling')
                if len(sizes) < n:
                    self.used.add('coupling band structure')
                if sum(self.channel_in_cpl[1:nf + 1]) < nf:
                    self.used.add('partial coupling')
            else:
                for ch in range(1, nf + 1):
                    self.channel_in_cpl[ch] = 0
                    self.first_cpl_coords[ch] = 1
                self.phase_flags_in_use = 0
                self.first_cpl_leak = self.enhanced
        elif blk == 0:
            raise DecodeError('no coupling strategy in block 0')
        cpl = self.cpl_in_use
        if cpl:
            exist = False
            for ch in range(1, nf + 1):
                if self.channel_in_cpl[ch]:
                    if (self.enhanced and self.first_cpl_coords[ch]) or g.get(1, 'cplcoe', blk, new):
                        self.first_cpl_coords[ch] = 0
                        exist = True
                        master = 3 * g.get(2, 'mstrcplco')
                        for bnd in range(self.num_cpl_bands):
                            e, m = g.get(4, 'cplcoexp'), g.get(4, 'cplcomant')
                            c = m << 22 if e == 15 else (m + 16) << 21
                            self.cpl_coords[ch][bnd] = c >> (e + master)
                    elif blk == 0:
                        raise DecodeError('no coupling coordinates in block 0')
                else:
                    self.first_cpl_coords[ch] = 1
            if acmod == 2 and exist:
                for bnd in range(self.num_cpl_bands):
                    self.phase_flags[bnd] = g.get(1, 'phsflg') if self.phase_flags_in_use else 0
                    if self.phase_flags[bnd]:
                        self.used.add('phase flags')
        if acmod == 2:
            if (self.enhanced and blk == 0) or g.get(1, 'rematstr', blk):
                self.num_rematrixing_bands = 4
                if cpl and self.start_freq[CPL] <= 61:
                    self.num_rematrixing_bands -= 1 + (self.start_freq[CPL] == 37)
                for bnd in range(self.num_rematrixing_bands):
                    self.rematrixing_flags[bnd] = g.get(1, 'rematflg')
                    if self.rematrixing_flags[bnd]:
                        self.used.add(f'rematrixing {self.num_rematrixing_bands} bands')
            elif blk == 0:
                self.num_rematrixing_bands = 0
        for ch in range(0 if cpl else 1, self.channels + 1):
            self.exp_strategy[ch] = self.frame_expstr[blk][ch] if self.enhanced else \
                g.get(1 if ch == self.lfe_ch else 2, 'expstr', blk, new)
            if blk == 0 and self.exp_strategy[ch] == 0:
                raise DecodeError('reuse in first block')
            if self.exp_strategy[ch] != EXP_REUSE:
                stages[ch] = 3
            self.used.add(f'exponent strategy {self.exp_strategy[ch]}')
        for ch in range(1, nf + 1):
            self.start_freq[ch] = 0
            if self.exp_strategy[ch] != EXP_REUSE:
                prev = self.end_freq[ch]
                if self.channel_in_cpl[ch]:
                    self.end_freq[ch] = self.start_freq[CPL]
                else:
                    code = g.get(6, 'chbwcod')
                    if code > 60:
                        raise DecodeError('bandwidth code above 60')
                    self.end_freq[ch] = code * 3 + 73
                size = 3 << (self.exp_strategy[ch] - 1)
                self.num_exp_groups[ch] = (self.end_freq[ch] + size - 4) // size
                if blk > 0 and self.end_freq[ch] != prev:
                    stages = [3] * 7
                    self.used.add('bandwidth change')
        if cpl and self.exp_strategy[CPL] != EXP_REUSE:
            self.num_exp_groups[CPL] = (self.end_freq[CPL] - self.start_freq[CPL]) // (3 << (self.exp_strategy[CPL] - 1))
        for ch in range(0 if cpl else 1, self.channels + 1):
            if self.exp_strategy[ch] != EXP_REUSE:
                absexp = g.get(4, 'absexp') << (1 if ch == CPL else 0)
                self.dexps[ch][0] = absexp
                self.exponents(g, self.exp_strategy[ch], self.num_exp_groups[ch], absexp, self.dexps[ch],
                               self.start_freq[ch] + (1 if ch else 0))
                if ch != CPL and ch != self.lfe_ch:
                    g.get(2, 'gainrng')
        p = self.params
        if (not self.enhanced or self.ba_syntax) and g.get(1, 'baie', blk):
            p['slow_decay'] = T['slow_decay'][g.get(2, 'sdcycod')] >> p['sr_shift']
            p['fast_decay'] = T['fast_decay'][g.get(2, 'fdcycod')] >> p['sr_shift']
            p['slow_gain'] = T['slow_gain'][g.get(2, 'sgaincod')]
            p['db_per_bit'] = T['db_per_bit'][g.get(2, 'dbpbcod')]
            p['floor'] = T['floor'][g.get(3, 'floorcod')]
            if p['floor'] >= 0x8000:
                p['floor'] -= 0x10000
            for ch in range(0 if cpl else 1, self.channels + 1):
                stages[ch] = max(stages[ch], 2)
        elif blk == 0 and (not self.enhanced or self.ba_syntax):
            raise DecodeError('no bit allocation information in block 0')
        if self.enhanced:
            self.block_snr(g, blk, stages)
        else:
            if g.get(1, 'snroffste', blk if blk and not (new and cpl) else 0):
                csnr = (g.get(6, 'csnroffst') - 15) << 4
                for ch in range(0 if cpl else 1, self.channels + 1):
                    snr = (csnr + g.get(4, 'fsnroffst')) << 2
                    if blk and self.snr_offset[ch] != snr:
                        stages[ch] = max(stages[ch], 1)
                    self.snr_offset[ch] = snr
                    if snr == -960:
                        self.used.add('snr offset -960')
                    prev = self.fast_gain[ch]
                    self.fast_gain[ch] = T['fast_gain'][g.get(3, 'fgaincod')]
                    if blk and prev != self.fast_gain[ch]:
                        stages[ch] = max(stages[ch], 2)
            elif blk == 0:
                raise DecodeError('no SNR offsets in block 0')
        if cpl:
            if (self.enhanced and self.first_cpl_leak) or g.get(1, 'cplleake', blk, new):
                fl, sl = g.get(3, 'cplfleak'), g.get(3, 'cplsleak')
                if blk and (fl != p['cpl_fast_leak'] or sl != p['cpl_slow_leak']):
                    stages[CPL] = max(stages[CPL], 2)
                p['cpl_fast_leak'], p['cpl_slow_leak'] = fl, sl
            elif blk == 0 and not self.enhanced:
                raise DecodeError('no coupling leak information in block 0')
            self.first_cpl_leak = False
        stale = any(self.dba_mode[ch] in (DBA_REUSE, DBA_NEW) and
                    not _dba_fits(self.dba[ch], T['bin_band'][self.start_freq[ch]])
                    for ch in range(0 if cpl else 1, nf + 1))
        if (not self.enhanced or self.dba_syntax) and g.get(1, 'deltbaie', stale or (new and cpl)):
            for ch in range(0 if cpl else 1, nf + 1):
                fits = _dba_fits(self.dba[ch], T['bin_band'][self.start_freq[ch]]) and not (ch == CPL and new) \
                    and ch in self.dba_sent                 # the writer reuses only this frame's segments
                self.dba_mode[ch] = g.get(2, 'deltbae', blk, fits)
                if self.dba_mode[ch] == DBA_RESERVED:
                    raise DecodeError('reserved delta bit allocation mode')
                stages[ch] = max(stages[ch], 2)
                if self.dba_mode[ch] == DBA_REUSE:
                    self.used.add('delta bit allocation reuse')
            for ch in range(0 if cpl else 1, nf + 1):
                if self.dba_mode[ch] == DBA_NEW:
                    n = g.get(3, 'deltnseg', T['bin_band'][self.start_freq[ch]]) + 1
                    offsets, lengths, values = [], [], []
                    for _ in range(n):
                        offsets.append(g.get(5, 'deltoffst'))
                        lengths.append(g.get(4, 'deltlen'))
                        values.append(g.get(3, 'deltba'))
                    self.dba[ch] = (offsets, lengths, values)
                    self.dba_sent.add(ch)
                    stages[ch] = max(stages[ch], 2)
                    self.used.add('delta bit allocation' + (' coupling' if ch == CPL else ''))
        elif blk == 0:
            for ch in range(7):
                self.dba_mode[ch] = DBA_NONE
        for ch in range(0 if cpl else 1, self.channels + 1):
            if stages[ch] > 2:
                self.psd[ch], self.band_psd[ch] = calc_psd(self.dexps[ch], self.start_freq[ch], self.end_freq[ch])
            if stages[ch] > 1:
                self.mask[ch] = calc_mask(p, self.band_psd[ch], self.start_freq[ch], self.end_freq[ch],
                                          self.fast_gain[ch], ch == self.lfe_ch, self.dba_mode[ch], self.dba[ch])
            if stages[ch] > 0:
                self.bap[ch] = calc_bap(self.mask[ch], self.psd[ch], self.start_freq[ch], self.end_freq[ch],
                                        self.snr_offset[ch], p['floor'])
        g.mark('mantissas', blk)
        if (not self.enhanced or self.skip_syntax) and g.get(1, 'skiple'):
            n = g.get(9, 'skipl')
            g.get(8 * n, 'skip')
            self.used.add('skip field')
        # Mantissas.
        fixed = [[0] * 256 for _ in range(7)]
        groups = {'b1': [], 'b2': [], 'b4': []}
        got_cpl = False
        for ch in range(1, self.channels + 1):
            self.mantissas(g, ch, fixed[ch], groups)
            if self.channel_in_cpl[ch]:
                if not got_cpl:
                    self.mantissas(g, CPL, fixed[CPL], groups)
                    self.uncouple(fixed)
                    got_cpl = True
                end = self.end_freq[CPL]
            else:
                end = self.end_freq[ch]
            for b in range(end, 256):
                fixed[ch][b] = 0
        for ch in range(1, nf + 1):
            if not self.dither_flag[ch] and self.channel_in_cpl[ch]:
                for b in range(self.start_freq[CPL], self.end_freq[CPL]):
                    if not self.bap[CPL][b]:
                        fixed[ch][b] = 0
        if acmod == 2:
            end = min(self.end_freq[1], self.end_freq[2])
            for bnd in range(self.num_rematrixing_bands):
                if self.rematrixing_flags[bnd]:
                    for b in range(REMATRIX_BANDS[bnd], min(end, REMATRIX_BANDS[bnd + 1])):
                        t0 = fixed[1][b]
                        fixed[1][b] = _i32(t0 + fixed[2][b])
                        fixed[2][b] = _i32(t0 - fixed[2][b])
        output = []
        for ch in range(1, self.channels + 1):
            audio = 2 - ch if acmod == 0 and ch <= 2 else 0
            gain = f32(self.dynamic_range[audio] * (1.0 / 4194304.0))
            coeffs = [f32(f32(float(v)) * gain) for v in fixed[ch]]
            delay = self.delay[ch - 1]
            if self.block_switch[ch] and ch != self.lfe_ch:
                first = imdct_half(coeffs[0::2])
                out = window_overlap(delay, first, T['window'])
                self.delay[ch - 1] = imdct_half(coeffs[1::2])
            else:
                half = imdct_half(coeffs)
                out = window_overlap(delay, half[:128], T['window'])
                self.delay[ch - 1] = half[128:]
            output.append(out)
        return output

    def mantissas(self, g, ch, coeffs, groups):
        exps, baps = self.dexps[ch], self.bap[ch]
        dither = ch == CPL or self.dither_flag[ch]
        for b in range(self.start_freq[ch], self.end_freq[ch]):
            bap = baps[b]
            self.used.add(f'bap {bap}')
            if bap == 0:
                mant = self.dither() if dither else 0
            elif bap == 1:
                if not groups['b1']:
                    groups['b1'] = list(T['b1'][g.get(5, 'b1')])
                mant = groups['b1'].pop(0)
            elif bap == 2:
                if not groups['b2']:
                    groups['b2'] = list(T['b2'][g.get(7, 'b2')])
                mant = groups['b2'].pop(0)
            elif bap == 3:
                mant = T['b3'][g.get(3, 'b3')]
            elif bap == 4:
                if not groups['b4']:
                    groups['b4'] = list(T['b4'][g.get(7, 'b4')])
                mant = groups['b4'].pop(0)
            elif bap == 5:
                mant = T['b5'][g.get(4, 'b5')]
            else:
                n = T['quant_bits'][bap]
                mant = _i32(g.signed(n, 'mant') << (24 - n))
                if bap == 15:
                    self.used.add('bap 15')
            coeffs[b] = mant >> exps[b]

    def uncouple(self, fixed):
        b = self.start_freq[CPL]
        for band in range(self.num_cpl_bands):
            start, end = b, b + self.cpl_band_sizes[band]
            for ch in range(1, self.nfchans + 1):
                if self.channel_in_cpl[ch]:
                    coord = _i32(self.cpl_coords[ch][band] << 5)
                    for k in range(start, end):
                        fixed[ch][k] = (_i32(fixed[CPL][k] << 4) * coord) >> 32
                    if ch == 2 and self.phase_flags[band]:
                        for k in range(start, end):
                            fixed[ch][k] = -fixed[ch][k]
            b = end


def _i32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v


def frames(data):
    """Split an AC-3 elementary stream into frames."""
    out, pos = [], 0
    while pos + 7 <= len(data):
        h = header(data[pos:pos + 7])
        if h is None:
            break
        out.append(data[pos:pos + h['bytes']])
        pos += h['bytes']
    return out


def decode(data, check_crc=True):
    """Whole stream -> (channels, floats per channel)."""
    decoder = Decoder(check_crc)
    channels = None
    for f in frames(data):
        out = decoder.frame(f)
        if out is None:
            continue
        if channels is None:
            channels = [[] for _ in out]
        for ch, samples in enumerate(out):
            channels[ch].extend(samples)
    return channels, decoder
