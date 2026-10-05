"""Test-only model of MPEG-4 parametric stereo (ISO/IEC 14496-3 8.6.4, HE-AAC v2).

PS.write() draws a valid ps_data payload, writes it and tracks the state a
decoder holds after reading it; PS.apply() renders the stereo pair from the
mono SBR QMF matrix: hybrid analysis (10/20 or 34 stereo bands), the
transient-aware all-pass decorrelator, mixing with IID/ICC and IPD/OPD
interpolated across envelopes, and hybrid synthesis. The structure follows
FFmpeg's decoder, which tests compare LAMP against. Tables come from
src/sbr_tables.inc (tests/generate-sbr-tables.py).
"""
from pathlib import Path
import struct

import sbr_model

ROOT = Path(__file__).resolve().parent.parent


def _tables():
    text = (ROOT / 'src' / 'sbr_tables.inc').read_text()

    def array(name, directive='.long'):
        body = text.split(name + ':\n', 1)[1]
        values = []
        for line in body.splitlines():
            line = line.strip()
            if line.startswith('.p2align'):
                continue
            if not line.startswith(directive):
                break
            values += [int(v, 0) for v in line[len(directive):].split(',')]
        if directive == '.long':
            return [struct.unpack('<f', struct.pack('<I', v))[0] for v in values]
        return values
    return {name: array(name) for name in ('ps_ha', 'ps_hb', 'ps_pd_re', 'ps_pd_im', 'ps_f20', 'ps_f34_12',
                                           'ps_f34_8', 'ps_f34_4', 'ps_g1', 'ps_phi_fract', 'ps_q_fract',
                                           'ps_constants')} | \
        {name: array(name, '.byte') for name in ('ps_k_to_i_20', 'ps_k_to_i_34')}


T = _tables()


def _filters(values, bands):
    return [[complex(values[(q * 7 + n) * 2], values[(q * 7 + n) * 2 + 1]) for n in range(7)] for q in range(bands)]


F20, F34_12, F34_8, F34_4 = (_filters(T['ps_f20'], 8), _filters(T['ps_f34_12'], 12), _filters(T['ps_f34_8'], 8),
                             _filters(T['ps_f34_4'], 4))
G1 = T['ps_g1']
PHI = [[complex(T['ps_phi_fract'][(c * 50 + k) * 2], T['ps_phi_fract'][(c * 50 + k) * 2 + 1]) for k in range(50)]
       for c in range(2)]
QF = [[[complex(T['ps_q_fract'][((c * 50 + k) * 3 + m) * 2], T['ps_q_fract'][((c * 50 + k) * 3 + m) * 2 + 1])
        for m in range(3)] for k in range(50)] for c in range(2)]
A_LINK = T['ps_constants'][:3]
DECAY_SLOPE, PEAK_DECAY, SMOOTH, IMPACT = T['ps_constants'][3:7]
K_TO_I = [T['ps_k_to_i_20'], T['ps_k_to_i_34']]
HA = [[T['ps_ha'][(i * 8 + c) * 4:(i * 8 + c) * 4 + 4] for c in range(8)] for i in range(46)]
HB = [[T['ps_hb'][(i * 8 + c) * 4:(i * 8 + c) * 4 + 4] for c in range(8)] for i in range(46)]
PD = [complex(re, im) for re, im in zip(T['ps_pd_re'], T['ps_pd_im'])]

NR_PAR_BANDS, NR_IPDOPD_BANDS, NR_BANDS = (20, 34), (11, 17), (71, 91)
DECAY_CUTOFF, NR_ALLPASS_BANDS, SHORT_DELAY_BAND = (10, 32), (30, 50), (42, 62)
NR_IIDICC = (10, 20, 34, 10, 20, 34)
NR_IPDOPD = (5, 11, 17, 5, 11, 17)
NUM_ENV = ((0, 1, 2, 4), (1, 2, 3, 4))
# Trees in sbr_model.TREES after the ten SBR trees.
IID_DF, IID_DT, IID_FINE_DF, IID_FINE_DT, ICC_DF, ICC_DT, IPD_DF, IPD_DT, OPD_DF, OPD_DT = range(10, 20)


