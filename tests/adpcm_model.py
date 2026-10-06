"""Test-only models of G.711 and the IMA and Microsoft ADPCM WAVE codecs.

The G.711 expansion follows ITU-T G.711's decoding rules (as FFmpeg's
alaw2linear/ulaw2linear implement them). The IMA step and index tables are
those of the IMA Digital Audio Focus and Technical Working Groups'
"Recommended Practices for Enhancing Digital Audio Compatibility in
Multimedia Systems" (revision 3.00, 1992); the Microsoft ADPCM adaptation
and coefficient tables are those of Microsoft's "New Multimedia Data Types
and Data Techniques" (revision 3.0, 1994), which every WAVE_FORMAT_ADPCM fmt
chunk repeats. Block decoding matches FFmpeg 6.1 (adpcm_ima_wav with 4-bit
samples, adpcm_ms with one or two channels), which tests/verify-wav-codecs.py
checks; the writer makes random valid blocks for it.
"""
import random
import struct

IMA_STEPS = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
             97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
             724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
             4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
             18500, 20350, 22385, 24623, 27086, 29794, 32767]
IMA_INDEX = [-1, -1, -1, -1, 2, 4, 6, 8] * 2
MS_ADAPT = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]
MS_COEFF1 = [256, 512, 0, 192, 240, 460, 392]
MS_COEFF2 = [0, -256, 0, 64, 0, -208, -232]
assert len(IMA_STEPS) == 89


def alaw(code):
    code ^= 0x55
    t = code & 0xf
    seg = (code & 0x70) >> 4
    t = (t + t + 1 + 32) << (seg + 2) if seg else (t + t + 1) << 3
    return t if code & 0x80 else -t


def ulaw(code):
    code = ~code & 0xff
    t = ((code & 0xf) << 3) + 0x84
    t <<= (code & 0x70) >> 4
    return 0x84 - t if code & 0x80 else t - 0x84


ALAW = [alaw(i) for i in range(256)]
ULAW = [ulaw(i) for i in range(256)]


def clip16(v):
    return max(-32768, min(32767, v))


