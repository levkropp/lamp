"""Test-only HE-AAC stream writer.

SBR extension payloads drawn by tests/sbr_model.py go into fill elements
after the channel elements of FFmpeg-encoded AAC-LC raw data blocks, so the
core is a realistic encoder's while every SBR field is known. Elements from
separate mono and stereo encodes combine into multichannel layouts.
"""
import copy
import random
import struct

import aac_vectors as vectors
import sbr_model as model

SCE, CPE, LFE = 0, 1, 3
LAYOUTS = {1: [SCE], 2: [CPE], 3: [SCE, CPE], 6: [SCE, CPE, CPE, LFE], 7: [SCE, CPE, CPE, CPE, LFE]}


def header(r, rate):
    """Random SBR header fields whose frequency tables are valid at rate."""
    while True:
        h = dict(amp_res=r.randrange(2), start_freq=r.randrange(16), stop_freq=r.randrange(16),
                 xover_band=r.randrange(8), freq_scale=r.randrange(4), alter_scale=r.randrange(2),
                 noise_bands=r.randrange(4), limiter_bands=r.randrange(4), limiter_gains=r.randrange(4),
                 interpol_freq=r.randrange(2), smoothing=r.randrange(2))
        try:
            model.frequency_tables(rate, h)
            return h
        except model.TableError:
            pass


def raw_blocks(data):
    """The raw data blocks of an ADTS stream."""
    position, blocks = 0, []
    while position + 7 <= len(data):
        length = ((data[position + 3] & 3) << 11) | (data[position + 4] << 3) | (data[position + 5] >> 5)
        head = 7 if data[position + 1] & 1 else 9
        blocks.append(data[position + head:position + length])
        position += length
    return blocks


def element(block):
    """(value, bit count) of a block's single channel element: everything
    before END (FFmpeg's encoder writes no other elements with bitexact)."""
    value, count = int.from_bytes(block, 'big'), len(block) * 8
    pad = 0
    while pad < 8 and not (value >> pad) & 1:
        pad += 1
    assert (value >> pad) & 7 == 7, 'block does not end with END'
    end = count - pad - 3
    return value >> (count - end), end


def fill(payload, crc=False):
    """A fill element carrying SBR data (payload: a vectors.Bits)."""
    bits = vectors.Bits()
    body = payload.count + (10 if crc else 0)
    count = (4 + body + 7) // 8
    assert count <= 269, 'SBR payload too large for one fill element'
    bits.put(6, 3)
    if count >= 15:
        bits.put(15, 4)
        bits.put(count - 14, 8)
    else:
        bits.put(count, 4)
    bits.put(14 if crc else 13, 4)
    if crc:
        bits.put(0, 10)                                  # bs_sbr_crc_bits, not checked
    bits.put(payload.value, payload.count)
    bits.put(0, count * 8 - 4 - body)
    return bits


def stream(cores, config, rate_index, seed, frames, steady=False, header_rate=0.15, crc=False, mutate=None,
           extension=None):
    """-> (ADTS HE-AAC bytes, SBR tools used). cores: per element of
    LAYOUTS[config] the raw blocks of an FFmpeg encode of that element alone.
    steady elements send a header in every frame and keep the steady model
    rules (seek fixtures). mutate(f, index, payload) may return replacement
    payload bits. extension(f) may return bytes for bs_extended_data."""
    rate = vectors.RATES[rate_index]
    r = random.Random(seed)
    layout = LAYOUTS[config]
    elements = {i: model.Element(2 * rate, 2 if kind == CPE else 1, steady)
                for i, kind in enumerate(layout) if kind != LFE}
    headers = {i: header(r, 2 * rate) for i in elements}
    out = bytearray()
    for f in range(frames):
        bits = vectors.Bits()
        tags = {}
        for i, kind in enumerate(layout):
            value, count = element(cores[i][f])
            tag = tags.get(kind, 0)
            tags[kind] = tag + 1
            value = (value & ~(127 << (count - 7))) | ((kind << 4 | tag) << (count - 7))   # id_syn_ele, tag
            bits.put(value, count)
            if i not in elements:
                continue
            send = headers[i] if steady or f == 0 or r.random() < header_rate else None
            if send and not steady and r.random() < 0.3:
                headers[i] = send = header(r, 2 * rate)
            for _ in range(100):                         # redraw payloads too large for a fill element
                trial = copy.deepcopy(elements[i])
                payload = vectors.Bits()
                trial.write_payload(r, payload, send, extension(f) if extension else None)
                if (4 + payload.count + (10 if crc else 0) + 7) // 8 <= 269:
                    break
            elements[i] = trial
            if mutate:
                payload = mutate(f, i, payload) or payload
            fil_bits = fill(payload, crc)
            bits.put(fil_bits.value, fil_bits.count)
        bits.put(7, 3)
        out += vectors.adts(bits.data(), rate_index, config)
    used = set().union(*(e.used for e in elements.values()))
    return bytes(out), used


def config_bits(fields):
    """AudioSpecificConfig bytes from (value, bit count) fields."""
    value, count = 0, 0
    for field, width in fields:
        value, count = value << width | field, count + width
    pad = -count % 8
    return (value << pad).to_bytes((count + pad) // 8, 'big')


_CONTAINERS = {b'moov', b'trak', b'mdia', b'minf', b'stbl'}


def _box_path(data, start, end, target, trail):
    position = start
    while position + 8 <= end:
        size, kind = struct.unpack('>I4s', data[position:position + 8])
        if size < 8 or position + size > end:
            return None
        if kind == target:
            return trail + [position]
        body = {b'stsd': 16, b'mp4a': 36}.get(kind, 8 if kind in _CONTAINERS else None)
        if body is not None:
            found = _box_path(data, position + body, position + size, target, trail + [position])
            if found:
                return found
        position += size
    return None


def replace_config(mp4, config):
    """An FFmpeg-written MP4 (moov after mdat) with its esds
    DecoderSpecificInfo replaced by config; parent box sizes follow."""
    path = _box_path(mp4, 0, len(mp4), b'esds', [])
    esds = path[-1]
    assert 0 < mp4.find(b'mdat') < path[0], 'moov must follow mdat'
    size = struct.unpack('>I', mp4[esds:esds + 4])[0]
    body = mp4[esds + 12:esds + size]

    def descriptor(position):
        length, position = 0, position + 1
        while True:
            byte = body[position]
            position += 1
            length = length << 7 | byte & 0x7f
            if not byte & 0x80:
                return position, length

    def encode(tag, payload):
        n = len(payload)
        return bytes([tag, 0x80 | n >> 21 & 0x7f, 0x80 | n >> 14 & 0x7f, 0x80 | n >> 7 & 0x7f, n & 0x7f]) + payload
    es, es_length = descriptor(0)
    decoder, decoder_length = descriptor(es + 3)
    specific, specific_length = descriptor(decoder + 13)
    inner = encode(4, body[decoder:decoder + 13] + encode(5, config) +
                   body[specific + specific_length:decoder + decoder_length])
    outer = encode(3, body[es:es + 3] + inner + body[decoder + decoder_length:es + es_length])
    new = struct.pack('>I4s', 12 + len(outer), b'esds') + mp4[esds + 8:esds + 12] + outer
    out = bytearray(mp4[:esds] + new + mp4[esds + size:])
    for position in path[:-1]:
        old = struct.unpack('>I', out[position:position + 4])[0]
        out[position:position + 4] = struct.pack('>I', old + len(new) - size)
    return bytes(out)