def _div(a, b):
    """C integer division (towards zero)."""
    q = abs(a) // b
    return q if a >= 0 else -q


def map_idx_10_to_20(par, full):
    out = [0] * 34
    if not full:
        out[10] = 0
    for b in range(9 if full else 4, -1, -1):
        out[2 * b + 1] = out[2 * b] = par[b]
    return out


def map_idx_34_to_20(par, full):
    out = [0] * 34
    out[0] = _div(2 * par[0] + par[1], 3)
    out[1] = _div(par[1] + 2 * par[2], 3)
    out[2] = _div(2 * par[3] + par[4], 3)
    out[3] = _div(par[4] + 2 * par[5], 3)
    out[4] = _div(par[6] + par[7], 2)
    out[5] = _div(par[8] + par[9], 2)
    out[6], out[7] = par[10], par[11]
    out[8] = _div(par[12] + par[13], 2)
    out[9] = _div(par[14] + par[15], 2)
    out[10] = par[16]
    if full:
        out[11], out[12], out[13] = par[17], par[18], par[19]
        out[14] = _div(par[20] + par[21], 2)
        out[15] = _div(par[22] + par[23], 2)
        out[16] = _div(par[24] + par[25], 2)
        out[17] = _div(par[26] + par[27], 2)
        out[18] = _div(par[28] + par[29] + par[30] + par[31], 4)
        out[19] = _div(par[32] + par[33], 2)
    return out


def map_idx_10_to_34(par, full):
    out = [0] * 34
    if full:
        for i, b in ((33, 9), (32, 9), (31, 9), (30, 9), (29, 9), (28, 9), (27, 8), (26, 8), (25, 8), (24, 8),
                     (23, 7), (22, 7), (21, 7), (20, 7), (19, 6), (18, 6), (17, 5), (16, 5)):
            out[i] = par[b]
    else:
        out[16] = 0
    for i, b in ((15, 4), (14, 4), (13, 4), (12, 4), (11, 3), (10, 3), (9, 2), (8, 2), (7, 2), (6, 2), (5, 1),
                 (4, 1), (3, 1), (2, 0), (1, 0), (0, 0)):
        out[i] = par[b]
    return out


def map_idx_20_to_34(par, full):
    out = [0] * 34
    if full:
        for i, b in ((33, 19), (32, 19), (31, 18), (30, 18), (29, 18), (28, 18), (27, 17), (26, 17), (25, 16),
                     (24, 16), (23, 15), (22, 15), (21, 14), (20, 14), (19, 13), (18, 12), (17, 11)):
            out[i] = par[b]
    for i, b in ((16, 10), (15, 9), (14, 9), (13, 8), (12, 8), (11, 7), (10, 6), (9, 5), (8, 5), (7, 4), (6, 4),
                 (5, 3), (3, 2), (2, 1), (0, 0)):
        out[i] = par[b]
    out[4] = _div(par[2] + par[3], 2)
    out[1] = _div(par[0] + par[1], 2)
    return out


def map_val_34_to_20(par):
    par[0] = (2 * par[0] + par[1]) * 0.33333333
    par[1] = (par[1] + 2 * par[2]) * 0.33333333
    par[2] = (2 * par[3] + par[4]) * 0.33333333
    par[3] = (par[4] + 2 * par[5]) * 0.33333333
    par[4] = (par[6] + par[7]) * 0.5
    par[5] = (par[8] + par[9]) * 0.5
    par[6], par[7] = par[10], par[11]
    par[8] = (par[12] + par[13]) * 0.5
    par[9] = (par[14] + par[15]) * 0.5
    par[10], par[11], par[12], par[13] = par[16], par[17], par[18], par[19]
    par[14] = (par[20] + par[21]) * 0.5
    par[15] = (par[22] + par[23]) * 0.5
    par[16] = (par[24] + par[25]) * 0.5
    par[17] = (par[26] + par[27]) * 0.5
    par[18] = (par[28] + par[29] + par[30] + par[31]) * 0.25
    par[19] = (par[32] + par[33]) * 0.5


