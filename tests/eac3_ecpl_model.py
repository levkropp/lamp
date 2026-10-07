"""Test-only full-stream ECPL reference, literal ATSC A/52:2018 Annex E.

Parse all frames first, then synthesize from adjacent raw C0 spectra. This
deliberately has no packet lookahead or assembly snapshot implementation.
The published carrier normalization is retained (see docs/eac3.md).
"""
import cmath
import copy
import importlib.util
import math
from pathlib import Path
import ac3_model as ac3
import eac3_model as conventional

spec = importlib.util.spec_from_file_location('ecpl_tables', Path(__file__).with_name('generate-eac3-ecpl-tables.py'))
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
EDGES, AMP, ANGLE, CHAOS, _, _, _, PROJECTION, DEFAULT_BANDS = gen.tables()
ZERO = [0.0]*256


def xorshift(state):
    state ^= (state << 13) & 0xffffffff
    state ^= state >> 17
    state ^= (state << 5) & 0xffffffff
    return state


def random_value(state):
    return ac3.f32(ac3.f32(float(ac3._i32(state)))*2**-31)


def static_random():
    state, values = 0x6d2b79f5, []
    for _ in range(8*256):
        state = xorshift(state)
        values.append(random_value(state))
    return [values[i*256:(i+1)*256] for i in range(8)]


STATIC_RANDOM = static_random()


def carrier(previous, current, following):
    times = []
    for spectrum in (previous, current, following):
        y = ac3.dct4(spectrum)
        time = [-y[n+128] for n in range(128)] + [y[383-n] for n in range(128,256)]
        time += [y[383-n] for n in range(256,384)] + [y[n-384] for n in range(384,512)]
        window = ac3.T['window'] + ac3.T['window'][::-1]
        times.append([v*w for v,w in zip(time,window)])
    values = []
    for n in range(512):
        pcm = times[0][n+256]+times[1][n] if n<256 else times[1][n]+times[2][n-256]
        values.append(pcm*window[n]*cmath.exp(-1j*math.pi*n/512))
    return [v/512 for v in ac3._fft(values)[:256]]


def wrap(value):
    while value > 1: value -= 2
    while value < -1: value += 2
    return value


