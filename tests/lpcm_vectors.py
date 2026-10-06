"""DVD and Blu-ray LPCM writers for the tests.

DVD LPCM goes into MPEG-2 program streams as private stream 1 substreams
0xA0-0xA7: each PES packet holds the substream number, a frame count, a
first access unit pointer, the three-byte LPCM header and big-endian
samples (20 and 24 bits in groups of four samples, two in mono: the top 16
bits of each, then the low bits). Blu-ray LPCM goes into transport streams
as stream type 0x80 under an HDMV registration: each PES packet holds a
four-byte header and frames of big-endian samples, the channels padded to
an even count. Both layouts are the inverses of FFmpeg's pcm_dvd and
pcm_bluray decoders. wave() writes the same samples as WAVE_FORMAT_EXTENSIBLE
with FFmpeg's channel layout, the reference a decoder must equal.
"""
from pathlib import Path
import random
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import latm_vectors

DVD_RATES = (48000, 96000, 44100, 32000)
# FFmpeg's default layouts for 1-8 channels (WAVE channel masks).
DVD_MASKS = (0x4, 0x3, 0xb, 0x107, 0x37, 0x3f, 0x70f, 0x63f)
# Blu-ray channel assignments: (source channels, WAVE mask, output index of
# each source channel, None for padding), as FFmpeg maps them.
BD_LAYOUTS = {1: (2, 0x4, (0, None)), 3: (2, 0x3, (0, 1)), 4: (4, 0x7, (0, 1, 2, None)),
              5: (4, 0x103, (0, 1, 2, None)), 6: (4, 0x107, (0, 1, 2, 3)), 7: (4, 0x603, (0, 1, 2, 3)),
              8: (6, 0x607, (0, 1, 2, 3, 4, None)), 9: (6, 0x60f, (0, 1, 2, 4, 5, 3)),
              10: (8, 0x637, (0, 1, 2, 5, 3, 4, 6, None)), 11: (8, 0x63f, (0, 1, 2, 6, 4, 5, 7, 3))}
BD_RATES = {1: 48000, 4: 96000, 5: 192000}


def samples(seed, frames, channels, bits):
    """Random signed samples, frames x channels, with full-scale extremes."""
    r = random.Random(seed)
    top = 1 << (bits - 1)
    out = []
    for f in range(frames):
        row = []
        for c in range(channels):
            kind = r.random()
            row.append(top - 1 if kind < 0.01 else -top if kind < 0.02 else int(r.gauss(0, top / 4)))
        out.append([max(-top, min(top - 1, v)) for v in row])
    return out


