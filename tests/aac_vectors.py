"""Random valid AAC-LC raw data blocks in ADTS frames for decoder comparisons.

Frames follow ISO/IEC 14496-3 subpart 4: random window sequences, shapes and
short-window groupings; sections with every spectral book, zero, noise and
(in common-window pairs) intensity bands; scalefactor, noise-energy and
intensity-position deltas; pulse data, TNS filters of every order, length,
direction, resolution and compression; M/S masks; escape values up to 8191;
data stream and fill elements. Codewords come from the decoder's generated
tables (src/aac_tables.inc), whose codebooks FFmpeg checks independently by
decoding the same streams.

Two places where FFmpeg 6.1 differs from ISO/IEC 14496-3 are avoided, so
FFmpeg stays a valid oracle: noise bands of both channels under an explicit
M/S bit (ISO correlates the noise) and intensity bands with
ms_mask_present = 2 (ISO does not invert them). correlated_noise_stream()
builds the first case for a separate property check.
"""
from pathlib import Path
import random
import re

ROOT = Path(__file__).resolve().parent.parent
RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000)
PAIR_MOD = {5: 9, 6: 9, 7: 8, 8: 8, 9: 13, 10: 13, 11: 17}
# Coding tools the generator may use; tests can switch them off to isolate one.
TOOLS = {'transition': True, 'kbd': True, 'short': True, 'noise': True, 'intensity': True, 'ms': True, 'pulse': True, 'tns': True, 'escape': True,
         'extras': True}


def _tables():
    text = (ROOT / 'src' / 'aac_tables.inc').read_text()

    def array(name):
        body = text.split(name + ':\n', 1)[1]
        values = []
        for line in body.splitlines():
            line = line.strip()
            if not line.startswith('.short'):
                break
            values += [int(v) for v in line[6:].split(',')]
        return values
    books, entries = array('aac_huff_books'), array('aac_huff_table')
    codes = []
    for book in range(12):
        base, bits = books[2 * book], books[2 * book + 1]
        found = {}
        for index in range(1 << bits):
            entry = entries[base + index]
            if entry & 0x8000:
                extra, offset = entry & 15, (entry >> 4) & 0x7ff
                for j in range(1 << extra):
                    leaf = entries[base + offset + j]
                    length, symbol = leaf & 31, (leaf >> 5) & 0x1ff
                    found[symbol] = (((index << extra) | j) >> (bits + extra - length), length)
            else:
                length, symbol = entry & 31, (entry >> 5) & 0x1ff
                found[symbol] = (index >> (bits - length), length)
        codes.append(found)
    offsets = array('aac_swb_offsets')
    info = []
    body = text.split('aac_rate_info:\n', 1)[1]
    numbers = [int(v) for v in re.findall(r'-?\d+', body)]
    for i in range(0, len(numbers), 7):
        rate, long_start, short_start, long_bands, short_bands, tns_long, tns_short = numbers[i:i + 7]
        info.append({'long': offsets[long_start:long_start + long_bands + 1],
                     'short': offsets[short_start:short_start + short_bands + 1]})
    return codes, info


CODES, BANDS = _tables()


