"""Test-only model of HE-AAC spectral band replication (ISO/IEC 14496-3 4.6.18).

A double-precision Python model of SBR decoding: frequency band tables,
envelope and noise dequantization, the complex QMF banks, HF generation with
inverse filtering, envelope adjustment and the time-slot buffering between
frames. Element.write_payload() draws valid SBR data and writes it (for
tests/sbr_vectors.py) while tracking what a decoder knows; Element.apply()
renders it from the core AAC-LC PCM, so the writer's intent can be checked
against FFmpeg independently of LAMP. Tables come from src/sbr_tables.inc.
"""
import cmath
import math
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parent.parent
FIXFIX, FIXVAR, VARFIX, VARVAR = 0, 1, 2, 3
ENV_OFFSET = 2          # envelope adjustment offset in QMF slots
NOISE_OFFSET = 6        # noise floor offset


def _tables():
    text = (ROOT / 'src' / 'sbr_tables.inc').read_text()

    def array(name, directive):
        body = text.split(name + ':\n', 1)[1]
        values = []
        for line in body.splitlines():
            line = line.strip()
            if not line.startswith(directive):
                break
            values += [int(v, 0) for v in line[len(directive):].split(',')]
        return values
    starts = array('sbr_huff_trees', '.short')
    nodes = [v - 256 if v > 127 else v for v in array('sbr_huff_nodes', '.byte')]
    trees = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(nodes) // 2
        trees.append([(nodes[2 * n], nodes[2 * n + 1]) for n in range(start, end)])
    offsets = [v - 256 if v > 127 else v for v in array('sbr_start_offsets', '.byte')]
    as_float = lambda v: struct.unpack('<f', struct.pack('<I', v))[0]
    window = [as_float(v) for v in array('sbr_qmf_window', '.long')]
    noise = [as_float(v) for v in array('sbr_noise_table', '.long')]
    return trees, [offsets[i:i + 16] for i in range(0, 112, 16)], window, \
        [complex(noise[2 * i], noise[2 * i + 1]) for i in range(512)]


TREES, START_OFFSETS, QMF_WINDOW, NOISE_TABLE = _tables()
# Tree indices.
ENV15_T, ENV15_F, BAL15_T, BAL15_F, ENV30_T, ENV30_F, BAL30_T, BAL30_F, NOISE30_T, NOISEBAL30_T = range(10)


def tree_codes(tree):
    """value -> (code, length) for a PacketVideo-style tree."""
    codes = {}

    def walk(node, code, length):
        for bit in (0, 1):
            nxt = tree[node][bit]
            if nxt < 0:
                codes[nxt + 64] = ((code << 1) | bit, length + 1)
            else:
                walk(nxt, (code << 1) | bit, length + 1)
    walk(0, 0, 0)
    return codes


CODES = [tree_codes(t) for t in TREES]
LAV = {ENV15_T: 60, ENV15_F: 60, BAL15_T: 24, BAL15_F: 24, ENV30_T: 31, ENV30_F: 31, BAL30_T: 12, BAL30_F: 12,
       NOISE30_T: 31, NOISEBAL30_T: 12}


class TableError(Exception):
    pass


def nint(x):
    return int(math.floor(x + 0.5))


def make_bands(start, stop, count):
    """Band widths between start and stop on a logarithmic scale (ISO vDk)."""
    widths, previous = [], start
    for k in range(1, count):
        present = nint(start * (stop / start) ** (k / count))
        widths.append(present - previous)
        previous = present
    widths.append(stop - previous)
    return widths


