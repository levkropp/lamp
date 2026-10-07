"""Test-only Duck DK3/DK4 block writer and integer PCM model.

Uses the IMA tables already documented in adpcm_model.py. Duck packing and
sum/difference int16 wrapping are independently checked against FFmpeg
n5.1.9 and n9.0.1 adpcm.c. No reference code enters the runtime.
"""
import struct
from adpcm_model import IMA_STEPS, IMA_INDEX, clip16

DK4, DK3 = 0x61, 0x62


def samples(tag, size, channels):
    if tag == DK4:
        return 0 if size < 4 * channels else 1 + 2 * (size - 4 * channels) // channels
    return 0 if size < 16 else 2 * ((size - 16) * 2 // 3)


def step(state, code):
    magnitude = ((2 * (code & 7) + 1) * IMA_STEPS[state[1]]) // 8
    state[0] = clip16(state[0] + (-magnitude if code & 8 else magnitude))
    state[1] = max(0, min(88, state[1] + IMA_INDEX[code]))
    return state[0]


def block_pcm(tag, block, channels):
    count = samples(tag, len(block), channels)
    if not count:
        return [[] for _ in range(channels)]
    if tag == DK4:
        state = [list(struct.unpack_from('<hh', block, c * 4)) for c in range(channels)]
        if any(not 0 <= s[1] <= 88 for s in state): raise ValueError('step index')
        out = [[s[0]] for s in state]
        for n in range((count - 1) * channels):
            code = block[channels * 4 + n // 2]
            code = (code >> 4 if n % 2 == 0 else code) & 15
            channel = n % channels
            out[channel].append(step(state[channel], code))
        return out
    state = [[struct.unpack_from('<h', block, 10 + c * 2)[0], block[14 + c]] for c in range(2)]
    if any(s[1] > 88 for s in state): raise ValueError('step index')
    codes = [(byte >> shift) & 15 for byte in block[16:] for shift in (0, 4)]
    out = [[], []]
    def emit():
        for channel, value in enumerate((state[0][0] + state[1][0], state[0][0] - state[1][0])):
            out[channel].append((value + 32768) % 65536 - 32768)
    for pos in range(0, count // 2 * 3, 3):
        step(state[0], codes[pos])
        step(state[1], codes[pos + 1])
        emit()
        step(state[0], codes[pos + 2])
        emit()
    return out


def decode(tag, data, channels, align):
    pcm = []
    for start in range(0, len(data), align):
        planes = block_pcm(tag, data[start:start + align], channels)
        pcm.extend(planes[c][i] for i in range(len(planes[0])) for c in range(channels))
    return pcm


def random_blocks(rng, tag, channels, align, count, tail=0):
    chunks = []
    for n, size in enumerate([align] * count + ([tail] if tail else [])):
        data = bytearray(rng.randbytes(size))
        if samples(tag, size, channels):
            for c in range(channels):
                predictor = (-32768, -32767, -1, 0, 1, 32767, 12345)[(n + c) % 7]
                index = (n + c) % 89
                if tag == DK4:
                    struct.pack_into('<hh', data, c * 4, predictor, index)
                else:
                    struct.pack_into('<h', data, 10 + c * 2, predictor)
                    data[14 + c] = index
        chunks.append(data)
    return b''.join(chunks)


def wave(tag, channels, rate, align, data, fact=None):
    frames = samples(tag, align, channels)
    fmt = struct.pack('<HHIIHHH', tag, channels, rate, rate * align // max(1, frames), align, 3 if tag == DK3 else 4, 0)
    chunks = [(b'fmt ', fmt)]
    if fact is not None: chunks.append((b'fact', struct.pack('<I', fact)))
    chunks.append((b'data', data))
    body = b''.join(k + struct.pack('<I', len(p)) + p + bytes(len(p) % 2) for k, p in chunks)
    return b'RIFF' + struct.pack('<I', len(body) + 4) + b'WAVE' + body