class Decoder(conventional.Decoder):
    synthesis_fields = ('acmod','nfchans','channels','lfe_ch','dynamic_range','block_switch',
        'channel_in_cpl','ecpl_in_use','ecpl_edges','ecpl_amp','ecpl_angle','ecpl_chaos',
        'ecpl_flags','channel_in_spx','spx_copy','spx_start','spx_end','spx_sizes',
        'spx_noise','spx_signal','spx_atten')

    def __init__(self, check_crc=True):
        super().__init__(check_crc)
        self.records = []
        self.ecpl_edges = [13,25]
        self.ecpl_amp = [[0]*22 for _ in range(7)]
        self.ecpl_angle = [[0]*22 for _ in range(7)]
        self.ecpl_chaos = [[0]*22 for _ in range(7)]
        self.ecpl_flags = [0]*7
        self.spx_copy, self.spx_start, self.spx_end, self.spx_sizes = 0,0,0,[]
        self.reserved_noise = None
        self.trans_seed = 0xa511e9b3

    def ecpl_reset_bands(self):
        self.ecpl_struct = DEFAULT_BANDS[:]

    def ecpl_strategy(self, g, blk):
        self.phase_flags_in_use = 0
        code = g.get(4, 'ecplbegf', blk)
        begin = 2*code if code<3 else code+2 if code<13 else 2*code-10
        end = EDGES.index(self.spx_start) if self.spx_in_use else g.get(4, 'ecplendf', begin)+7
        if begin >= end: raise ac3.DecodeError('invalid enhanced coupling range')
        self.start_freq[0], self.end_freq[0] = EDGES[begin], EDGES[end]
        if g.get(1, 'ecplbndstrce', blk):
            for s in range(max(9,begin+1),end): self.ecpl_struct[s] = g.get(1, 'ecplbndstrc', s)
        edges = [EDGES[begin]]
        for s in range(begin,end):
            if s == begin or not self.ecpl_struct[s]: edges.append(EDGES[s+1])
            else: edges[-1] = EDGES[s+1]
        self.ecpl_edges = edges
        self.num_cpl_bands = len(edges)-1
        self.cpl_band_sizes = [b-a for a,b in zip(edges,edges[1:])]
        self.used.update({'enhanced coupling',f'ECPL begin {code}',f'ECPL end {end}'})

    def ecpl_coordinates(self, g, blk):
        interp = g.get(1, 'ecplangleintrp', blk)
        first = next(ch for ch in range(1,self.nfchans+1) if self.channel_in_cpl[ch])
        for ch in range(1,self.nfchans+1):
            if not self.channel_in_cpl[ch]:
                self.first_cpl_coords[ch] = 1
                continue
            fresh = self.first_cpl_coords[ch]
            amp = 1 if fresh else g.get(1, 'ecplparam1e', blk,ch)
            phase = ch != first and (1 if fresh else g.get(1, 'ecplparam2e', blk,ch))
            self.first_cpl_coords[ch] = 0
            for b in range(self.num_cpl_bands):
                if amp:
                    self.ecpl_amp[ch][b] = g.get(5, 'ecplamp', ch,b)
                    self.used.add(f'ECPL amplitude {self.ecpl_amp[ch][b]}')
            for b in range(self.num_cpl_bands):
                if phase:
                    self.ecpl_angle[ch][b] = g.get(6, 'ecplangle', ch,b)
                    self.ecpl_chaos[ch][b] = g.get(3, 'ecplchaos', ch,b)
                    self.used.update({f'ECPL angle {self.ecpl_angle[ch][b]}',f'ECPL chaos {self.ecpl_chaos[ch][b]}'})
            trans = g.get(1, 'ecpltrans', blk,ch) if ch != first else 0
            self.ecpl_flags[ch] = interp*4 + trans*2 + (ch == first)
            self.used.update({f'ECPL interpolation {interp}',f'ECPL transient {trans}',f'ECPL amplitude present {amp}',f'ECPL phase present {int(phase)}'})

    def synthesize_block(self, fixed):
        self.pending = (copy.deepcopy(fixed), {k:copy.deepcopy(getattr(self,k)) for k in self.synthesis_fields})
        return [[0.0]*256 for _ in range(self.channels)]

    def block_accepted(self, blk):
        fixed, params = self.pending
        spectrum = ZERO[:]
        if self.ecpl_in_use and any(self.channel_in_cpl[1:self.nfchans+1]):
            for k in range(self.start_freq[0],self.end_freq[0]):
                spectrum[k] = ac3.f32(ac3.f32(float(fixed[0][k]))*2**-22)
        count = sum(bool(self.channel_in_spx[ch]) for ch in range(1,self.nfchans+1))*(self.spx_end-self.spx_start) if self.spx_in_use else 0
        noise = [super(Decoder,self).random_word() for _ in range(count)]
        self.current_records[blk] = dict(fixed=fixed, params=params, spectrum=spectrum, noise=noise)

    def decode_frame(self, g, h, err=False, strict=False):
        self.current_records = [None]*h['blocks']
        out = super().decode_frame(g,h,err,strict)
        self.records.extend(self.current_records)
        return out

    def random_word(self):
        if self.reserved_noise is not None: return next(self.reserved_noise)
        return super().random_word()

    def ecpl_apply(self, ch, coeffs):
        edges, flags = self.ecpl_edges, self.ecpl_flags[ch]
        n = len(edges)-1
        amplitudes = [AMP[self.ecpl_amp[ch][b]] for b in range(n)]
        angles = [0 if flags&1 else ANGLE[self.ecpl_angle[ch][b]] for b in range(n)]
        chaos = [0 if flags&1 else CHAOS[self.ecpl_chaos[ch][b]] for b in range(n)]
        if not flags&3: amplitudes = [a*(1+.38*c) for a,c in zip(amplitudes,chaos)]
        centers = [(a+b-1)/2 for a,b in zip(edges,edges[1:])]
        phase = [0.0]*256
        for b in range(n): phase[edges[b]:edges[b+1]] = [angles[b]]*(edges[b+1]-edges[b])
        if flags&4 and n>1:
            for b in range(1,n):
                slope = wrap(angles[b]-angles[b-1])/(centers[b]-centers[b-1])
                start = edges[0] if b==1 else math.ceil(centers[b-1])
                end = edges[-1] if b==n-1 else math.ceil(centers[b])
                for k in range(start,end): phase[k] = wrap(angles[b-1]+slope*(k-centers[b-1]))
        noise = STATIC_RANDOM[ch]
        if flags&2:
            noise = ZERO[:]
            for a,b in zip(edges,edges[1:]):
                self.trans_seed = xorshift(self.trans_seed)
                noise[a:b] = [random_value(self.trans_seed)]*(b-a)
        for b in range(n):
            for k in range(edges[b],edges[b+1]):
                p = phase[k]+chaos[b]*noise[k]
                if p < -1: p += 2
                elif p >= 1: p -= 2
                z = self.carrier[k]*cmath.exp(1j*math.pi*p)
                coeffs[k] = ac3.f32(ac3.f32(-2*amplitudes[b]*(PROJECTION[k]*z.real+PROJECTION[255-k]*z.imag))*self.dynamic_range[0])

    def render(self, zero_frame_neighbors=False, frame_blocks=None):
        self.last = None
        self.delay = [[0.0]*128 for _ in range(6)]
        self.trans_seed = 0xa511e9b3
        out = [[] for _ in range(self.channels)]
        boundaries = set(frame_blocks or [])
        previous = ZERO
        for i,row in enumerate(self.records):
            if row is None:
                block = self.last or [[0.0]*256 for _ in out]
                previous = ZERO
            else:
                for k,v in row['params'].items(): setattr(self,k,v)
                following = self.records[i+1]['spectrum'] if i+1<len(self.records) and self.records[i+1] else ZERO
                if zero_frame_neighbors and i+1 in boundaries: following = ZERO
                if self.ecpl_in_use: self.carrier = carrier(previous,row['spectrum'],following)
                self.reserved_noise = iter(row['noise'])
                block = ac3.Decoder.synthesize_block(self,row['fixed'])
                if next(self.reserved_noise,None) is not None: raise ac3.DecodeError('unused reserved SPX noise')
                self.reserved_noise = None
                previous = row['spectrum']
            self.last = block
            for ch,samples in enumerate(block): out[ch].extend(samples)
        return out


def decode(data, zero_frame_neighbors=False):
    decoder = Decoder()
    boundaries = []
    for frame in conventional.frames(data):
        decoder.frame(frame)
        boundaries.append(len(decoder.records))
    return decoder.render(zero_frame_neighbors,boundaries), decoder