def frequency_tables(rate, h):
    """Master and derived frequency band tables (ISO 4.6.18.3.2); rate is the
    SBR output rate. Raises TableError for streams FFmpeg also rejects."""
    rows = {16000: 0, 22050: 1, 24000: 2, 32000: 3, 44100: 4, 48000: 4, 64000: 4, 88200: 5, 96000: 5}
    if rate not in rows:
        raise TableError('rate')
    temp = 3000 if rate < 32000 else 4000 if rate < 64000 else 5000
    start_min = ((temp << 7) + (rate >> 1)) // rate
    stop_min = ((temp << 8) + (rate >> 1)) // rate
    k0 = start_min + START_OFFSETS[rows[rate]][h['start_freq']]
    if h['stop_freq'] < 14:
        k2 = stop_min + sum(sorted(make_bands(stop_min, 64, 13))[:h['stop_freq']])
    elif h['stop_freq'] == 14:
        k2 = 2 * k0
    else:
        k2 = 3 * k0
    k2 = min(64, k2)
    maximum = 48 if rate <= 32000 else 35 if rate == 44100 else 32
    if k2 - k0 > maximum:
        raise TableError('too many QMF subbands')
    regions = 0
    if h['freq_scale'] == 0:
        dk = h['alter_scale'] + 1
        n_master = ((k2 - k0 + (dk & 2)) >> dk) << 1
        if n_master <= 0 or h['xover_band'] >= n_master:
            raise TableError('n_master')
        widths = [dk] * n_master
        diff = k2 - k0 - n_master * dk
        if diff < 0:
            widths[0] -= 1
            if diff < -1:
                widths[1] -= 1
        elif diff:
            widths[-1] += 1
        f_master = [k0]
        for w in widths:
            f_master.append(f_master[-1] + w)
    else:
        half = 7 - h['freq_scale']
        two_regions = 49 * k2 > 110 * k0
        k1 = 2 * k0 if two_regions else k2
        num0 = nint(half * math.log2(k1 / k0)) * 2
        if num0 <= 0:
            raise TableError('num_bands_0')
        vk0 = sorted(make_bands(k0, k1, num0))
        if min(vk0) <= 0:
            raise TableError('vDk0')
        f_master = [k0]
        for w in vk0:
            f_master.append(f_master[-1] + w)
        warp = 1.3 if h['alter_scale'] else 1.0
        num1 = nint(half * math.log2(k2 / k1) / warp) * 2 if two_regions else 0
        regions = 2 if num1 else 1
        if num1:                                # FFmpeg leaves an empty second region out
            vk1 = make_bands(k1, k2, num1)
            if min(vk1) < max(vk0):
                vk1 = sorted(vk1)
                change = min(max(vk0) - vk1[0], (vk1[-1] - vk1[0]) >> 1)
                vk1[0] += change
                vk1[-1] -= change
            vk1 = sorted(vk1)
            if min(vk1) <= 0:
                raise TableError('vDk1')
            for w in vk1:
                f_master.append(f_master[-1] + w)
        n_master = len(f_master) - 1
        if n_master <= 0 or h['xover_band'] >= n_master:
            raise TableError('n_master')
    t = {'k0': k0, 'k2': k2, 'f_master': f_master, 'n_master': len(f_master) - 1, 'regions': regions}
    # Derived tables.
    n_high = t['n_master'] - h['xover_band']
    n_low = (n_high + 1) >> 1
    f_high = f_master[h['xover_band']:]
    kx, m = f_high[0], f_high[-1] - f_high[0]
    if kx + m > 64 or kx > 32:
        raise TableError('border')
    odd = n_high & 1
    f_low = [f_high[0]] + [f_high[2 * k - odd] for k in range(1, n_low + 1)]
    n_q = max(1, nint(h['noise_bands'] * math.log2(k2 / kx)))
    if n_q > 5:
        raise TableError('n_q')
    f_noise, temp = [f_low[0]], 0
    for k in range(1, n_q + 1):
        temp += (n_low - temp) // (n_q + 1 - k)
        f_noise.append(f_low[temp])
    t.update(n=[n_low, n_high], f_high=f_high, f_low=f_low, kx=kx, m=m, n_q=n_q, f_noise=f_noise)
    patches(rate, t)
    limiter_table(h, t)
    return t


def patches(rate, t):
    """Patch construction (ISO figure 4.46)."""
    k0, kx, m, f_master, n_master = t['k0'], t['kx'], t['m'], t['f_master'], t['n_master']
    msb, usb = k0, kx
    goal = ((1000 << 11) + (rate >> 1)) // rate
    if goal < kx + m:
        k = 0
        while f_master[k] < goal:
            k += 1
    else:
        k = n_master
    sizes, starts = [], []
    last_k = last_msb = None
    sb = 0
    while True:
        if k == last_k and msb == last_msb:
            raise TableError('patch construction')
        last_k, last_msb = k, msb
        i, odd = k, 0
        while True:
            sb = f_master[i]
            odd = (sb + k0) & 1
            if not (sb > k0 - 1 + msb - odd):
                break
            i -= 1
        if len(sizes) > 5:
            raise TableError('patches')
        size = max(sb - usb, 0)
        start = k0 - odd - size
        if size > 0:
            sizes.append(size)
            starts.append(start)
            usb = msb = sb
        else:
            msb = kx
        if f_master[k] - sb < 3:
            k = n_master
        if sb == kx + m:
            break
    if len(sizes) > 1 and sizes[-1] < 3:
        sizes.pop()
        starts.pop()
    t['patch_sizes'], t['patch_starts'] = sizes, starts


def limiter_table(h, t):
    if h['limiter_bands'] == 0:
        t['f_lim'] = [t['f_low'][0], t['f_low'][-1]]
        return
    warped = [1.32715174233856803909, 1.18509277094158210129, 1.11987160404675912501][h['limiter_bands'] - 1]
    borders = [t['kx']]
    for size in t['patch_sizes']:
        borders.append(borders[-1] + size)
    table = sorted(t['f_low'] + borders[1:-1]) if len(t['patch_sizes']) > 1 else list(t['f_low'])
    # In-place reduction exactly as the reference loop walks it.
    out, inp, n_lim = 0, 1, len(table) - 1
    while out < n_lim:
        if table[inp] >= table[out] * warped:
            out += 1
            table[out] = table[inp]
            inp += 1
        elif table[inp] == table[out] or table[inp] not in borders:
            inp += 1
            n_lim -= 1
        elif table[out] not in borders:
            table[out] = table[inp]
            inp += 1
            n_lim -= 1
        else:
            out += 1
            table[out] = table[inp]
            inp += 1
    t['f_lim'] = table[:n_lim + 1]


# ------------------------------------------------------------------ QMF banks
_ANALYSIS = [[2 * cmath.exp(1j * math.pi / 64 * (k + 0.5) * (2 * n - 0.5)) for n in range(64)] for k in range(32)]
_SYNTHESIS = [[cmath.exp(1j * math.pi / 128 * (k + 0.5) * (2 * n - 255)) / 64 for k in range(64)] for n in range(128)]


