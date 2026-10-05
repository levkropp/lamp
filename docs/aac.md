# AAC-LC

LAMP 0.4.0-dev decodes MPEG-4 AAC Low Complexity in MP4/M4A/MOV, Matroska and raw ADTS (`.aac`) files with a handwritten decoder (`src/aac.s`) following ISO/IEC 14496-3 subpart 4 and ISO/IEC 13818-7. Packets pass through the shared [track layer](matroska.md#track-layer), so MP4 edit lists, sample durations and seeking work as for the other codecs.

## Coverage

- AudioSpecificConfig with object type 2 (LC) from an MP4 `esds` (object types 0x40 and 0x67), Matroska `A_AAC` CodecPrivate or the ADTS header; sampling-frequency indices 0–11 (8–96 kHz); channel configurations 1–7 (mono to 7.1). Configuration 7 is 7.1 front-wide as ISO defines it: C, Lc/Rc, L/R, Ls/Rs, LFE.
- Raw data blocks with single-channel, channel-pair and LFE elements in the configured order; data stream, fill and program config elements are skipped.
- Section data with all eleven spectral codebooks, zero, noise and intensity bands; scalefactors, noise energies and intensity positions; pulse data; escape values up to 8191; TNS with both resolutions, coefficient compression, either direction and orders up to 12 (7 for short windows).
- Mid/side stereo with transmitted or all-band masks, intensity stereo, and perceptual noise substitution. A band that is noise in both channels of a pair with a transmitted M/S bit reuses the first channel's noise vector, as ISO specifies.
- All four window sequences, grouped short windows, sine and Kaiser-Bessel-derived window shapes (alpha 4 and 6), and a 2048/256-point IMDCT computed as a DCT-IV through a 512/64-point complex FFT in double precision.
- Multichannel output mixes to stereo with the shared WAVE speaker weights, as for FLAC, WAV and ALAC.

Unsupported streams reject with `decode_error` 101: HE-AAC (SBR or PS, signalled in the configuration or by SBR fill elements in the first frame), other object types (Main, SSR, LTP and later), explicit or sub-8 kHz rates, channel configuration 0 (layouts given by a program config element), 960-sample frames, coupling channel elements, gain control and prediction. Malformed streams reject with 100. Dynamic range control data is ignored.

## Containers and timing

MP4 edit lists remove the encoder's priming samples (1024 for FFmpeg's encoder) and the end padding. ADTS and Matroska files carry no such information, so their output starts with the priming samples, as FFmpeg's does. ADTS files may start with an ID3v2 tag and end with an ID3v1 tag; every frame must repeat the first frame's profile, rate and channel configuration and hold one raw data block. ADTS CRCs are skipped unchecked.

Seeking restarts one packet before the target and discards that packet's output, which rebuilds the overlap and window shape. Without noise substitution, seeks equal continuous decoding. Noise substitution draws a pseudo-random generator that runs through the whole stream (the generator and constants match FFmpeg's, so continuous decodes compare closely), so after a seek those bands carry different noise of the same energy.

## Precision

Spectra, TNS and long-window overlap use single precision; noise scaling, the IMDCT, short-window assembly and stereo mixing use double precision. TNS reflection coefficients are the correctly rounded `sin()` values of the ISO formula. FFmpeg's tables differ by one float step for three coefficient values, which matters only for near-unstable filters, and FFmpeg applies its own window definitions to window-sequence transitions that encoders do not produce.

## Verification

`python3 tests/verify-aac.py` checks:

- 26 FFmpeg-encoded M4A files: tones, noise and transients at all twelve rates, 48–320 kb/s, FFmpeg's two-loop and fast coders with M/S, intensity, PNS and TNS switched on and off, mono, and 3.0, 4.0, 5.0, 5.1 and 7.1 layouts. Mono and stereo files match FFmpeg's decode within 2.4e-7 (at least 138 dB SNR); multichannel files match FFmpeg's channels mixed with LAMP's speaker weights. A coverage probe records which coding tools each file used.
- Six of them as ADTS, Matroska and fragmented MP4: 18 files equal the M4A decode exactly after the priming samples, and the ADTS files match FFmpeg's decode.
- 48 random valid streams (`tests/aac_vectors.py`) with every coding tool, including pulse data, all TNS parameters and escape values: at least 138 dB against FFmpeg. The generator avoids the cases where FFmpeg 6.1 differs from ISO (correlated noise, intensity with an all-band M/S mask, nonstandard window transitions, and the three rounded TNS constants); a separate stream checks that correlated noise bands give identical channels.
- 60 exact seeks in three M4A files and one ADTS file without noise substitution.
- 16 rejected streams: SBR fill data, a coupling channel, gain control, prediction, AAC Main in ADTS and HE-AAC or escaped object types in MP4, a reserved codebook, intensity in a single channel, an escape overflow, a scalefactor out of range, too many bands, pulses in short windows, the wrong element for the configuration, a block running past its packet, and a truncated file.
- Cancelled open and read, and playback through the Linux null sink.

The codebooks, scalefactor band tables and TNS limits in `src/aac_tables.inc` are generated by `python3 tests/generate-aac-tables.py`, which fetches the PacketVideo AAC decoder (Apache License 2.0) at a pinned Android Open Source Project commit, checks file hashes, and runs its Huffman lookup decoder over every input to recover each codeword. `--check` verifies the committed include.
