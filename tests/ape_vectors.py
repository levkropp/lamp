"""Monkey's Audio streams written for the tests: what JMAC never writes.

LAMP's decoder follows FFmpeg's (libavcodec/apedec.c, libavformat/ape.c).
This writer inverts it step by step, so every stream decodes to the PCM it
was given: mid/side, the 3930 or 3950 predictor (the latter in 32- or
64-bit arithmetic), the cascade of sign-LMS filters of the compression
level (rounding in 32 bits as Monkey's Audio does), and the range coder with
the 3900 or the 3990 residual model. Headers are the descriptor form
(versions 3980-3990) or the earlier 32-byte header with its optional peak
level, seek element count and stored WAV header. Frames may carry flags
(silence, pseudo-stereo); the CRC covers the samples as the decoder checks
them. The data is a byte stream stored as little-endian 32-bit words, frames
starting at any byte.

write(pcm, channels, bits, rate, version, level, **options) -> (data, used)
pcm is a list of frames (tuples of channel values); used names the coding
features the stream exercised.
"""

COUNTS_3970 = [0, 14824, 28224, 39348, 47855, 53994, 58171, 60926, 62682, 63786, 64463, 64878, 65126, 65276,
               65365, 65419, 65450, 65469, 65480, 65487, 65491, 65493]
COUNTS_3980 = [0, 19578, 36160, 48417, 56323, 60899, 63265, 64435, 64971, 65232, 65351, 65416, 65447, 65466,
               65476, 65482, 65485, 65488, 65490, 65491, 65492, 65493]
ORDERS = [(), (16,), (64,), (32, 256), (16, 256, 1280)]
FRACBITS = [(), (11,), (11,), (10, 13), (11, 13, 15)]
INITIAL = (360, 317, -109, 98)
HISTORY, PRED_SIZE = 512, 50
YDELAYA, YDELAYB, XDELAYA, XDELAYB = 50, 42, 34, 26
YADAPTA, XADAPTA, YADAPTB, XADAPTB = 18, 14, 10, 5
M32 = 0xffffffff
CHUNK = 4608


def s16(x):
    x &= 0xffff
    return x - 0x10000 if x & 0x8000 else x


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def s64(x):
    x &= (1 << 64) - 1
    return x - (1 << 64) if x >> 63 else x


def apesign(x):
    return (x < 0) - (x > 0)


def crc32_table():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0xedb88320 if c & 1 else c >> 1
        table.append(c)
    return table


CRC_TABLE = crc32_table()


class RangeEncoder:
    """The range coder Monkey's Audio uses (Schindler's, 31-bit low), as
    FFmpeg's decoder reads it. The first byte written is the unused one."""
    TOP, BOTTOM, SHIFT = 1 << 31, 1 << 23, 23

    def __init__(self, out):
        self.out, self.low, self.range, self.buffer, self.help = out, 0, self.TOP, 0, 0

    def normalize(self):
        while self.range <= self.BOTTOM:
            if self.low < (0xff << self.SHIFT):
                self.out.append(self.buffer)
                self.out.extend(b'\xff' * self.help)
                self.help = 0
                self.buffer = self.low >> self.SHIFT
            elif self.low & self.TOP:
                self.out.append((self.buffer + 1) & 0xff)
                self.out.extend(b'\x00' * self.help)
                self.help = 0
                self.buffer = (self.low >> self.SHIFT) & 0xff
            else:
                self.help += 1
            self.range = (self.range << 8) & M32
            self.low = (self.low << 8) & (self.TOP - 1)

    def freq(self, below, width, total):
        self.normalize()
        r = self.range // total
        self.low += r * below
        self.range = r * width

    def bits(self, value, count):
        self.normalize()
        r = self.range >> count
        self.low += r * value
        self.range = r

    def finish(self):
        self.normalize()
        top = (self.low >> self.SHIFT) + 1
        if top > 0xff:
            self.out.append((self.buffer + 1) & 0xff)
            self.out.extend(b'\x00' * self.help)
        else:
            self.out.append(self.buffer)
            self.out.extend(b'\xff' * self.help)
        self.out.extend(bytes([top & 0xff, 0, 0, 0]))


def update_rice(rice, x):
    k, ksum = rice
    limit = (1 << (k + 4)) if k else 0
    ksum = (ksum + (((x + 1) & M32) >> 1) - (((ksum + 16) & M32) >> 5)) & M32
    if ksum < limit:
        k -= 1
    elif ksum >= (1 << (k + 5)) and k < 24:
        k += 1
    rice[0], rice[1] = k, ksum


def put_symbol(rc, counts, symbol):
    if symbol <= 20:
        rc.freq(counts[symbol], counts[symbol + 1] - counts[symbol], 1 << 16)
    else:
        rc.freq(65472 + symbol, 1, 1 << 16)