def map_val_20_to_34(par):
    for i, b in ((33, 19), (32, 19), (31, 18), (30, 18), (29, 18), (28, 18), (27, 17), (26, 17), (25, 16),
                 (24, 16), (23, 15), (22, 15), (21, 14), (20, 14), (19, 13), (18, 12), (17, 11), (16, 10),
                 (15, 9), (14, 9), (13, 8), (12, 8), (11, 7), (10, 6), (9, 5), (8, 5), (7, 4), (6, 4), (5, 3)):
        par[i] = par[b]
    par[4] = (par[2] + par[3]) * 0.5
    par[3] = par[2]
    par[2] = par[1]
    par[1] = (par[0] + par[1]) * 0.5


class PS:
    def __init__(self):
        self.start = False
        self.enable_iid = self.iid_quant = self.nr_iid_par = self.nr_ipdopd_par = 0
        self.enable_icc = self.icc_mode = self.nr_icc_par = self.enable_ext = 0
        self.frame_class = self.num_env_old = self.num_env = self.enable_ipdopd = 0
        self.border = [0] * 6
        self.iid = [[0] * 34 for _ in range(5)]
        self.icc = [[0] * 34 for _ in range(5)]
        self.ipd = [[0] * 34 for _ in range(5)]
        self.opd = [[0] * 34 for _ in range(5)]
        self.is34 = self.is34_old = 0
        self.in_buf = [[0j] * 44 for _ in range(5)]
        self.delay = [[0j] * 46 for _ in range(91)]
        self.ap_delay = [[[0j] * 37 for _ in range(3)] for _ in range(50)]
        self.peak_decay_nrg = [0.0] * 34
        self.power_smooth = [0.0] * 34
        self.peak_decay_diff_smooth = [0.0] * 34
        self.H = [[[[0.0] * 34 for _ in range(6)] for _ in range(2)] for _ in range(4)]   # H11, H12, H21, H22
        self.opd_hist = [0] * 34
        self.ipd_hist = [0] * 34
        self.used = set()

    # Payload -------------------------------------------------------------
    def write(self, r, bits, header=None):
        """ps_data; header: None or dict(iid_mode, icc_mode, ext) (None
        values disable IID/ICC). Draws values and tracks decoder state."""
        bits.put(1 if header else 0, 1)
        if header:
            self.enable_iid = int(header['iid_mode'] is not None)
            bits.put(self.enable_iid, 1)
            if self.enable_iid:
                bits.put(header['iid_mode'], 3)
                self.nr_iid_par = NR_IIDICC[header['iid_mode']]
                self.iid_quant = int(header['iid_mode'] > 2)
                self.nr_ipdopd_par = NR_IPDOPD[header['iid_mode']]
            self.enable_icc = int(header['icc_mode'] is not None)
            bits.put(self.enable_icc, 1)
            if self.enable_icc:
                self.icc_mode = header['icc_mode']
                bits.put(self.icc_mode, 3)
                self.nr_icc_par = NR_IIDICC[self.icc_mode]
            self.enable_ext = int(header['ext'])
            bits.put(self.enable_ext, 1)
            self.used.add(f'IID mode {header["iid_mode"]}')
            self.used.add(f'ICC mode {header["icc_mode"]}')
        self.frame_class = r.randrange(2)
        bits.put(self.frame_class, 1)
        self.num_env_old = self.num_env
        index = r.randrange(4)
        bits.put(index, 2)
        self.num_env = NUM_ENV[self.frame_class][index]
        self.used.add(f'class {self.frame_class} with {self.num_env} envelopes')
        self.border[0] = -1
        if self.frame_class:
            positions = sorted(r.randrange(32) for _ in range(self.num_env))
            for e in range(1, self.num_env + 1):
                self.border[e] = positions[e - 1]
                bits.put(self.border[e], 5)
        else:
            log2 = (0, 0, 1, 1, 2)[self.num_env]
            for e in range(1, self.num_env + 1):
                self.border[e] = (e * 32 >> log2) - 1
        if self.enable_iid:
            top = 7 + 8 * self.iid_quant
            for e in range(self.num_env):
                prev = max(e - 1 if e else self.num_env_old - 1, 0)
                dt = int(r.random() < 0.5 and all(abs(v) <= top for v in self.iid[prev][:self.nr_iid_par]))
                bits.put(dt, 1)
                tree = (IID_FINE_DT if dt else IID_FINE_DF) if self.iid_quant else (IID_DT if dt else IID_DF)
                self._par(r, bits, self.iid, e, dt, self.nr_iid_par, tree, -top, top)
        else:
            self.iid = [[0] * 34 for _ in range(5)]
        if self.enable_icc:
            for e in range(self.num_env):
                dt = r.randrange(2)
                bits.put(dt, 1)
                self._par(r, bits, self.icc, e, dt, self.nr_icc_par, ICC_DT if dt else ICC_DF, 0, 7)
        else:
            self.icc = [[0] * 34 for _ in range(5)]
        if self.enable_ext:
            ext = sbr_model_bits()
            self.enable_ipdopd = int(r.random() < 0.7)
            ext.put(self.enable_ipdopd, 1)
            if self.enable_ipdopd:
                self.used.add('IPD/OPD')
                for e in range(self.num_env):
                    for par, trees in ((self.ipd, (IPD_DF, IPD_DT)), (self.opd, (OPD_DF, OPD_DT))):
                        dt = r.randrange(2)
                        ext.put(dt, 1)
                        self._par(r, ext, par, e, dt, self.nr_ipdopd_par, trees[dt], 0, 7, wrap=True)
            ext.put(0, 1)                                  # reserved_ps
            count = (2 + ext.count + 7) // 8               # ps_extension_id 0 and its data
            if count >= 15:
                bits.put(15, 4)
                bits.put(count - 15, 8)
            else:
                bits.put(count, 4)
            bits.put(0, 2)
            bits.put(ext.value, ext.count)
            bits.put(0, count * 8 - 2 - ext.count)
        # Envelope fix-up as the decoder does it.
        if not self.num_env or self.border[self.num_env] < 31:
            source = self.num_env - 1 if self.num_env else self.num_env_old - 1
            if source >= 0 and source != self.num_env:
                if self.enable_iid:
                    self.iid[self.num_env] = list(self.iid[source])
                if self.enable_icc:
                    self.icc[self.num_env] = list(self.icc[source])
                if self.enable_ipdopd:
                    self.ipd[self.num_env] = list(self.ipd[source])
                    self.opd[self.num_env] = list(self.opd[source])
            self.num_env += 1
            self.border[self.num_env] = 31
            self.used.add('appended last envelope')
        self.is34_old = self.is34
        if self.enable_iid or self.enable_icc:
            self.is34 = int((self.enable_iid and self.nr_iid_par == 34) or (self.enable_icc and self.nr_icc_par == 34))
        if self.is34 != self.is34_old:
            self.used.add('band layout switch')
        self.used.add('34 bands' if self.is34 else '20 bands')
        if not self.enable_ipdopd:
            self.ipd = [[0] * 34 for _ in range(5)]
            self.opd = [[0] * 34 for _ in range(5)]
        if header:
            self.start = True

    def _par(self, r, bits, par, e, dt, count, tree, low, high, wrap=False):
        codes = sbr_model.CODES[tree]
        def draw(base):
            if r.random() < 0.3:
                return r.randrange(low, high + 1)
            value = base + r.randrange(-2, 3)                  # mostly small steps, as encoders send
            return value & 7 if wrap else min(high, max(low, value))
        if dt:
            prev = max(e - 1 if e else self.num_env_old - 1, 0)
            for b in range(count):
                value = draw(par[prev][b])
                delta = (value - par[prev][b]) & 7 if wrap else value - par[prev][b]
                par[e][b] = value
                bits.put(*codes[delta])
        else:
            last = 0
            for b in range(count):
                value = draw(last)
                delta = (value - last) & 7 if wrap else value - last
                par[e][b] = last = value
                bits.put(*codes[delta])

    # Signal processing -----------------------------------------------------
    def apply(self, L, R, top):
        """L: 38 slots x 64 complex QMF values of the mono signal, replaced by
        the left channel in slots 0-31; R receives the right channel."""
        is34 = self.is34
        top += NR_BANDS[is34] - 64
        for k in range(top, NR_BANDS[is34]):
            self.delay[k] = [0j] * 46
        for k in range(top, NR_ALLPASS_BANDS[is34]):
            self.ap_delay[k] = [[0j] * 37 for _ in range(3)]
        lbuf = self._hybrid_analysis(L, is34)
        rbuf = self._decorrelation(lbuf, is34)
        self._stereo_processing(lbuf, rbuf, is34)
        self._hybrid_synthesis(L, lbuf, is34)
        self._hybrid_synthesis(R, rbuf, is34)

    def _hybrid_analysis(self, L, is34):
        for i in range(5):
            for j in range(38):
                self.in_buf[i][j + 6] = L[j][i]
        out = [[0j] * 32 for _ in range(91)]

        def complex_filter(x, f):
            s = f[6].real * x[6]
            for j in range(6):
                s += f[j].real * (x[j] + x[12 - j]) + 1j * f[j].imag * (x[j] - x[12 - j])
            return s
        if is34:
            row = 0
            for band, filters in ((0, F34_12), (1, F34_8), (2, F34_4), (3, F34_4), (4, F34_4)):
                for q, f in enumerate(filters):
                    for i in range(32):
                        out[row + q][i] = complex_filter(self.in_buf[band][i:i + 13], f)
                row += len(filters)
            for k in range(5, 64):
                for j in range(32):
                    out[k + 27][j] = L[j][k]
        else:
            for i in range(32):
                x = self.in_buf[0][i:i + 13]
                t = [complex_filter(x, f) for f in F20]
                out[0][i], out[1][i], out[2][i], out[3][i] = t[6], t[7], t[0], t[1]
                out[4][i], out[5][i] = t[2] + t[5], t[3] + t[4]
            for band, first, reverse in ((1, 6, 1), (2, 8, 0)):
                for i in range(32):
                    x = self.in_buf[band][i:i + 13]
                    inphase = G1[6] * x[6]
                    outphase = sum(G1[j + 1] * (x[j + 1] + x[12 - j - 1]) for j in (0, 2, 4))
                    out[first + reverse][i] = inphase + outphase
                    out[first + 1 - reverse][i] = inphase - outphase
            for k in range(3, 64):
                for j in range(32):
                    out[k + 7][j] = L[j][k]
        for i in range(5):
            self.in_buf[i][0:6] = self.in_buf[i][32:38]
        return out

    def _decorrelation(self, s, is34):
        k_to_i = K_TO_I[is34]
        out = [[0j] * 32 for _ in range(91)]
        if is34 != self.is34_old:
            self.peak_decay_nrg = [0.0] * 34
            self.power_smooth = [0.0] * 34
            self.peak_decay_diff_smooth = [0.0] * 34
            self.delay = [[0j] * 46 for _ in range(91)]
            self.ap_delay = [[[0j] * 37 for _ in range(3)] for _ in range(50)]
        power = [[0.0] * 32 for _ in range(34)]
        for k in range(NR_BANDS[is34]):
            row = power[k_to_i[k]]
            for n in range(32):
                row[n] += s[k][n].real ** 2 + s[k][n].imag ** 2
        gain = [[1.0] * 32 for _ in range(34)]
        for i in range(NR_PAR_BANDS[is34]):
            for n in range(32):
                decayed = PEAK_DECAY * self.peak_decay_nrg[i]
                self.peak_decay_nrg[i] = max(decayed, power[i][n])
                self.power_smooth[i] += SMOOTH * (power[i][n] - self.power_smooth[i])
                self.peak_decay_diff_smooth[i] += SMOOTH * (self.peak_decay_nrg[i] - power[i][n] -
                                                           self.peak_decay_diff_smooth[i])
                denominator = IMPACT * self.peak_decay_diff_smooth[i]
                gain[i][n] = self.power_smooth[i] / denominator if denominator > self.power_smooth[i] else 1.0
        for k in range(NR_BANDS[is34]):
            delay = self.delay[k]
            delay[0:14] = delay[32:46]
            delay[14:46] = s[k]
            if k < NR_ALLPASS_BANDS[is34]:
                g = min(1.0, max(0.0, 1.0 - DECAY_SLOPE * (k - DECAY_CUTOFF[is34])))
                ag = [a * g for a in A_LINK]
                ap = self.ap_delay[k]
                for m in range(3):
                    ap[m][0:5] = ap[m][32:37]
                tg = gain[k_to_i[k]]
                for n in range(32):
                    x = delay[12 + n] * PHI[is34][k]
                    for m in range(3):
                        apd = x
                        x = ap[m][n + 2 - m] * QF[is34][k][m] - ag[m] * x
                        ap[m][n + 5] = apd + ag[m] * x
                    out[k][n] = tg[n] * x
            else:
                offset = 0 if k < SHORT_DELAY_BAND[is34] else 13
                tg = gain[k_to_i[k]]
                for n in range(32):
                    out[k][n] = delay[n + offset] * tg[n]
        return out

    def _stereo_processing(self, l, r, is34):
        H = self.H
        k_to_i = K_TO_I[is34]
        lut = HA if self.icc_mode < 3 else HB
        if self.num_env_old:
            for h in H:
                for part in range(2):
                    h[part][0] = list(h[part][self.num_env_old])

        def remap(par, count, full):
            if is34:
                if count in (20, 11):
                    return [map_idx_20_to_34(par[e], full) for e in range(self.num_env)]
                if count in (10, 5):
                    return [map_idx_10_to_34(par[e], full) for e in range(self.num_env)]
            else:
                if count in (34, 17):
                    return [map_idx_34_to_20(par[e], full) for e in range(self.num_env)]
                if count in (10, 5):
                    return [map_idx_10_to_20(par[e], full) for e in range(self.num_env)]
            return par
        iid = remap(self.iid, self.nr_iid_par, True)
        icc = remap(self.icc, self.nr_icc_par, True)
        ipd = opd = None
        if self.enable_ipdopd:
            ipd = remap(self.ipd, self.nr_ipdopd_par, False)
            opd = remap(self.opd, self.nr_ipdopd_par, False)
        if is34 and not self.is34_old:
            for h in H:
                for part in range(2):
                    map_val_20_to_34(h[part][0])
            self.ipd_hist = [0] * 34
            self.opd_hist = [0] * 34
        elif not is34 and self.is34_old:
            for h in H:
                for part in range(2):
                    map_val_34_to_20(h[part][0])
            self.ipd_hist = [0] * 34
            self.opd_hist = [0] * 34
        for e in range(self.num_env):
            for b in range(NR_PAR_BANDS[is34]):
                h = list(lut[iid[e][b] + 7 + 23 * self.iid_quant][icc[e][b]])
                if self.enable_ipdopd and b < NR_IPDOPD_BANDS[is34]:
                    opd_index = self.opd_hist[b] * 8 + opd[e][b]
                    ipd_index = self.ipd_hist[b] * 8 + ipd[e][b]
                    o, i = PD[opd_index], PD[ipd_index]
                    self.opd_hist[b] = opd_index & 0x3f
                    self.ipd_hist[b] = ipd_index & 0x3f
                    adjust = complex(o.real * i.real + o.imag * i.imag, o.imag * i.real - o.real * i.imag)
                    imaginary = [h[0] * o.imag, h[1] * adjust.imag, h[2] * o.imag, h[3] * adjust.imag]
                    h = [h[0] * o.real, h[1] * adjust.real, h[2] * o.real, h[3] * adjust.real]
                    for j in range(4):
                        H[j][1][e + 1][b] = imaginary[j]
                for j in range(4):
                    H[j][0][e + 1][b] = h[j]
            start, stop = self.border[e], self.border[e + 1]
            width = 1.0 / ((stop - start) or 1)
            for k in range(NR_BANDS[is34]):
                b = k_to_i[k]
                h0 = [H[j][0][e][b] for j in range(4)]
                step0 = [(H[j][0][e + 1][b] - h0[j]) * width for j in range(4)]
                if self.enable_ipdopd:
                    negate = (is34 and 9 <= k <= 13) or (not is34 and k <= 1)
                    h1 = [-H[j][1][e][b] if negate else H[j][1][e][b] for j in range(4)]
                    step1 = [(H[j][1][e + 1][b] - h1[j]) * width for j in range(4)]
                for n in range(start + 1, stop + 1):
                    for j in range(4):
                        h0[j] += step0[j]
                    lv, rv = l[k][n], r[k][n]
                    if self.enable_ipdopd:
                        for j in range(4):
                            h1[j] += step1[j]
                        l[k][n] = complex(h0[0] * lv.real + h0[2] * rv.real - h1[0] * lv.imag - h1[2] * rv.imag,
                                          h0[0] * lv.imag + h0[2] * rv.imag + h1[0] * lv.real + h1[2] * rv.real)
                        r[k][n] = complex(h0[1] * lv.real + h0[3] * rv.real - h1[1] * lv.imag - h1[3] * rv.imag,
                                          h0[1] * lv.imag + h0[3] * rv.imag + h1[1] * lv.real + h1[3] * rv.real)
                    else:
                        l[k][n] = h0[0] * lv + h0[2] * rv
                        r[k][n] = h0[1] * lv + h0[3] * rv

    @staticmethod
    def _hybrid_synthesis(out, buf, is34):
        for n in range(32):
            row = out[n]
            if is34:
                row[0] = sum(buf[i][n] for i in range(12))
                row[1] = sum(buf[i][n] for i in range(12, 20))
                row[2] = sum(buf[i][n] for i in range(20, 24))
                row[3] = sum(buf[i][n] for i in range(24, 28))
                row[4] = sum(buf[i][n] for i in range(28, 32))
                for k in range(5, 64):
                    row[k] = buf[k + 27][n]
            else:
                row[0] = sum(buf[i][n] for i in range(6))
                row[1] = buf[6][n] + buf[7][n]
                row[2] = buf[8][n] + buf[9][n]
                for k in range(3, 64):
                    row[k] = buf[k + 7][n]


def sbr_model_bits():
    import aac_vectors
    return aac_vectors.Bits()


def header(r):
    """Random PS header fields: IID and ICC modes (None disables) and the
    IPD/OPD extension."""
    return dict(iid_mode=r.choice([None, 0, 1, 2, 3, 4, 5]), icc_mode=r.choice([None, 0, 1, 2, 3, 4, 5]),
                ext=r.random() < 0.5)