class Bits:
    def __init__(self):
        self.value, self.count = 0, 0

    def put(self, value, count):
        assert 0 <= value < (1 << count) or count == 0
        self.value = (self.value << count) | value
        self.count += count

    def code(self, book, symbol):
        code, length = CODES[book][symbol]
        self.put(code, length)

    def data(self):
        pad = -self.count % 8
        return (self.value << pad).to_bytes((self.count + pad) // 8, 'big')


# TNS coefficients whose FFmpeg 6.1 table constants are one float step from
# the correctly rounded sin() of ISO/IEC 14496-3; near-unstable random
# filters would amplify that step. LAMP uses the correctly rounded values.
TNS_ROUNDED = {3: {-2}, 4: {1, -7}}


# Window sequences an encoder may follow each one with (ONLY_LONG 0,
# LONG_START 1, EIGHT_SHORT 2, LONG_STOP 3); FFmpeg treats other transitions
# as short-to-short, which ISO does not.
NEXT = {0: (0, 0, 1), 1: (2, 3), 2: (2, 2, 3), 3: (0, 1)}


def _next_sequences(previous):
    options = set(NEXT[previous[0]])
    for p in previous[1:]:
        options &= set(NEXT[p])
    if not TOOLS['short']:
        options.discard(2)
    if not TOOLS['transition']:
        options = {0} if 0 in options else options
    return sorted(options)


def _info(r, rate_index, previous=(0,), short_bias=0.3):
    options = _next_sequences(previous)
    shorts = [s for s in options if s == 2]
    sequence = shorts[0] if shorts and r.random() < 0.7 else r.choice(options)
    info = {'sequence': sequence, 'shape': r.randrange(2) if TOOLS['kbd'] else 0}
    if sequence == 2:
        bands = BANDS[rate_index]['short']
        info['grouping'] = r.randrange(128)
        lengths = [1]
        for bit in range(6, -1, -1):
            if info['grouping'] >> bit & 1:
                lengths[-1] += 1
            else:
                lengths.append(1)
        info['groups'] = lengths
    else:
        bands = BANDS[rate_index]['long']
        info['groups'] = [1]
    info['offsets'] = bands
    info['max_sfb'] = r.randrange(len(bands)) if r.random() < 0.85 else len(bands) - 1
    return info


def _write_info(bits, info):
    bits.put(0, 1)
    bits.put(info['sequence'], 2)
    bits.put(info['shape'], 1)
    if info['sequence'] == 2:
        bits.put(info['max_sfb'], 4)
        bits.put(info['grouping'], 7)
    else:
        bits.put(info['max_sfb'], 6)
        bits.put(0, 1)


def _channel(r, info, second=False, common=False):
    """Plans one individual_channel_stream: band types and scalefactor deltas."""
    max_sfb, groups = info['max_sfb'], info['groups']
    types = []
    for _ in groups:
        k = 0
        while k < max_sfb:
            length = r.randint(1, max_sfb - k)
            choices = list(range(12)) + ([13, 13] if TOOLS['noise'] else [])
            if second and common and TOOLS['intensity']:
                choices += [14, 15, 14, 15]
            types += [r.choice(choices)] * length
            k += length
    return {'types': types, 'gain': r.randint(90, 160)}


def _write_channel(r, bits, info, plan, common, short_window):
    max_sfb, groups, types = info['max_sfb'], info['groups'], plan['types']
    bits.put(plan['gain'], 8)
    if not common:
        _write_info(bits, info)
    # Section data: runs of equal band types per group.
    section_bits = 3 if short_window else 5
    escape = (1 << section_bits) - 1
    for g in range(len(groups)):
        k = 0
        while k < max_sfb:
            band_type = types[g * max_sfb + k]
            end = k
            while end < max_sfb and types[g * max_sfb + end] == band_type:
                end += 1
            # Split long runs randomly into adjacent sections of the same book.
            length = r.randint(1, end - k)
            bits.put(band_type, 4)
            remaining = length
            while remaining >= escape:
                bits.put(escape, section_bits)
                remaining -= escape
            bits.put(remaining, section_bits)
            k += length
    # Scalefactors: deltas kept small and inside the valid ranges.
    sf, noise, position, first_noise = plan['gain'], plan['gain'] - 90, 0, True
    for band_type in types:
        if band_type == 0:
            continue
        if band_type == 13:
            if first_noise:
                target = r.randint(-20, 40)
                bits.put(target - noise + 256, 9)
                noise, first_noise = target, False
            else:
                delta = r.randint(max(-10, -20 - noise), min(10, 40 - noise))
                bits.code(0, delta + 60)
                noise += delta
        elif band_type >= 14:
            delta = r.randint(max(-6, -24 - position), min(6, 24 - position))
            bits.code(0, delta + 60)
            position += delta
        else:
            delta = r.randint(max(-8, 60 - sf), min(8, 200 - sf))
            bits.code(0, delta + 60)
            sf += delta
    # Spectral values per band and window, planned before pulses refer to them.
    offsets = info['offsets']
    values = {}
    window = 0
    for g, length in enumerate(groups):
        for band in range(max_sfb):
            book = types[g * max_sfb + band]
            for w in range(window, window + length):
                for k in range(offsets[band], offsets[band + 1]):
                    values[(w, k)] = _value(r, book)
        window += length
    # Pulse data (long windows): positions inside spectral-book bands.
    candidates = [k for band in range(max_sfb) if 1 <= types[band] <= 11
                  for k in range(offsets[band], offsets[band + 1])] if not short_window else []
    if candidates and r.random() < 0.4 and TOOLS['pulse']:
        bits.put(1, 1)
        count = r.randint(1, 4)
        start_band = min(band for band in range(max_sfb) if 1 <= types[band] <= 11)
        position = offsets[start_band]
        positions = []
        for _ in range(count):
            step = r.randint(0, 31)
            if position + step >= offsets[max_sfb]:
                step = 0
            position += step
            positions.append(position)
        bits.put(count - 1, 2)
        bits.put(start_band, 6)
        last = offsets[start_band]
        for position in positions:
            bits.put(position - last, 5)
            bits.put(r.randrange(16), 4)
            last = position
    else:
        bits.put(0, 1)
    # TNS: every parameter random.
    if r.random() < 0.5 and TOOLS['tns']:
        bits.put(1, 1)
        for _ in range(8 if short_window else 1):
            filters = r.randrange(2 if short_window else 4)
            bits.put(filters, 1 if short_window else 2)
            if not filters:
                continue
            resolution = r.randrange(2)
            bits.put(resolution, 1)
            for _ in range(filters):
                bits.put(r.randrange(16 if short_window else 64), 4 if short_window else 6)
                order = r.randint(0, 7 if short_window else 12)
                bits.put(order, 3 if short_window else 5)
                if order:
                    bits.put(r.randrange(2), 1)
                    compress = r.randrange(2)
                    bits.put(compress, 1)
                    width = resolution + 3 - compress
                    for _ in range(order):
                        while True:
                            # Mostly small reflection coefficients, as encoders
                            # produce; every value still occurs. Many values near
                            # +-1 at high orders give filters whose gain makes
                            # float rounding audible.
                            if r.random() < 0.85:
                                signed = r.randint(-(1 << (width - 2)), (1 << (width - 2)) - 1)
                            else:
                                signed = r.randint(-(1 << (width - 1)), (1 << (width - 1)) - 1)
                            code = signed & ((1 << width) - 1)
                            if signed not in TNS_ROUNDED[resolution + 3]:
                                break
                        bits.put(code, width)
    else:
        bits.put(0, 1)
    bits.put(0, 1)                                   # no gain control
    # Spectral data: codewords of 4 or 2 values in band and window order.
    window = 0
    for g, length in enumerate(groups):
        for band in range(max_sfb):
            book = types[g * max_sfb + band]
            if not 1 <= book <= 11:
                continue
            for w in range(window, window + length):
                k = offsets[band]
                while k < offsets[band + 1]:
                    size = 4 if book <= 4 else 2
                    _write_tuple(bits, book, [values[(w, k + i)] for i in range(size)])
                    k += size
        window += length


def _value(r, book):
    if book == 0 or book >= 12:
        return 0
    limit = {1: 1, 2: 1, 3: 2, 4: 2, 5: 4, 6: 4, 7: 7, 8: 7, 9: 12, 10: 12, 11: 16}[book]
    if r.random() < 0.35:
        return 0
    magnitude = r.randint(0, limit)
    if book == 11 and magnitude == 16 and not TOOLS['escape']:
        magnitude = 15
    if book == 11 and magnitude == 16:
        magnitude = r.choice((16, 17, 31, 32, 255, 256, 1000, 4095, 4096, 8191, r.randint(16, 8191)))
    if book in (1, 2, 5, 6) or magnitude:
        return magnitude * r.choice((-1, 1)) if magnitude else 0
    return 0


def _write_tuple(bits, book, values):
    if book <= 4:
        if book <= 2:
            index = sum((v + 1) * m for v, m in zip(values, (27, 9, 3, 1)))
        else:
            index = sum(abs(v) * m for v, m in zip(values, (27, 9, 3, 1)))
    else:
        mod = PAIR_MOD[book]
        clipped = [min(abs(v), 16) for v in values]
        if book <= 6:
            index = (values[0] + 4) * mod + values[1] + 4
        else:
            index = clipped[0] * mod + clipped[1]
    bits.code(book, index)
    if book in (3, 4, 7, 8, 9, 10, 11):
        for v in values:
            if v:
                bits.put(1 if v < 0 else 0, 1)
    if book == 11:
        for v in values:
            if abs(v) >= 16:
                width = abs(v).bit_length() - 1        # 2^width <= |v| < 2^(width+1)
                bits.put((1 << (width - 4)) - 1, width - 4)
                bits.put(0, 1)
                bits.put(abs(v) - (1 << width), width)


def _extras(r, bits):
    if not TOOLS['extras']:
        return
    if r.random() < 0.2:                             # data stream element
        bits.put(4, 3)
        bits.put(r.randrange(16), 4)
        align = r.randrange(2)
        bits.put(align, 1)
        count = r.choice((0, 3, 254, 255, 300))
        bits.put(min(count, 255), 8)
        if count >= 255:
            bits.put(count - 255, 8)
        if align:
            bits.put(0, -bits.count % 8)
        for _ in range(count):
            bits.put(r.randrange(256), 8)
    if r.random() < 0.2:                             # fill element, not SBR
        bits.put(6, 3)
        count = r.choice((1, 5, 14, 15, 40))
        if count >= 15:
            bits.put(15, 4)
            bits.put(count - 14, 8)
        else:
            bits.put(count, 4)
        bits.put(r.choice((0, 1, 2)), 4)
        bits.put(0, 4)
        for _ in range(count - 1):
            bits.put(r.randrange(256), 8)


def frame(r, rate_index, channels, state):
    """One raw data block; state holds each channel's previous window sequence."""
    bits = Bits()
    _extras(r, bits)
    if channels == 1:
        info = _info(r, rate_index, (state[0],))
        state[0] = info['sequence']
        plan = _channel(r, info)
        bits.put(0, 3)
        bits.put(0, 4)
        _write_channel(r, bits, info, plan, False, info['sequence'] == 2)
    else:
        common = r.random() < 0.75 and bool(_next_sequences(state))
        bits.put(1, 3)
        bits.put(0, 4)
        bits.put(1 if common else 0, 1)
        if common:
            info = _info(r, rate_index, tuple(state))
            state[0] = state[1] = info['sequence']
            first, second = _channel(r, info), _channel(r, info, True, True)
            _write_info(bits, info)
            ms = r.randrange(3) if TOOLS['ms'] else 0
            if ms == 2 and any(t >= 14 for t in second['types']):
                ms = 1
            bits.put(ms, 2)
            if ms == 1:
                for a, b in zip(first['types'], second['types']):
                    both_noise = a == 13 and b == 13
                    bits.put(0 if both_noise else r.randrange(2), 1)
            _write_channel(r, bits, info, first, True, info['sequence'] == 2)
            _write_channel(r, bits, info, second, True, info['sequence'] == 2)
        else:
            for channel in range(2):
                info = _info(r, rate_index, (state[channel],))
                state[channel] = info['sequence']
                _write_channel(r, bits, info, _channel(r, info), False, info['sequence'] == 2)
    _extras(r, bits)
    bits.put(7, 3)
    return bits.data()


def adts(payload, rate_index, channels, crc=False):
    length = len(payload) + (9 if crc else 7)
    assert length < 8192
    header = Bits()
    header.put(0xfff, 12)
    header.put(0, 1)                                 # MPEG-4
    header.put(0, 2)
    header.put(0 if crc else 1, 1)
    header.put(1, 2)                                 # LC
    header.put(rate_index, 4)
    header.put(0, 1)
    header.put(channels, 3)
    header.put(0, 4)
    header.put(length, 13)
    header.put(0x7ff, 11)
    header.put(0, 2)
    if crc:
        header.put(0, 16)                            # not checked
    return header.data() + payload


def stream(seed, frames=24):
    r = random.Random(seed)
    rate_index = r.randrange(12)
    channels = r.choice((1, 2, 2))
    data = bytearray()
    state = [0, 0]
    for _ in range(frames):
        while True:
            saved = list(state)
            payload = frame(r, rate_index, channels, state)
            if len(payload) < 8000:
                break
            state[:] = saved
        data += adts(payload, rate_index, channels, crc=r.random() < 0.2)
    return bytes(data), RATES[rate_index], channels


def correlated_noise_stream(frames=8):
    """Common-window pairs whose bands are all noise in both channels with
    every M/S bit set and equal energies: ISO noise correlation makes the
    two channels identical."""
    r = random.Random(7)
    data = bytearray()
    for _ in range(frames):
        bits = Bits()
        info = _info(r, 4)
        while info['sequence'] != 0:
            info = _info(r, 4)
        info['max_sfb'] = len(info['offsets']) - 1
        bits.put(1, 3)
        bits.put(0, 4)
        bits.put(1, 1)
        _write_info(bits, info)
        bits.put(1, 2)
        bits.put((1 << info['max_sfb']) - 1, info['max_sfb'])
        for _ in range(2):
            bits.put(120, 8)
            bits.put(13, 4)
            remaining = info['max_sfb']
            while remaining >= 31:
                bits.put(31, 5)
                remaining -= 31
            bits.put(remaining, 5)
            bits.put(256 + 10, 9)                    # first noise energy 30 - 90 + 10
            for _ in range(info['max_sfb'] - 1):
                bits.code(0, 60)
            bits.put(0, 3)                           # no pulses, TNS or gain control
        bits.put(7, 3)
        data += adts(bits.data(), 4, 2)
    return bytes(data)


def _mono(element=0, sequence=0, max_sfb=1, book=1, predictor=0, pulse=0, gain_control=0, gain=100,
          sf_delta=0, escape_ones=None, before=None, rate_index=4):
    """One small mono raw data block, with fields that malformed cases change."""
    bits = Bits()
    if before:
        before(bits)
    bits.put(element, 3)
    bits.put(0, 4)
    bits.put(gain, 8)
    bits.put(0, 1)
    bits.put(sequence, 2)
    bits.put(0, 1)
    if sequence == 2:
        bits.put(max_sfb, 4)
        bits.put(0x7f, 7)                            # one group of eight
    else:
        bits.put(max_sfb, 6)
        bits.put(predictor, 1)
    if 0 < max_sfb <= 14:                            # larger counts reject before sections
        bits.put(book, 4)
        bits.put(1, 3 if sequence == 2 else 5)
        if max_sfb > 1:
            bits.put(0, 4)
            bits.put(max_sfb - 1, 3 if sequence == 2 else 5)
        bits.code(0, sf_delta + 60)
    bits.put(pulse, 1)
    if pulse:
        bits.put(0, 2)
        bits.put(0, 6)
        bits.put(0, 5)
        bits.put(1, 4)
    bits.put(0, 1)                                   # no TNS
    bits.put(gain_control, 1)
    if 0 < max_sfb <= 14 and 1 <= book <= 11:
        if escape_ones is not None:
            bits.code(11, 16 * 17)                   # (16, 0): escape, then zero
            bits.put(0, 1)
            bits.put((1 << escape_ones) - 1, escape_ones)
            bits.put(0, 1)
            bits.put(0, escape_ones + 4)
        else:
            size = 4 if book <= 4 else 2
            zero = {1: 40, 2: 40, 3: 0, 4: 0, 5: 40, 6: 40}.get(book, 0)
            for _ in range(BANDS[rate_index]['short' if sequence == 2 else 'long'][1] // size *
                           (8 if sequence == 2 else 1)):
                bits.code(book, zero)
    bits.put(7, 3)
    return bits.data()


def valid_mono_frame():
    return _mono()


def malformed():
    """name -> (ADTS bytes, expected decode_error): 100 malformed, 101 unsupported.
    The bad frame comes first, so opening (which decodes the first frame) fails."""
    good = valid_mono_frame()

    def stream(bad, channels=1, profile_frame=None):
        return (profile_frame or adts(bad, 4, channels)) + adts(good, 4, channels)

    def fill_sbr(bits):
        bits.put(6, 3)
        bits.put(2, 4)
        bits.put(13, 4)                              # EXT_SBR_DATA
        bits.put(0, 12)

    def coupling(bits):
        bits.put(2, 3)
    main = bytearray(adts(good, 4, 1))
    main[2] &= 0x3f                                  # profile 0: AAC Main
    truncated = adts(good, 4, 1)
    cases = {
        'sbr-fill': (stream(_mono(before=fill_sbr)), 101),
        'coupling-element': (stream(_mono(before=coupling)), 101),
        'gain-control': (stream(_mono(gain_control=1)), 101),
        'prediction': (stream(_mono(predictor=1)), 101),
        'main-profile': (bytes(main) + bytes(main), 101),
        'reserved-book': (stream(_mono(book=12)), 100),
        'intensity-single': (stream(_mono(book=14)), 100),
        'escape-overflow': (stream(_mono(book=11, escape_ones=9)), 100),
        'scalefactor-range': (stream(_mono(gain=10, sf_delta=-30)), 100),
        'max-sfb': (stream(_mono(max_sfb=60)), 100),
        'short-pulse': (stream(_mono(sequence=2, pulse=1)), 100),
        'element-layout': (stream(_mono(element=1)), 100),
        'packet-overrun': (adts(good[:-3], 4, 1) + adts(good, 4, 1), 100),
        'truncated-frame': (truncated + truncated[:-4], 100),
    }
    return cases