def put_value_3990(rc, rice, value, used):
    x = (2 * value - 1 if value > 0 else -2 * value) & M32
    pivot = max(rice[1] >> 5, 1)
    overflow, base = divmod(x, pivot)
    if overflow >= 63:
        put_symbol(rc, COUNTS_3980, 63)
        rc.bits(overflow >> 16, 16)
        rc.bits(overflow & 0xffff, 16)
        used.add('3990 escape')
    else:
        put_symbol(rc, COUNTS_3980, overflow)
    if pivot < 0x10000:
        rc.freq(base, 1, pivot)
    else:
        shift, high = 0, pivot
        while high & ~0xffff:
            high >>= 1
            shift += 1
        rc.freq(base >> shift, 1, high + 1)
        rc.freq(base & ((1 << shift) - 1), 1, 1 << shift)
        used.add('wide pivot')
    update_rice(rice, x)


def put_value_3900(rc, rice, value, used):
    x = (2 * value - 1 if value > 0 else -2 * value) & M32
    k = rice[0]
    count = k - 1 if k else 0
    if x >> count < 63:
        put_symbol(rc, COUNTS_3970, x >> count)
        low = x & ((1 << count) - 1)
    else:
        put_symbol(rc, COUNTS_3970, 63)
        count = max(x.bit_length(), 1)
        assert count <= 31
        rc.bits(count, 5)
        low = x
        used.add('3900 escape')
    if count <= 16:
        rc.bits(low, count)
    else:
        rc.bits(low & 0xffff, 16)
        rc.bits(low >> 16, count - 16)
        used.add('3900 wide bits')
    update_rice(rice, x)