class Channel:
    """SBR state of one channel (ISO SBR data and the filterbank memories)."""

    def __init__(self):
        self.x = [0.0] * 320                      # analysis input, time order
        self.v = [0.0] * 1280                     # synthesis memory, newest first
        self.W = [[[0j] * 32 for _ in range(32)] for _ in range(2)]
        self.Y = [[[0j] * 64 for _ in range(38)] for _ in range(2)]
        self.ypos = 0
        self.num_env = 0
        self.freq_res = [0] * 7
        self.t_env = [0] * 8
        self.t_env_old = 0
        self.e_a = [-1, -1]
        self.env_q = [[0] * 48 for _ in range(6)]
        self.noise_q = [[0] * 5 for _ in range(3)]
        self.invf = [[0] * 5, [0] * 5]
        self.bw = [0.0] * 5
        self.s_index = [[0] * 48 for _ in range(8)]
        self.g_temp = [[0.0] * 48 for _ in range(42)]
        self.q_temp = [[0.0] * 48 for _ in range(42)]
        self.index_noise = 0
        self.index_sine = 0

    def analysis(self, pcm):
        """32 slots of 32 complex subbands from 1024 samples scaled to +-32768."""
        out = []
        for slot in range(32):
            self.x = self.x[32:] + [s * 32768.0 for s in pcm[32 * slot:32 * slot + 32]]
            u = [0.0] * 64
            for n in range(320):
                u[n % 64] += self.x[319 - n] * QMF_WINDOW[2 * n]
            out.append([sum(u[n] * _ANALYSIS[k][n] for n in range(64)) for k in range(32)])
        return out

    def synthesis(self, X):
        """64-band synthesis of 32 slots -> 2048 samples scaled back to +-1."""
        out = []
        for slot in range(32):
            self.v = [0.0] * 128 + self.v[:1152]
            for n in range(128):
                self.v[n] = sum((X[slot][k] * _SYNTHESIS[n][k]).real for k in range(64))
            for j in range(64):
                acc = 0.0
                for i in range(5):
                    acc += self.v[256 * i + j] * QMF_WINDOW[128 * i + j]
                    acc += self.v[256 * i + 192 + j] * QMF_WINDOW[128 * i + 64 + j]
                out.append(acc / 32768.0)
        return out


# ------------------------------------------------------------ stream writing
CEIL_LOG2 = [0, 1, 2, 2, 3, 3]
LIMITER_GAINS = [0.70795, 1.0, 1.41254, 10000000000.0]
SMOOTH = [0.33333333333333, 0.30150283239582, 0.21816949906249, 0.11516383427084, 0.03183050093751]
SPECTRUM = ('start_freq', 'stop_freq', 'xover_band', 'freq_scale', 'alter_scale', 'noise_bands')