def tdiv(a, b):
    return -(-a // b) if a < 0 else a // b


def ima_samples(size, channels):
    """Samples per channel of an IMA block of the given size (FFmpeg)."""
    if size < 4 * channels:
        return 0
    return 1 + (size - 4 * channels) // (4 * channels) * 8


def ms_samples(size, channels):
    if size < 7 * channels:
        return 0
    return 2 + (size - 7 * channels) * 2 // channels


class DecodeError(Exception):
    pass


def ima_block(block, channels, used=None):
    """-> list of channels (int16 lists)."""
    n = ima_samples(len(block), channels)
    out, state = [], []
    for c in range(channels):
        predictor, index = struct.unpack_from('<hh', block, 4 * c)
        if not 0 <= index <= 88:
            raise DecodeError('step index')
        state.append([predictor, index])
        out.append([predictor])
    pos = 4 * channels
    for _ in range((n - 1) // 8):
        for c in range(channels):
            s = state[c]
            for k in range(4):
                byte = block[pos]
                pos += 1
                for nibble in (byte & 15, byte >> 4):
                    step = IMA_STEPS[s[1]]
                    if used is not None:
                        used.add(s[1])
                    diff = ((2 * (nibble & 7) + 1) * step) >> 3
                    s[0] = clip16(s[0] - diff if nibble & 8 else s[0] + diff)
                    s[1] = max(0, min(88, s[1] + IMA_INDEX[nibble]))
                    out[c].append(s[0])
    return out


def ms_block(block, channels, used=None):
    n = ms_samples(len(block), channels)
    state = [{} for _ in range(channels)]
    pos = 0
    for c in range(channels):
        k = block[pos]
        pos += 1
        if k > 6:
            raise DecodeError('predictor')
        if used is not None:
            used.add(k)
        state[c]['c1'], state[c]['c2'] = MS_COEFF1[k], MS_COEFF2[k]
    for key in ('delta', 's1', 's2'):
        for c in range(channels):
            state[c][key] = struct.unpack_from('<h', block, pos)[0]
            pos += 2
    out = [[s['s2'], s['s1']] for s in state]
    last = channels - 1
    for _ in range((n - 2) * channels // 2):
        byte = block[pos]
        pos += 1
        for c, nibble in ((0, byte >> 4), (last, byte & 15)):
            s = state[c]
            p = tdiv(s['s1'] * s['c1'] + s['s2'] * s['c2'], 256) + (nibble - 16 if nibble & 8 else nibble) * s['delta']
            s['s2'], s['s1'] = s['s1'], clip16(p)
            s['delta'] = max(16, min((MS_ADAPT[nibble] * s['delta']) >> 8, 0x7fffffff // 768))
            out[c].append(s['s1'])
    return out


def decode(data, tag, channels, align):
    """Data chunk -> interleaved int16 samples (FFmpeg's blocks: full ones,
    then a partial last block if it holds a header)."""
    pcm = []
    for start in range(0, len(data), align):
        block = data[start:start + align]
        if len(block) < (4 if tag == 0x11 else 7) * channels:
            break
        chans = ima_block(block, channels) if tag == 0x11 else ms_block(block, channels)
        for i in range(len(chans[0])):
            pcm += [c[i] for c in chans]
    return pcm


def random_ima(r, channels, align, blocks, partial=0):
    """Random valid IMA blocks (any nibbles are valid; headers keep the step
    index in range, with edge predictors and indexes)."""
    out = bytearray()
    for b in range(blocks + (1 if partial else 0)):
        size = partial if b == blocks else align
        block = bytearray(r.getrandbits(8) for _ in range(max(size, 4 * channels)))
        for c in range(channels):
            predictor = r.choice((-32768, 32767, 0, r.randint(-32768, 32767)))
            index = r.choice((0, 88, r.randint(0, 88)))
            struct.pack_into('<hh', block, 4 * c, predictor, index)
        out += block[:size]
    return bytes(out)


def random_ms(r, channels, align, blocks, partial=0):
    """Random valid Microsoft ADPCM blocks: every predictor, and deltas from
    negative to large."""
    out = bytearray()
    for b in range(blocks + (1 if partial else 0)):
        size = partial if b == blocks else align
        block = bytearray(r.getrandbits(8) for _ in range(max(size, 7 * channels)))
        pos = 0
        for c in range(channels):
            block[pos] = (b * channels + c) % 7
            pos += 1
        for c in range(channels):
            struct.pack_into('<h', block, pos, r.choice((16, -5, 0, 32767, r.randint(16, 3000))))
            pos += 2
        for _ in range(2 * channels):
            struct.pack_into('<h', block, pos, r.randint(-32768, 32767))
            pos += 2
        out += block[:size]
    return bytes(out)


def wave(tag, channels, rate, align, data, fact=None, extra=b''):
    """A WAVE file with an ADPCM fmt chunk (cbSize and its extension)."""
    if tag == 0x11:
        per_block = ima_samples(align, channels)
        ext = struct.pack('<H', per_block)
        bits = 4
    else:
        per_block = ms_samples(align, channels)
        ext = struct.pack('<HH', per_block, 7) + b''.join(struct.pack('<hh', a, b) for a, b in zip(MS_COEFF1, MS_COEFF2))
        bits = 4
    rate_bytes = rate * align // per_block
    fmt = struct.pack('<HHIIHHH', tag, channels, rate, rate_bytes, align, bits, len(ext)) + ext
    chunks = [(b'fmt ', fmt)]
    if fact is not None:
        chunks.append((b'fact', struct.pack('<I', fact)))
    chunks += [(b'data', data)]
    body = b''.join(cid + struct.pack('<I', len(p)) + p + (b'\0' if len(p) & 1 else b'') for cid, p in chunks)
    return b'RIFF' + struct.pack('<I', 4 + len(body) + len(extra)) + b'WAVE' + body + extra


if __name__ == '__main__':
    r = random.Random(1)
    print(len(random_ima(r, 2, 1024, 3)), len(random_ms(r, 2, 1024, 3)))