class Filter:
    """One sign-LMS filter, inverted: input from the wanted output."""

    def __init__(self, order, fracbits, version):
        self.order, self.fracbits, self.version = order, fracbits, version
        self.coeffs = [0] * order
        self.hist = [0] * (2 * order + HISTORY)
        self.pos, self.avg = order, 0

    def input_for(self, output, used):
        n, a, h = self.order, self.pos, self.hist
        dot = s32(sum(c * d for c, d in zip(self.coeffs, h[a:a + n])))
        rounding = 1 << (self.fracbits - 1)
        if dot + rounding > 0x7fffffff:
            used.add('filter rounding wrap')         # FFmpeg rounds in 64 bits here
        value = s32(output - (s32(dot + rounding) >> self.fracbits))
        sign = apesign(value)
        if sign:
            self.coeffs = [s16(c + sign * d) for c, d in zip(self.coeffs, h[a - n:a])]
        h[a + n] = max(-32768, min(32767, output))
        if self.version >= 3980:
            absolute = abs(output) & M32
            if absolute:
                step = (absolute > self.avg * 3) + (absolute > ((self.avg + self.avg // 3) & M32))
                h[a] = apesign(output) * (8 << step)
            else:
                h[a] = 0
            difference = s32(absolute - self.avg)
            self.avg = (self.avg + int(difference / 16)) & M32
            h[a - 1] >>= 1
            h[a - 2] >>= 1
            h[a - 8] >>= 1
        else:
            h[a] = 0 if output == 0 else ((output >> 28) & 8) - 4
            h[a - 4] >>= 1
            h[a - 8] >>= 1
        self.pos += 1
        if self.pos == n + HISTORY:
            h[0:2 * n] = h[HISTORY:HISTORY + 2 * n]
            self.pos = n
        return value


class Predictor:
    """The 3930 or 3950 predictor, inverted."""

    def __init__(self, version, wide, used):
        self.version, self.wide, self.used = version, wide, used
        self.buf = [0] * (HISTORY + PRED_SIZE)
        self.i = 0
        self.last = [0, 0]
        self.filter_a = [0, 0]
        self.filter_b = [0, 0]
        self.ca = [list(INITIAL), list(INITIAL)]
        self.cb = [[0] * 5, [0] * 5]

    def advance(self):
        self.i += 1
        if self.i == HISTORY:
            self.buf[0:PRED_SIZE] = self.buf[HISTORY:HISTORY + PRED_SIZE]
            self.i = 0

    def stereo_3950(self, f, target):
        b, i = self.buf, self.i
        da, db, aa, ab = (YDELAYA, YDELAYB, YADAPTA, YADAPTB) if f == 0 else (XDELAYA, XDELAYB, XADAPTA, XADAPTB)
        b[i + da] = self.last[f]
        b[i + aa] = apesign(b[i + da])
        b[i + da - 1] = s64(b[i + da] - b[i + da - 1])
        b[i + aa - 1] = apesign(b[i + da - 1])
        pa = s64(sum(b[i + da - j] * self.ca[f][j] for j in range(4)))
        b[i + db] = s64(self.filter_a[f ^ 1] - (s64(self.filter_b[f] * 31) >> 5))
        b[i + ab] = apesign(b[i + db])
        b[i + db - 1] = s64(b[i + db] - b[i + db - 1])
        b[i + ab - 1] = apesign(b[i + db - 1])
        self.filter_b[f] = self.filter_a[f ^ 1]
        pb = s64(sum(b[i + db - j] * self.cb[f][j] for j in range(5)))
        previous = s64(self.filter_a[f] * 31) >> 5
        last = target - previous
        if self.wide:
            value = last - (s64(pa + (pb >> 1)) >> 10)
            assert -(1 << 31) <= value < (1 << 31)
            if s64(pa + (pb >> 1)) >> 10 != s32(s32(pa) + (s32(pb) >> 1)) >> 10:
                self.used.add('64-bit prediction beyond 32 bits')
        else:
            assert -(1 << 31) <= last < (1 << 31)
            value = s32(last - (s32(s32(pa) + (s32(pb) >> 1)) >> 10))
        self.last[f] = last
        self.filter_a[f] = last + previous
        sign = apesign(value)
        if sign:
            for j in range(4):
                self.ca[f][j] = s64(self.ca[f][j] + b[i + aa - j] * sign)
            for j in range(5):
                self.cb[f][j] = s64(self.cb[f][j] + b[i + ab - j] * sign)
        return value

    def mono_3950(self, target):
        b, i = self.buf, self.i
        b[i + YDELAYA] = self.last[0]
        b[i + YDELAYA - 1] = s64(b[i + YDELAYA] - b[i + YDELAYA - 1])
        pa = s32(sum(b[i + YDELAYA - j] * self.ca[0][j] for j in range(4)))
        previous = s64(self.filter_a[0] * 31) >> 5
        current = target - previous
        assert -(1 << 31) <= current < (1 << 31)
        value = s32(current - (pa >> 10))
        b[i + YADAPTA] = apesign(b[i + YDELAYA])
        b[i + YADAPTA - 1] = apesign(b[i + YDELAYA - 1])
        sign = apesign(value)
        if sign:
            for j in range(4):
                self.ca[0][j] = s64(self.ca[0][j] + b[i + YADAPTA - j] * sign)
        self.advance()
        self.filter_a[0] = current + previous
        self.last[0] = current
        return value

    def step_3930(self, f, target):
        b, i = self.buf, self.i
        da = YDELAYA if f == 0 else XDELAYA
        b[i + da] = self.last[f]
        d = [b[i + da], s32(b[i + da] - b[i + da - 1]), s32(b[i + da - 1] - b[i + da - 2]),
             s32(b[i + da - 2] - b[i + da - 3])]
        pa = s32(sum(x * c for x, c in zip(d, self.ca[f])))
        previous = s32(self.filter_a[f] * 31) >> 5
        last = s32(target - previous)
        value = s32(last - (pa >> 9))
        self.last[f] = last
        self.filter_a[f] = target
        sign = apesign(value)
        for j in range(4):
            self.ca[f][j] = s32(self.ca[f][j] + ((d[j] < 0) * 2 - 1) * sign)
        return value


def sample_bytes(value, bits):
    if bits == 8:
        return bytes([(value + 0x80) & 0xff])
    return (value & M32).to_bytes(4, 'little')[:bits // 8]


def encode_frame(frame, channels, bits, version, level, flags, wide, used):
    """frame: list of channel tuples -> the frame's bytes."""
    crc = M32
    for block in frame:
        for c in range(channels):
            for byte in sample_bytes(block[c], bits):
                crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >> 8)
    stored = (~crc & M32) >> 1
    out = bytearray()
    if flags is None:
        out += stored.to_bytes(4, 'big')
    else:
        out += (stored | 0x80000000).to_bytes(4, 'big') + flags.to_bytes(4, 'big')
    flags = flags or 0
    rc = RangeEncoder(out)
    mono = channels == 1 or flags & 4
    silent = (flags & 3) if mono else (flags & 3) == 3
    if not silent:
        filters = [[Filter(o, f, version) for o, f in zip(ORDERS[level - 1], FRACBITS[level - 1])] for _ in range(2)]
        predictor = Predictor(version, wide, used)
        rice = [[10, 16384], [10, 16384]]
        put = put_value_3990 if version >= 3990 else put_value_3900

        def residual(c, value):
            for flt in reversed(filters[c]):
                value = flt.input_for(value, used)
            return value
        for block in frame:
            if mono:
                if version >= 3950:
                    value = predictor.mono_3950(block[0])
                else:
                    value = predictor.step_3930(0, block[0])
                    predictor.advance()
                put(rc, rice[0], residual(0, value), used)
                continue
            left, right = block[0], block[1]
            side = s32(right - left)
            mid = s32(left + int(side / 2))
            if version >= 3950:
                y = predictor.stereo_3950(0, side)
                x = predictor.stereo_3950(1, mid)
                predictor.advance()
                put(rc, rice[0], residual(0, y), used)
                put(rc, rice[1], residual(1, x), used)
            else:
                second = predictor.step_3930(0, side)   # decodes from the second channel
                first = predictor.step_3930(1, mid)
                predictor.advance()
                put(rc, rice[0], residual(0, first), used)
                put(rc, rice[1], residual(1, second), used)
    rc.finish()
    return bytes(out)


def write(pcm, channels, bits, rate, version, level, frame_blocks=None, flags=None, wide=False, peak=False,
          seek_count=False, wav_header=True, tail=b'', lead=b'', trailer=b'', pad=0):
    """-> (file bytes, features used). flags: None (no flags word) or a
    function of the frame index giving flags or None. frame_blocks applies to
    versions 3980 and later; earlier versions have fixed frames."""
    used = {f'version {version}', f'level {level}000', f'{bits}-bit', 'mono' if channels == 1 else 'stereo'}
    if version >= 3980:
        bpf = frame_blocks or 73728
    else:
        bpf = 294912 if version >= 3950 else 73728
    frames = [pcm[i:i + bpf] for i in range(0, len(pcm), bpf)]
    stream, starts = bytearray(), []
    for index, frame in enumerate(frames):
        starts.append(len(stream))
        frame_flags = flags(index) if flags else None
        if frame_flags is not None:
            used.add('frame flags')
            if frame_flags & 4 and channels == 2:
                used.add('pseudo-stereo')
            if (frame_flags & 3) and (channels == 1 or frame_flags & 4):
                used.add('mono silence')
            elif (frame_flags & 3) == 3:
                used.add('stereo silence')
            elif frame_flags & 3:
                used.add('one silent channel flag (ignored)')
        stream += encode_frame(frame, channels, bits, version, level, frame_flags, wide, used)
        if starts[-1] & 3:
            used.add(f'frame at byte {starts[-1] & 3} of a word')
    stream += b'\0' * pad
    stream += b'\0' * (-len(stream) % 4)
    words = bytearray(len(stream))
    for k in range(0, len(stream), 4):
        words[k:k + 4] = stream[k:k + 4][::-1]
    final = len(frames[-1])
    wav = b''
    if wav_header:
        size = len(pcm) * channels * bits // 8
        wav = b'RIFF' + (36 + size).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little') + \
            (1).to_bytes(2, 'little') + channels.to_bytes(2, 'little') + rate.to_bytes(4, 'little') + \
            (rate * channels * bits // 8).to_bytes(4, 'little') + (channels * bits // 8).to_bytes(2, 'little') + \
            bits.to_bytes(2, 'little') + b'data' + size.to_bytes(4, 'little')
    le16 = lambda v: v.to_bytes(2, 'little')
    le32 = lambda v: v.to_bytes(4, 'little')
    if version >= 3980:
        table_size = 4 * len(frames)
        first = 52 + 24 + table_size + len(wav)
        descriptor = b'MAC ' + le16(version) + le16(0) + le32(52) + le32(24) + le32(table_size) + le32(len(wav)) + \
            le32(len(words)) + le32(0) + le32(len(tail)) + b'\0' * 16
        format_flags = 0 if wav_header else 32
        header = le16(level * 1000) + le16(format_flags) + le32(bpf) + le32(final) + le32(len(frames)) + \
            le16(bits) + le16(channels) + le32(rate)
        table = b''.join(le32(first + s) for s in starts)
        body = descriptor + header + table + wav
        used.add('descriptor')
    else:
        format_flags = (1 if bits == 8 else 8 if bits == 24 else 0) | (4 if peak else 0) | (16 if seek_count else 0) | \
            (0 if wav_header else 32)
        extra = (le32(12345) if peak else b'') + (le32(len(frames)) if seek_count else b'')
        first = 32 + len(extra) + 4 * len(frames) + len(wav)
        header = b'MAC ' + le16(version) + le16(level * 1000) + le16(format_flags) + le16(channels) + le32(rate) + \
            le32(len(wav)) + le32(len(tail)) + le32(len(frames)) + le32(final)
        table = b''.join(le32(first + s) for s in starts)
        body = header + extra + wav + table
        used.add('32-byte header')
        if peak:
            used.add('peak level')
        if seek_count:
            used.add('seek element count')
        if not wav_header:
            used.add('no stored WAV header')
    if tail:
        used.add('WAV tail')
    used.add('predictor 3950' if version >= 3950 else 'predictor 3930')
    if level > 1:
        used.add('adaption before 3980' if version < 3980 else 'adaption 3980')
    if wide:
        used.add('64-bit predictor')
    return lead + body + bytes(words) + tail + trailer, used