class Element:
    """SBR state of one channel element, updated as a decoder would after
    reading each payload; write_payload() draws random valid values, writes
    them and applies them in one pass. A steady element keeps everything a
    decoder tuning in at a seek cannot know out of its output: frequency-coded
    first envelopes and noise floors, no inverse filtering, no sinusoids and
    the lowest noise floors."""

    def __init__(self, rate, channels, steady=False):
        self.rate, self.channels, self.steady = rate, channels, steady
        self.ch = [Channel(), Channel()]
        self.kx, self.m = [0, 0], [0, 0]
        self.pushed = False
        self.header = None
        self.tables = None
        self.coupling = False
        self.ps = None                            # ps_model.PS: mono input renders a stereo pair
        # Gains and levels persist per element (FFmpeg): a limiter table that
        # ends below kx + M leaves the top subbands with earlier values.
        self.gain = [[0.0] * 48 for _ in range(7)]
        self.q_m = [[0.0] * 48 for _ in range(7)]
        self.s_m = [[0.0] * 48 for _ in range(7)]
        self.used = set()                         # SBR tools written, for coverage
        self.turnoff()

    def turnoff(self):
        self.start = False
        self.ready = False
        self.kx[1], self.m[1] = 32, 0
        for c in self.ch:
            c.e_a[1] = -1
        self.spectrum = None

    # Payload ------------------------------------------------------------
    def write_payload(self, r, bits, header=None, extension=None):
        """sbr_extension_data after the extension type; returns nothing."""
        self.reset = False
        self.kx[0], self.m[0] = self.kx[1], self.m[1]
        self.pushed = True
        bits.put(1 if header else 0, 1)
        if header:
            self._header(bits, header)
        if self.reset:
            try:
                self.tables = frequency_tables(self.rate, self.header)
                self.kx[1], self.m[1] = self.tables['kx'], self.tables['m']
                for c in self.ch:
                    c.index_noise = 0
                h = self.header
                self.used.add('header reset')
                self.used.add(('linear', 'one-region', 'two-region')[self.tables['regions']] + ' master table')
                self.used.add(f'{len(self.tables["patch_sizes"])} patches')
                self.used.add('limiter bands' if h['limiter_bands'] else 'one limiter band')
                if self.tables['f_lim'][-1] < self.tables['kx'] + self.tables['m']:
                    self.used.add('limiter table below kx + M')
                self.used.add('interpolated envelopes' if h['interpol_freq'] else 'band envelopes')
                self.used.add('smoothing' if h['smoothing'] == 0 else 'no smoothing')
            except TableError:
                self.turnoff()
        if not self.start:
            return
        self.ready = True
        if self.channels == 1:
            bits.put(0, 1)                                    # bs_data_extra
            c = self.ch[0]
            self._grid(r, bits, c)
            self._dtdf(r, bits, c)
            self._invf(r, bits, c)
            self._envelope(r, bits, c, 0)
            self._noise(r, bits, c, 0)
            self._harmonic(r, bits, c)
        else:
            bits.put(0, 1)
            # A shared grid continues both channels' previous frames, so they
            # must have ended on the same border (as an encoder ensures).
            a, b = self.ch
            self.coupling = r.random() < 0.5 and a.t_env[a.num_env] == b.t_env[b.num_env]
            bits.put(int(self.coupling), 1)
            self.used.add('coupled pair' if self.coupling else 'independent pair')
            a, b = self.ch
            if self.coupling:
                self._grid(r, bits, a)
                self._copy_grid(b, a)
                self._dtdf(r, bits, a)
                self._dtdf(r, bits, b)
                self._invf(r, bits, a)
                b.invf[1] = list(b.invf[0])
                b.invf[0] = list(a.invf[0])
                self._envelope(r, bits, a, 0)
                self._noise(r, bits, a, 0)
                self._envelope(r, bits, b, 1)
                self._noise(r, bits, b, 1)
            else:
                self._grid(r, bits, a)
                self._grid(r, bits, b)
                self._dtdf(r, bits, a)
                self._dtdf(r, bits, b)
                self._invf(r, bits, a)
                self._invf(r, bits, b)
                self._envelope(r, bits, a, 0)
                self._envelope(r, bits, b, 1)
                self._noise(r, bits, a, 0)
                self._noise(r, bits, b, 1)
            self._harmonic(r, bits, a)
            self._harmonic(r, bits, b)
        if extension:
            self.used.add('extended data')
            size = len(extension)
            bits.put(1, 1)
            if size >= 15:
                bits.put(15, 4)
                bits.put(size - 15, 8)
            else:
                bits.put(size, 4)
            for byte in extension:                       # extension id 0/1/3 and fill
                bits.put(byte, 8)
        else:
            bits.put(0, 1)

    def _header(self, bits, h):
        old_spectrum = self.spectrum
        old_limiter = self.header['limiter_bands'] if self.header else None
        self.start = True
        self.ready = False
        bits.put(h['amp_res'], 1)
        bits.put(h['start_freq'], 4)
        bits.put(h['stop_freq'], 4)
        bits.put(h['xover_band'], 3)
        bits.put(0, 2)
        extra1 = (h['freq_scale'], h['alter_scale'], h['noise_bands']) != (2, 1, 2) or h.get('force_extra')
        extra2 = (h['limiter_bands'], h['limiter_gains'], h['interpol_freq'], h['smoothing']) != (2, 2, 1, 1) \
            or h.get('force_extra')
        bits.put(int(bool(extra1)), 1)
        bits.put(int(bool(extra2)), 1)
        if extra1:
            bits.put(h['freq_scale'], 2)
            bits.put(h['alter_scale'], 1)
            bits.put(h['noise_bands'], 2)
        if extra2:
            bits.put(h['limiter_bands'], 2)
            bits.put(h['limiter_gains'], 2)
            bits.put(h['interpol_freq'], 1)
            bits.put(h['smoothing'], 1)
        self.header = dict(h)
        self.spectrum = tuple(h[k] for k in SPECTRUM)
        if self.spectrum != old_spectrum:
            self.reset = True
        if h['limiter_bands'] != old_limiter and not self.reset and self.tables:
            limiter_table(self.header, self.tables)

    def _grid(self, r, bits, c):
        old_env = c.num_env
        c.freq_res[0] = c.freq_res[c.num_env]
        c.amp_res = self.header['amp_res']
        c.t_env_old = c.t_env[old_env]
        lead = c.t_env_old - 16 if c.t_env_old > 16 else 0   # continue the previous frame
        classes = [VARFIX, VARVAR] if lead else [FIXFIX, FIXVAR, VARFIX, VARVAR]
        cls = r.choice(classes)
        bits.put(cls, 2)
        pointer = 0
        if cls == FIXFIX:
            exp = r.randrange(3)
            bits.put(exp, 2)
            c.num_env = 1 << exp
            if c.num_env == 1:
                c.amp_res = 0
            c.t_env = [0] * 8
            c.t_env[c.num_env] = 16
            step = (16 + (c.num_env >> 1)) // c.num_env
            for i in range(c.num_env - 1):
                c.t_env[i + 1] = c.t_env[i] + step
            res = r.randrange(2)
            bits.put(res, 1)
            for i in range(1, c.num_env + 1):
                c.freq_res[i] = res
        else:
            while True:
                trail = 16 + (r.randrange(4) if cls in (FIXVAR, VARVAR) else 0)
                start = lead if cls in (VARFIX, VARVAR) else 0
                n_lead = r.randrange(4) if cls in (VARFIX, VARVAR) else 0
                n_trail = r.randrange(4) if cls in (FIXVAR, VARVAR) else 0
                if n_lead + n_trail + 1 > (5 if cls == VARVAR else 4):
                    continue
                leads = [r.randrange(4) for _ in range(n_lead)]
                trails = [r.randrange(4) for _ in range(n_trail)]
                num = n_lead + n_trail + 1
                t = [0] * 8
                t[0], t[num] = start, trail
                for i in range(n_lead):
                    t[i + 1] = t[i] + 2 * leads[i] + 2
                for i in range(n_trail):
                    t[num - 1 - i] = t[num - i] - 2 * trails[i] - 2
                if all(t[i] < t[i + 1] for i in range(num)):
                    break
            c.num_env, c.t_env = num, t
            width = CEIL_LOG2[num]
            pointer = r.randrange(min(1 << width, num + 2)) if width else 0
            if cls == FIXVAR:
                bits.put(trail - 16, 2)
                bits.put(n_trail, 2)
                for v in trails:
                    bits.put(v, 2)
                bits.put(pointer, width)
                for i in range(num):
                    c.freq_res[num - i] = r.randrange(2)
                    bits.put(c.freq_res[num - i], 1)
            elif cls == VARFIX:
                bits.put(start, 2)
                bits.put(n_lead, 2)
                for v in leads:
                    bits.put(v, 2)
                bits.put(pointer, width)
                for i in range(num):
                    c.freq_res[i + 1] = r.randrange(2)
                    bits.put(c.freq_res[i + 1], 1)
            else:
                bits.put(start, 2)
                bits.put(trail - 16, 2)
                bits.put(n_lead, 2)
                bits.put(n_trail, 2)
                for v in leads:
                    bits.put(v, 2)
                for v in trails:
                    bits.put(v, 2)
                bits.put(pointer, width)
                for i in range(num):
                    c.freq_res[i + 1] = r.randrange(2)
                    bits.put(c.freq_res[i + 1], 1)
        c.frame_class = cls
        self.used.add(('FIXFIX', 'FIXVAR', 'VARFIX', 'VARVAR')[cls])
        self.used.add('1.5 dB envelopes' if c.amp_res == 0 else '3 dB envelopes')
        c.num_noise = 2 if c.num_env > 1 else 1
        c.t_q = [c.t_env[0], 0, 0]
        c.t_q[c.num_noise] = c.t_env[c.num_env]
        if c.num_noise > 1:
            if cls == FIXFIX:
                idx = c.num_env >> 1
            elif cls & 1:
                idx = c.num_env - max(pointer - 1, 1)
            else:
                idx = 1 if pointer == 0 else c.num_env - 1 if pointer == 1 else pointer - 1
            c.t_q[1] = c.t_env[idx]
        c.e_a[0] = -(c.e_a[1] != old_env)
        c.e_a[1] = -1
        if (cls & 1) and pointer:
            c.e_a[1] = c.num_env + 1 - pointer
        elif cls == VARFIX and pointer > 1:
            c.e_a[1] = pointer - 1
        if c.e_a[1] >= 0:
            self.used.add('transient envelope')

    def _copy_grid(self, dst, src):
        dst.freq_res[0] = dst.freq_res[dst.num_env]
        dst.t_env_old = dst.t_env[dst.num_env]
        dst.e_a[0] = -(dst.e_a[1] != dst.num_env)
        dst.freq_res[1:] = src.freq_res[1:]
        dst.t_env = list(src.t_env)
        dst.t_q = list(src.t_q)
        dst.num_env = src.num_env
        dst.amp_res = src.amp_res
        dst.num_noise = src.num_noise
        dst.frame_class = src.frame_class
        dst.e_a[1] = src.e_a[1]

    def _dtdf(self, r, bits, c):
        c.df_env = [r.randrange(2) for _ in range(c.num_env)]
        c.df_noise = [r.randrange(2) for _ in range(c.num_noise)]
        if self.steady:
            c.df_env[0] = c.df_noise[0] = 0
        for v in c.df_env + c.df_noise:
            bits.put(v, 1)
        self.used.update('time-delta' if v else 'frequency-delta' for v in c.df_env + c.df_noise)

    def _invf(self, r, bits, c):
        c.invf[1] = list(c.invf[0])
        for i in range(self.tables['n_q']):
            c.invf[0][i] = 0 if self.steady else r.randrange(4)
            bits.put(c.invf[0][i], 2)

    def _envelope(self, r, bits, c, index):
        t = self.tables
        balance = self.coupling and index == 1
        delta = 2 if balance else 1
        if balance:
            fbits, tt, ft = (5, BAL30_T, BAL30_F) if c.amp_res else (6, BAL15_T, BAL15_F)
            top = 24 if c.amp_res else 48                     # 2 * pan offset
        else:
            fbits, tt, ft = (6, ENV30_T, ENV30_F) if c.amp_res else (7, ENV15_T, ENV15_F)
            top = 30 if c.amp_res else 60                     # plausible energies
        odd = t['n'][1] & 1
        for i in range(c.num_env):
            count = t['n'][c.freq_res[i + 1]]
            if c.df_env[i]:
                for j in range(count):
                    if c.freq_res[i + 1] == c.freq_res[i]:
                        k = j
                    elif c.freq_res[i + 1]:
                        k = (j + odd) >> 1
                    else:
                        k = 2 * j - odd if j else 0
                    base = c.env_q[i][k]
                    lav = LAV[tt]
                    choices = [d for d in range(-lav, lav + 1) if 0 <= base + delta * d <= top]
                    d = r.choice(choices) if choices else 0
                    if not choices:
                        d = max(-lav, min(lav, -base // delta))
                    c.env_q[i + 1][j] = base + delta * d
                    bits.put(*CODES[tt][d])
            else:
                first = r.randrange(top // delta + 1)
                bits.put(first, fbits)
                c.env_q[i + 1][0] = delta * first
                for j in range(1, count):
                    base = c.env_q[i + 1][j - 1]
                    lav = LAV[ft]
                    choices = [d for d in range(-lav, lav + 1) if 0 <= base + delta * d <= top]
                    d = r.choice(choices)
                    c.env_q[i + 1][j] = base + delta * d
                    bits.put(*CODES[ft][d])
        c.env_q[0] = list(c.env_q[c.num_env])

    def _noise(self, r, bits, c, index):
        balance = self.coupling and index == 1
        delta = 2 if balance else 1
        tt, ft = (NOISEBAL30_T, BAL30_F) if balance else (NOISE30_T, ENV30_F)
        top = 24 if balance else 30
        for i in range(c.num_noise):
            if c.df_noise[i]:
                for j in range(self.tables['n_q']):
                    base = c.noise_q[i][j]
                    choices = [d for d in range(-LAV[tt], LAV[tt] + 1) if 0 <= base + delta * d <= top]
                    d = 0 if self.steady and not balance else r.choice(choices)
                    c.noise_q[i + 1][j] = base + delta * d
                    bits.put(*CODES[tt][d])
            else:
                first = top // delta if self.steady and not balance else r.randrange(top // delta + 1)
                bits.put(first, 5)
                c.noise_q[i + 1][0] = delta * first
                for j in range(1, self.tables['n_q']):
                    base = c.noise_q[i + 1][j - 1]
                    choices = [d for d in range(-LAV[ft], LAV[ft] + 1) if 0 <= base + delta * d <= top]
                    d = 0 if self.steady and not balance else r.choice(choices)
                    c.noise_q[i + 1][j] = base + delta * d
                    bits.put(*CODES[ft][d])
        c.noise_q[0] = list(c.noise_q[c.num_noise])

    def _harmonic(self, r, bits, c):
        c.harmonic_flag = not self.steady and r.random() < 0.5
        bits.put(int(c.harmonic_flag), 1)
        c.harmonic = [0] * 48
        if c.harmonic_flag:
            self.used.add('sinusoids')
            for i in range(self.tables['n'][1]):
                c.harmonic[i] = int(r.random() < 0.25)
                bits.put(c.harmonic[i], 1)

    # Signal processing --------------------------------------------------
    def dequant(self):
        t = self.tables
        a, b = self.ch
        if self.channels == 2 and self.coupling:
            pan = 12 if a.amp_res else 24
            a.env, b.env = [[0.0] * 48 for _ in range(6)], [[0.0] * 48 for _ in range(6)]
            for e in range(1, a.num_env + 1):
                for k in range(t['n'][a.freq_res[e]]):
                    scale = 1.0 if a.amp_res else 0.5
                    t1 = 2.0 ** (a.env_q[e][k] * scale + 7)
                    t2 = 2.0 ** ((pan - b.env_q[e][k]) * scale)
                    fac = t1 / (1.0 + t2)
                    a.env[e][k], b.env[e][k] = fac, fac * t2
            a.noise, b.noise = [[0.0] * 5 for _ in range(3)], [[0.0] * 5 for _ in range(3)]
            for e in range(1, a.num_noise + 1):
                for k in range(t['n_q']):
                    t1 = 2.0 ** (NOISE_OFFSET - a.noise_q[e][k] + 1)
                    t2 = 2.0 ** (12 - b.noise_q[e][k])
                    fac = t1 / (1.0 + t2)
                    a.noise[e][k], b.noise[e][k] = fac, fac * t2
        else:
            for c in self.ch[:self.channels]:
                scale = 1.0 if c.amp_res else 0.5
                c.env = [[2.0 ** (q * scale + 6) for q in row] for row in c.env_q]
                c.noise = [[2.0 ** (NOISE_OFFSET - q) for q in row] for row in c.noise_q]

    def apply(self, pcm):
        """pcm: per channel 1024 core samples (+-1) -> per channel 2048 samples."""
        if not self.pushed:
            self.kx[0], self.m[0] = self.kx[1], self.m[1]
        else:
            self.pushed = False
        if self.start and not self.ready:
            self.turnoff()
        if self.start:
            self.dequant()
            self.ready = False
        out = []
        for index in range(self.channels):
            c = self.ch[index]
            c.W[c.ypos] = c.analysis(pcm[index])
            x_low = self._lf_gen(c)
            c.ypos ^= 1
            if self.start:
                alpha0, alpha1 = self._inverse_filter(x_low)
                self._chirp(c)
                x_high = self._hf_gen(c, x_low, alpha0, alpha1)
                self._adjust(c, x_high)
            X = self._x_gen(c, x_low)
            if self.ps is not None:
                R = [list(row) for row in X]
                if self.ps.start:
                    self.ps.apply(X, R, self.kx[1] + self.m[1])
                return [c.synthesis(X), self.ch[1].synthesis(R)]
            out.append(c.synthesis(X))
        return out

    def _lf_gen(self, c):
        x_low = [[0j] * 40 for _ in range(32)]
        cur, prev = c.W[c.ypos], c.W[c.ypos ^ 1]
        for k in range(self.kx[1]):
            for i in range(8, 40):
                x_low[k][i] = cur[i - 8][k]
        for k in range(self.kx[0]):
            for i in range(8):
                x_low[k][i] = prev[i + 24][k]
        return x_low

    def _inverse_filter(self, x_low):
        alpha0, alpha1 = [0j] * 64, [0j] * 64
        for k in range(self.tables['k0']):
            x = x_low[k]
            phi = {}
            for (i, j) in ((0, 1), (0, 2), (1, 1), (1, 2), (2, 2)):
                # phi(i, j) = sum_{n=0}^{37} x[n - i + 2] * conj(x[n - j + 2])
                phi[(i, j)] = sum(x[n - i + 2] * x[n - j + 2].conjugate() for n in range(38))
            d = (phi[(2, 2)].real * phi[(1, 1)].real - abs(phi[(1, 2)]) ** 2 / (1.0 + 1e-6))
            a1 = 0j if d == 0 else (phi[(0, 1)] * phi[(1, 2)] - phi[(0, 2)] * phi[(1, 1)].real) / d
            a0 = 0j if phi[(1, 1)].real == 0 else -(phi[(0, 1)] + a1 * phi[(1, 2)].conjugate()) / phi[(1, 1)].real
            if abs(a1) ** 2 >= 16 or abs(a0) ** 2 >= 16:
                a0 = a1 = 0j
            alpha0[k], alpha1[k] = a0, a1
        return alpha0, alpha1

    def _chirp(self, c):
        table = [0.0, 0.75, 0.9, 0.98]
        for i in range(self.tables['n_q']):
            new = 0.6 if c.invf[0][i] + c.invf[1][i] == 1 else table[c.invf[0][i]]
            if new < c.bw[i]:
                new = 0.75 * new + 0.25 * c.bw[i]
            else:
                new = 0.90625 * new + 0.09375 * c.bw[i]
            c.bw[i] = 0.0 if new < 0.015625 else new

    def _hf_gen(self, c, x_low, alpha0, alpha1):
        t = self.tables
        x_high = [[0j] * 40 for _ in range(64)]
        k = self.kx[1]
        g = 0
        for size, start in zip(t['patch_sizes'], t['patch_starts']):
            for x in range(size):
                p = start + x
                while g <= t['n_q'] and k >= t['f_noise'][g]:
                    g += 1
                g -= 1
                bw = c.bw[g]
                a0, a1 = alpha0[p] * bw, alpha1[p] * bw * bw
                for i in range(2 * c.t_env[0] + ENV_OFFSET, 2 * c.t_env[c.num_env] + ENV_OFFSET):
                    x_high[k][i] = x_low[p][i] + a0 * x_low[p][i - 1] + a1 * x_low[p][i - 2]
                k += 1
        return x_high

    def _adjust(self, c, x_high):
        t, h = self.tables, self.header
        kx, m_max = self.kx[1], self.m[1]
        # Mapping.
        e_orig, q_mapped, s_mapped = [], [], []
        new_index = [[0] * 48 for _ in range(c.num_env + 1)]
        new_index[0] = list(c.s_index[0])
        for e in range(c.num_env):
            table = t['f_high'] if c.freq_res[e + 1] else t['f_low']
            eo, qm, sm = [0.0] * 48, [0.0] * 48, [0] * 48
            for i in range(len(table) - 1):
                for m in range(table[i], table[i + 1]):
                    eo[m - kx] = c.env[e + 1][i]
            kq = 1 if c.num_noise > 1 and c.t_env[e] >= c.t_q[1] else 0
            for i in range(t['n_q']):
                for m in range(t['f_noise'][i], t['f_noise'][i + 1]):
                    qm[m - kx] = c.noise[kq + 1][i]
            if c.harmonic_flag:
                for i in range(t['n'][1]):
                    mid = (t['f_high'][i] + t['f_high'][i + 1]) >> 1
                    new_index[e + 1][mid - kx] = c.harmonic[i] * \
                        (e >= c.e_a[1] or c.s_index[0][mid - kx] == 1)
            for i in range(len(table) - 1):
                present = any(new_index[e + 1][m - kx] for m in range(table[i], table[i + 1]))
                for m in range(table[i], table[i + 1]):
                    sm[m - kx] = int(present)
            e_orig.append(eo)
            q_mapped.append(qm)
            s_mapped.append(sm)
        c.s_index = new_index + [[0] * 48 for _ in range(8 - len(new_index))]
        c.s_index[0] = list(new_index[c.num_env])
        # Current envelope.
        e_curr = []
        for e in range(c.num_env):
            lo, hi = 2 * c.t_env[e] + ENV_OFFSET, 2 * c.t_env[e + 1] + ENV_OFFSET
            row = [0.0] * 48
            if h['interpol_freq']:
                for m in range(m_max):
                    row[m] = sum(abs(v) ** 2 for v in x_high[m + kx][lo:hi]) / (2 * (c.t_env[e + 1] - c.t_env[e]))
            else:
                table = t['f_high'] if c.freq_res[e + 1] else t['f_low']
                for p in range(len(table) - 1):
                    total = sum(abs(v) ** 2 for k in range(table[p], table[p + 1]) for v in x_high[k][lo:hi])
                    total /= (hi - lo) * (table[p + 1] - table[p])
                    for k in range(table[p], table[p + 1]):
                        row[k - kx] = total
            e_curr.append(row)
        # Gains.
        gains, q_m, s_m = [], [], []
        for e in range(c.num_env):
            delta = 0 if e in c.e_a else 1
            g, qmv, smv = self.gain[e], self.q_m[e], self.s_m[e]
            for k in range(len(t['f_lim']) - 1):
                band = range(t['f_lim'][k] - kx, t['f_lim'][k + 1] - kx)
                for m in band:
                    temp = e_orig[e][m] / (1.0 + q_mapped[e][m])
                    qmv[m] = math.sqrt(temp * q_mapped[e][m])
                    smv[m] = math.sqrt(temp * c.s_index[e + 1][m] if e + 1 <= c.num_env else 0)
                    if not s_mapped[e][m]:
                        g[m] = math.sqrt(e_orig[e][m] / ((1.0 + e_curr[e][m]) * (1.0 + q_mapped[e][m] * delta)))
                    else:
                        g[m] = math.sqrt(e_orig[e][m] * q_mapped[e][m] /
                                         ((1.0 + e_curr[e][m]) * (1.0 + q_mapped[e][m])))
                    g[m] += 1.1754943508222875e-38
                s0 = sum(e_orig[e][m] for m in band)
                s1 = sum(e_curr[e][m] for m in band)
                gain_max = LIMITER_GAINS[h['limiter_gains']] * math.sqrt((1.1920929e-07 + s0) / (1.1920929e-07 + s1))
                gain_max = min(100000.0, gain_max)
                for m in band:
                    qmv[m] = min(qmv[m], qmv[m] * gain_max / g[m])
                    g[m] = min(g[m], gain_max)
                s0 = sum(e_orig[e][m] for m in band)
                s1 = sum(e_curr[e][m] * g[m] * g[m] + smv[m] * smv[m] +
                         (delta and not smv[m]) * qmv[m] * qmv[m] for m in band)
                boost = min(1.584893192, math.sqrt((1.1920929e-07 + s0) / (1.1920929e-07 + s1)))
                for m in band:
                    g[m] *= boost
                    qmv[m] *= boost
                    smv[m] *= boost
            gains.append(g)
            q_m.append(qmv)
            s_m.append(smv)
        # Assembly into Y[ypos] slots.
        Y = c.Y[c.ypos]
        h_sl = 0 if h['smoothing'] else 4
        if self.reset:
            for i in range(h_sl):
                c.g_temp[i + 2 * c.t_env[0]] = list(gains[0])
                c.q_temp[i + 2 * c.t_env[0]] = list(q_m[0])
        elif h_sl:
            for i in range(4):
                c.g_temp[i + 2 * c.t_env[0]] = list(c.g_temp[i + 2 * c.t_env_old])
                c.q_temp[i + 2 * c.t_env[0]] = list(c.q_temp[i + 2 * c.t_env_old])
        for e in range(c.num_env):
            for i in range(2 * c.t_env[e], 2 * c.t_env[e + 1]):
                c.g_temp[h_sl + i] = list(gains[e])
                c.q_temp[h_sl + i] = list(q_m[e])
        noise, sine = c.index_noise, c.index_sine
        for e in range(c.num_env):
            for i in range(2 * c.t_env[e], 2 * c.t_env[e + 1]):
                if h_sl and e not in c.e_a:
                    g_filt = [sum(c.g_temp[i + h_sl - j][m] * SMOOTH[j] for j in range(h_sl + 1)) for m in range(48)]
                    q_filt = [sum(c.q_temp[i + h_sl - j][m] * SMOOTH[j] for j in range(h_sl + 1)) for m in range(48)]
                else:
                    g_filt, q_filt = c.g_temp[i + h_sl], c.q_temp[i]
                row = Y[i]
                for m in range(m_max):
                    row[m + kx] = x_high[m + kx][i + ENV_OFFSET] * g_filt[m]
                if e not in c.e_a:
                    for m in range(m_max):
                        idx = (noise + m + 1) & 511
                        if s_m[e][m]:
                            row[m + kx] += s_m[e][m] * _phase(sine, m + kx)
                        else:
                            row[m + kx] += q_filt[m] * NOISE_TABLE[idx]
                else:
                    for m in range(m_max):
                        row[m + kx] += s_m[e][m] * _phase(sine, m + kx)
                noise = (noise + m_max) & 511
                sine = (sine + 1) & 3
        c.index_noise, c.index_sine = noise, sine

    def _x_gen(self, c, x_low):
        X = [[0j] * 64 for _ in range(38)]
        i_temp = max(2 * c.t_env_old - 32, 0) if self.start or True else 0
        y_old, y_new = c.Y[c.ypos ^ 1], c.Y[c.ypos]
        for k in range(self.kx[0]):
            for i in range(i_temp):
                X[i][k] = x_low[k][i + ENV_OFFSET]
        for k in range(self.kx[0], self.kx[0] + self.m[0]):
            for i in range(i_temp):
                X[i][k] = y_old[i + 32][k]
        for k in range(self.kx[1]):
            for i in range(i_temp, 38):
                X[i][k] = x_low[k][i + ENV_OFFSET]
        for k in range(self.kx[1], self.kx[1] + self.m[1]):
            for i in range(i_temp, 32):
                X[i][k] = y_new[i][k]
        return X


def _phase(sine, k):
    """phi_sin(sine index) for subband k: +1, +j(-1)^k, -1, -j(-1)^k."""
    sign = 1 - 2 * (k & 1)
    return (1, 1j * sign, -1, -1j * sign)[sine]
