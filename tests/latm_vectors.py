"""LOAS/LATM writer for the tests: AAC raw data blocks and an
AudioSpecificConfig into LOAS frames (ISO/IEC 14496-3, 1.7).

Every frame is an AudioSyncStream frame (sync 0x2B7, 13-bit length) holding
one AudioMuxElement: useSameStreamMux, a StreamMuxConfig when the frame
carries one, each sub-frame's PayloadLengthInfo and payload, other data and
byte alignment. The options cover what LAMP reads; FFmpeg's muxer writes
only version 0 with one sub-frame.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aac_vectors import Bits


OTHER = int('10' * 128, 2)                           # other data bits, alternating


def config(fields):
    """(value, bit count) of an AudioSpecificConfig from (value, width) fields."""
    value, count = 0, 0
    for field, width in fields:
        assert 0 <= field < 1 << width
        value, count = value << width | field, count + width
    return value, count


def lc_config(rate_index, channels, object_type=2):
    return config([(object_type, 5), (rate_index, 4), (channels, 4), (0, 3)])


def adts_config(data):
    """The AudioSpecificConfig an ADTS stream's first header describes."""
    profile, rate_index = data[2] >> 6, (data[2] >> 2) & 15
    channels = (data[2] & 1) << 2 | data[3] >> 6
    return lc_config(rate_index, channels, profile + 1)


def raw_blocks(data):
    """The raw data blocks of an ADTS stream (one per frame)."""
    position, blocks = 0, []
    while position + 7 <= len(data):
        length = ((data[position + 3] & 3) << 11) | (data[position + 4] << 3) | (data[position + 5] >> 5)
        head = 7 if data[position + 1] & 1 else 9
        blocks.append(data[position + head:position + length])
        position += length
    return blocks