def wave(frames, rate, bits, mask):
    """WAVE_FORMAT_EXTENSIBLE bytes: 16-bit samples, or 24-bit containers
    with bits valid (20-bit samples shifted up)."""
    channels = len(frames[0])
    container = 16 if bits == 16 else 24
    align = channels * container // 8
    fmt = struct.pack('<HHIIHHHHI', 0xfffe, channels, rate, rate * align, align, container, 22, bits, mask)
    fmt += b'\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71'
    shift = container - bits
    data = b''.join(((v << shift) & ((1 << container) - 1)).to_bytes(container // 8, 'little')
                    for row in frames for v in row)
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
    return b'RIFF' + struct.pack('<I', len(body)) + body


def dvd_samples(frames, bits):
    """The DVD byte layout of interleaved samples (whole blocks)."""
    flat = [v for row in frames for v in row]
    if bits == 16:
        return b''.join((v & 0xffff).to_bytes(2, 'big') for v in flat)
    group = 2 if len(frames[0]) == 1 else 4
    out = bytearray()
    for i in range(0, len(flat), group):
        part = flat[i:i + group]
        out += b''.join(((v >> (bits - 16)) & 0xffff).to_bytes(2, 'big') for v in part)
        if bits == 24:
            out += bytes(v & 0xff for v in part)
        else:
            out += bytes(((part[k] & 15) << 4) | (part[k + 1] & 15) for k in range(0, group, 2))
    return bytes(out)


def dvd_block_frames(channels, bits):
    if bits == 16:
        return 1
    samples_per_block = 4 if channels in (1, 2, 4) else 8 if channels == 8 else 4 * channels
    return samples_per_block // channels


_PACK = bytes.fromhex('000001ba4400040004010189c3f8')


def _pes(stream_id, payload, pts):
    stamp = bytes([0x21 | (pts >> 29) & 0x0e, (pts >> 22) & 0xff, 0x01 | (pts >> 14) & 0xfe,
                   (pts >> 7) & 0xff, 0x01 | (pts << 1) & 0xfe])
    return b'\x00\x00\x01' + bytes([stream_id]) + (len(payload) + 8).to_bytes(2, 'big') + b'\x81\x80\x05' + \
        stamp + payload


def dvd_stream(frames, rate, bits, packet=2000, substream=0xa0, header=None, drc=0x80, change=None, extra=None):
    """An MPEG-2 program stream of DVD LPCM: packet bytes of samples per PES
    packet (blocks straddle packets). header overrides the header's second
    byte; change=(packet index, byte) rewrites it from that packet on; extra
    is a second substream's (frames, packet) written alongside."""
    channels = len(frames[0])
    code = (DVD_RATES.index(rate) << 4) | ((bits - 16) // 4 << 6) | (channels - 1) if header is None else header
    data = dvd_samples(frames, bits)
    out = bytearray()
    other = dvd_samples(extra, bits) if extra else b''
    for k, i in enumerate(range(0, len(data), packet)):
        second = change[1] if change and k >= change[0] else code
        lpcm = bytes([0xc0 | k & 0x1f, second, drc])          # emphasis 1, frame number k
        payload = bytes([substream, 1, 0, 4]) + lpcm + data[i:i + packet]
        out += _PACK + _pes(0xbd, payload, 90000 + k * 900)
        if other[i:i + packet]:
            payload = bytes([substream + 1, 1, 0, 4]) + bytes([0, code, 0x80]) + other[i:i + packet]
            out += _PACK + _pes(0xbd, payload, 90000 + k * 900)
    return bytes(out + b'\x00\x00\x01\xb9')


def bluray_frames(frames, layout, bits):
    """Source frames: each frame's channels in Blu-ray order, padded."""
    source, _, index = BD_LAYOUTS[layout]
    width = 2 if bits == 16 else 3                     # 20 bits in 24
    out = bytearray()
    for row in frames:
        values = [0] * source
        for s, d in enumerate(index):
            if d is not None:
                values[s] = row[d]
        out += b''.join(((v << (8 * width - bits)) & ((1 << 8 * width) - 1)).to_bytes(width, 'big')
                        for v in values)
    return bytes(out)


def bluray_stream(frames, layout, rate, bits, per_packet=240, header=None, change=None, hdmv=True, m2ts=True,
                  partial=0):
    """A transport stream of Blu-ray LPCM: per_packet frames per PES packet.
    header overrides header bytes 2 and 3; change=(packet index, bytes 2-3)
    from that packet on; partial adds that many bytes of a cut frame to each
    packet (FFmpeg drops them)."""
    rate_code = {v: k for k, v in BD_RATES.items()}.get(rate, 1)
    bits_code = {16: 1, 20: 2, 24: 3}[bits]
    code = (layout << 12 | rate_code << 8 | bits_code << 6) if header is None else header
    data = bluray_frames(frames, layout, bits)
    frame = len(data) // len(frames)
    payloads = []
    for k, i in enumerate(range(0, len(frames), per_packet)):
        body = data[i * frame:(i + per_packet) * frame] + bytes(partial)
        word = change[1] if change and k >= change[0] else code
        payloads.append(len(body).to_bytes(2, 'big') + word.to_bytes(2, 'big') + body)
    info = b'\x05\x04HDMV' if hdmv else b''
    return latm_vectors.transport_pes(payloads, per_packet * 90000 // rate, 0x80, stream_id=0xbd, program_info=info,
                                      m2ts=m2ts)
