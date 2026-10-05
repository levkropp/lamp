# MPEG audio Layers I and II

LAMP 0.4.0-dev decodes MPEG audio Layer I (`.mp1`) and Layer II (`.mp2`, also common in broadcast and DVD/Video CD audio) in handwritten assembly. Layer I/II frames share the Layer III module's framing, frame index, seeking and polyphase synthesis filterbank (`src/mp3.s`, `src/mp3_synthesis.s`); `src/mp2.s` reads the bit allocation, scalefactors and samples.

## Coverage

- MPEG-1 at 32, 44.1 and 48 kHz and MPEG-2 lower sampling frequencies at 16, 22.05 and 24 kHz. MPEG 2.5 defines Layer III only, so a Layer I/II header with it rejects.
- Every Layer II allocation table: the four MPEG-1 tables, selected by sampling rate and bitrate per channel (8, 12, 27 or 30 subbands), and the MPEG-2 table. Layer I uses 4-bit allocations for 32 subbands.
- Plain quantizers of 2–16 bits and grouped 3-, 5- and 9-level quantizers (three samples per 5-, 7- or 10-bit code).
- Layer II scalefactor selection (one, two or three scalefactors per part); scalefactor indexes 0–63.
- Stereo, joint stereo (intensity bound at subband 4, 8, 12 or 16, with each channel's own scalefactors above the bound), dual channel and mono. Output is stereo float; mono is duplicated, and dual-channel streams play their two channels as left and right.
- CRC-16 over the header, bit allocation and (Layer II) scalefactor selection; a mismatch rejects the frame.
- Every frame must keep the first frame's layer, version, rate and channel count. Bitrate, padding, mode extension and CRC protection may change between frames. Free format, the reserved bitrate index and reserved sample rate reject. Ancillary data is ignored.

Layer I frames hold 384 samples (12 time slots of 32 subbands) and Layer II frames 1,152 (three parts of 12 slots). Samples are dequantized with the same constants as minimp3/dr_mp3 and synthesized by the shared filterbank, which takes the slot count as a parameter.

Opening scans every frame's header, allocation, scalefactor selection and CRC to build the same sparse index as Layer III; there is no reservoir. Seeking restores an index point and decodes two frames of pre-roll, which rebuilds the synthesis history exactly. Untagged streams carry no encoder delay information, so output is not trimmed. MPEG audio inside other containers (WAV, MPEG program/transport streams, Matroska) is not yet supported.

## Verification

`python3 tests/verify-mp2.py` compares LAMP with FFmpeg's `mp1float`/`mp2float` decoders, an independent implementation:

- 96 random valid streams from `tests/mpa12_vectors.py`: both layers, MPEG-1 and MPEG-2, all three rates, all four modes, sparse and dense allocations, random bitrates, padding, joint stereo bounds and CRC protection per frame. The generator draws allocations within each table, scalefactor selection patterns, scalefactors 0–62, samples that avoid the forbidden all-ones codes and valid grouped codes, then fills the frame with ancillary bits.
- 34 encoder files from FFmpeg's `mp2` encoder and libtwolame: 16–48 kHz, 32–384 kbps, mono, stereo, dual channel, joint stereo (84 joint frames come from two 48 kHz libtwolame files) and CRC protection.
- Every comparison requires at least 105 dB SNR and a peak error below 0.00002 of the reference peak; the recorded minimum is 108.7 dB.
- Three files (Layer I joint stereo, Layer II MPEG-1, Layer II MPEG-2 mono) pass the exact seek oracle against continuous decoding: 45 seeks, EOF/clamping, canaries and allocation release.
- Seven malformed streams reject: a protected allocation bit with a stale CRC, a layer change, a truncated frame, MPEG 2.5 Layer II, the reserved bitrate, free format and the reserved sample rate.

FFmpeg's MPEG audio demuxer skips leading frames until two consecutive headers agree in stereo mode; the suite drops such frames from encoder files so both decoders see the same frames.