def latm_value(bits, value):
    """LatmGetValue: two bits of byte count - 1, then the bytes."""
    count = max(1, (value.bit_length() + 7) // 8)
    bits.put(count - 1, 2)
    bits.put(value, 8 * count)


def stream_mux_config(asc, version=0, subframes=1, asc_fill=0, other_bits=None, other_escape=1, crc=False,
                      programs=0, layers=0, version_a=0, frame_length_type=0, asc_length=None):
    """A StreamMuxConfig as a Bits. asc: (value, bit count). asc_fill: bits
    after the AudioSpecificConfig inside ascLen (version 1). other_bits:
    otherDataLenBits, version 0 coding it in other_escape bytes. asc_length
    overrides the ascLen written."""
    bits = Bits()
    bits.put(version, 1)
    if version:
        bits.put(version_a, 1)
        latm_value(bits, 0xff)                       # taraBufferFullness
    bits.put(1, 1)                                   # allStreamsSameTimeFraming
    bits.put(subframes - 1, 6)
    bits.put(programs, 4)
    bits.put(layers, 3)
    value, count = asc
    if version:
        latm_value(bits, count + asc_fill if asc_length is None else asc_length)
    bits.put(value, count)
    bits.put(0, asc_fill)
    bits.put(frame_length_type, 3)
    bits.put(0xff, 8)                                # latmBufferFullness
    bits.put(other_bits is not None, 1)
    if other_bits is not None:
        if version:
            latm_value(bits, other_bits)
        else:
            for i in reversed(range(other_escape)):
                bits.put(i > 0, 1)                   # otherDataLenEsc
                bits.put((other_bits >> 8 * i) & 0xff, 8)
    bits.put(crc, 1)
    if crc:
        bits.put(0x5a, 8)                            # crcCheckSum (not checked)
    return bits


def element(payloads, mux=None, other_bits=0, lengths=None):
    """An AudioMuxElement's bytes: mux is a StreamMuxConfig (Bits) or None
    for useSameStreamMux; lengths overrides the payload lengths written."""
    bits = Bits()
    bits.put(0 if mux else 1, 1)
    if mux:
        bits.put(mux.value, mux.count)
    for i, payload in enumerate(payloads):
        n = lengths[i] if lengths else len(payload)
        while n >= 255:
            bits.put(255, 8)
            n -= 255
        bits.put(n, 8)
        bits.put(int.from_bytes(payload, 'big'), 8 * len(payload))
    bits.put(OTHER >> (256 - other_bits), other_bits)
    return bits.data()


def loas(element_bytes):
    assert len(element_bytes) < 8192
    n = len(element_bytes)
    return bytes([0x56, 0xe0 | n >> 8, n & 0xff]) + element_bytes


def stream(blocks, asc, interval=1, subframes=1, skip_first=0, other_bits=None, **mux):
    """LOAS bytes for blocks: a StreamMuxConfig every interval frames
    (frames before skip_first carry none, so decoders skip them), subframes
    payloads per frame, other_bits of other data per frame."""
    out = bytearray()
    frames = [blocks[i:i + subframes] for i in range(0, len(blocks) - subframes + 1, subframes)]
    for f, payloads in enumerate(frames):
        config = f >= skip_first and (f - skip_first) % interval == 0
        smc = stream_mux_config(asc, subframes=subframes, other_bits=other_bits, **mux) if config else None
        out += loas(element(payloads, smc, other_bits or 0))
    return bytes(out)


def frames(data):
    """The LOAS frames of a stream."""
    position, out = 0, []
    while position + 3 <= len(data):
        n = 3 + ((data[position + 1] & 0x1f) << 8 | data[position + 2])
        out.append(data[position:position + n])
        position += n
    return out


def _crc32(data):
    """MPEG-2 section CRC (polynomial 0x04C11DB7, not reflected)."""
    crc = 0xffffffff
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = (crc << 1) ^ 0x04c11db7 if crc & 0x80000000 else crc << 1
            crc &= 0xffffffff
    return crc


def _section(table_id, extension, body):
    head = bytes([table_id]) + (0xb000 | len(body) + 9).to_bytes(2, 'big') + extension.to_bytes(2, 'big') + \
        b'\xc1\x00\x00'
    section = head + body
    return section + _crc32(section).to_bytes(4, 'big')


def _packets(pid, payload, counter, start=True):
    """Transport packets for one payload unit; counter is a one-item list."""
    out = bytearray()
    first = True
    while payload or first:
        chunk = payload[:184]
        payload = payload[184:]
        head = bytes([0x47, (0x40 if first and start else 0) | pid >> 8, pid & 0xff])
        if len(chunk) < 184:                            # stuffing in an adaptation field
            stuffing = 184 - len(chunk) - 1
            field = bytes([stuffing]) + (bytes([0]) + b'\xff' * (stuffing - 1) if stuffing else b'')
            out += head + bytes([0x30 | counter[0]]) + field + chunk
        else:
            out += head + bytes([0x10 | counter[0]]) + chunk
        counter[0] = (counter[0] + 1) & 15
        first = False
    return out


def transport(data, rate, per_pes=1, split=0, stream_type=0x11):
    """A transport stream carrying the LOAS stream data as stream_type on PID
    0x100: per_pes LOAS frames per PES packet, the boundary moved split bytes
    into the next frame (so frames straddle PES packets)."""
    pid, pmt_pid = 0x100, 0x1000
    pat = b'\x00' + _section(0, 1, (1).to_bytes(2, 'big') + (0xe000 | pmt_pid).to_bytes(2, 'big'))
    pmt = b'\x00' + _section(2, 1, (0xe000 | pid).to_bytes(2, 'big') + b'\xf0\x00' + bytes([stream_type]) +
                             (0xe000 | pid).to_bytes(2, 'big') + b'\xf0\x00')
    units, out = frames(data), bytearray()
    counters = {0: [0], pmt_pid: [0], pid: [0]}
    chunks, position = [], 0
    for i in range(0, len(units), per_pes):
        end = sum(len(u) for u in units[:i + per_pes]) + (split if i + per_pes < len(units) else 0)
        chunks.append(data[position:end])
        position = end
    for k, chunk in enumerate(chunks):
        if k % 20 == 0:
            out += _packets(0, pat, counters[0]) + _packets(pmt_pid, pmt, counters[pmt_pid])
        pts = 90000 + k * per_pes * 1024 * 90000 // rate
        stamp = bytes([0x21 | (pts >> 29) & 0x0e, (pts >> 22) & 0xff, 0x01 | (pts >> 14) & 0xfe,
                       (pts >> 7) & 0xff, 0x01 | (pts << 1) & 0xfe])
        pes = b'\x00\x00\x01\xc0' + (len(chunk) + 8).to_bytes(2, 'big') + b'\x80\x80\x05' + stamp + chunk
        out += _packets(pid, pes, counters[pid])
    return bytes(out)
