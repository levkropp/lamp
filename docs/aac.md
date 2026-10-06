# AAC-LC and HE-AAC

LAMP 0.4.0-dev decodes MPEG-4 AAC Low Complexity in MP4/M4A/MOV, Matroska, raw ADTS (`.aac`) and [LOAS/LATM](latm.md) (`.loas`, `.latm`, DVB transport streams) files with a handwritten decoder (`src/aac.s`) following ISO/IEC 14496-3 subpart 4 and ISO/IEC 13818-7, and HE-AAC's spectral band replication and parametric stereo on top of it (`src/aac_sbr.inc`, [below](#he-aac-spectral-band-replication)). Packets pass through the shared [track layer](matroska.md#track-layer), so MP4 edit lists, sample durations and seeking work as for the other codecs.

## Coverage

- AudioSpecificConfig with object type 2 (LC) from an MP4 `esds` (object types 0x40 and 0x67), Matroska `A_AAC` CodecPrivate, a LATM StreamMuxConfig or the ADTS header; sampling-frequency indices 0–11 (8–96 kHz); channel configurations 1–7 (mono to 7.1). Configuration 7 is 7.1 front-wide as ISO defines it: C, Lc/Rc, L/R, Ls/Rs, LFE.
- Raw data blocks with single-channel, channel-pair and LFE elements in the configured order; data stream, fill and program config elements are skipped.
- Section data with all eleven spectral codebooks, zero, noise and intensity bands; scalefactors, noise energies and intensity positions; pulse data; escape values up to 8191; TNS with both resolutions, coefficient compression, either direction and orders up to 12 (7 for short windows).
- Mid/side stereo with transmitted or all-band masks, intensity stereo, and perceptual noise substitution. A band that is noise in both channels of a pair with a transmitted M/S bit reuses the first channel's noise vector, as ISO specifies.
- All four window sequences, grouped short windows, sine and Kaiser-Bessel-derived window shapes (alpha 4 and 6), and a 2048/256-point IMDCT computed as a DCT-IV through a 512/64-point complex FFT in double precision.
- Multichannel output mixes to stereo with the shared WAVE speaker weights, as for FLAC, WAV and ALAC.

Unsupported streams reject with `decode_error` 101: other object types (Main, SSR, LTP and later), explicit or sub-8 kHz rates, channel configuration 0 (layouts given by a program config element), 960-sample frames, coupling channel elements, gain control and prediction. Malformed streams reject with 100. Dynamic range control data is ignored.

## Containers and timing

MP4 edit lists remove the encoder's priming samples (1024 for FFmpeg's encoder) and the end padding. ADTS, LOAS and Matroska files carry no such information, so their output starts with the priming samples, as FFmpeg's does. ADTS files may start with an ID3v2 tag and end with an ID3v1 tag; every frame must repeat the first frame's profile, rate and channel configuration and hold one raw data block. ADTS CRCs are skipped unchecked.

Seeking restarts one packet before the target and discards that packet's output, which rebuilds the overlap and window shape. Without noise substitution, seeks equal continuous decoding. Noise substitution draws a pseudo-random generator that runs through the whole stream (the generator and constants match FFmpeg's, so continuous decodes compare closely), so after a seek those bands carry different noise of the same energy.

## HE-AAC: spectral band replication

SBR (ISO/IEC 14496-3 4.6.18) rebuilds the upper half of the spectrum from the AAC-LC core, which runs at half the output rate.

- Signalling: an AudioSpecificConfig with object type 5 and a higher extension rate; the backward-compatible extension (sync word 0x2B7) with `sbrPresentFlag`; or only in the stream (implicit), by SBR fill elements in the first frame of an object type 2 stream. The first packet is decoded when the track opens, so the doubled rate is known before MP4 and Matroska timing is converted. `sbrPresentFlag` 0 plays the core alone. SBR data first seen after the first frame is skipped and the core plays at its own rate, as FFmpeg does for MP4 (in ADTS, FFmpeg 6.1 switches rate mid-stream).
- Output: twice the core rate (16–96 kHz from 8–48 kHz cores), 2048 samples per frame. Every channel element keeps SBR state; LFE elements and elements without SBR data pass through the QMF banks with no high band, as in FFmpeg.
- Bitstream: headers with both extra parts, all four frame classes (FIXFIX, FIXVAR, VARFIX, VARVAR) with transient pointers, coupled (level and balance) and independent channel pairs, time and frequency delta coding, 1.5 and 3 dB envelopes, inverse filtering modes, additional sinusoids, CRC-protected payloads (CRC not checked) and extended data (skipped).
- Frequency tables for SBR rates 16–96 kHz: linear or one- and two-region logarithmic master tables with warping, high and low resolution tables, noise floor bands, patches and the limiter table.
- Signal path, in double precision: the 32-band complex analysis and 64-band synthesis QMF banks (direct matrix products with the ISO window, input at ±32768 scale), HF generation with covariance-method inverse filtering and chirp factors, envelope estimation per subband or per band, gains with limiter and boost, gain smoothing, noise floors and sinusoids.
- Errors behave as in FFmpeg: invalid SBR data (bad time grids, scalefactors out of range, frequency tables that fail, payloads that read past their fill element) turns SBR off for that element until its next header, and the core continues upsampled. Gains, noise and sinusoid levels persist per element across frames, as FFmpeg's do; this is visible only when a dropped last patch leaves the limiter table ending below the top SBR subband.

Not supported: downsampled SBR (an extension rate not above the core rate) and SBR on cores above 48 kHz.

A seek resets SBR, which resumes with the element's next SBR header, and decodes two primer packets instead of one, because SBR also filters the previous frame's core output. With a header in every frame, output after a seek matches continuous decoding except for the phase of the SBR noise generator. Decoding runs about 80 times faster than real time for stereo at 48 kHz output on the test machine.

## HE-AAC v2: parametric stereo

Parametric stereo (ISO/IEC 14496-3 subpart 8) turns a mono SBR stream into stereo from per-band level differences, correlations and phases, structured as FFmpeg's decoder.

- Signalling: object type 29, the backward-compatible extension's `psPresentFlag`, or only in the stream. As in FFmpeg, every mono stream with SBR plays as stereo unless the extension signals PS absent; both channels carry the mono signal until the first PS header. `psPresentFlag` 0 plays mono and skips PS data, as do streams with more than one channel.
- Bitstream: PS headers, inter-channel intensity differences with default and fine quantization and coherences in all six band modes (10, 20 or 34 parameter bands), both frame classes with every envelope count, time and frequency delta coding, and the IPD/OPD extension. A frame without new parameters, or a variable frame whose last envelope ends early, repeats the last envelope to the frame's end.
- Signal path, in double precision with FFmpeg's single-precision tables: hybrid analysis of the low QMF bands (20 bands: 8 and two 2-band splits of QMF bands 0–2; 34 bands: 12, 8, 4, 4 and 4 of bands 0–4), decorrelation with transient attenuation, fractional delays and a three-link all-pass chain, the two mixing procedures (ICC modes 0–2 and 3–5), IPD/OPD phase smoothing, interpolation across envelope borders, parameter remapping between 10-, 20- and 34-band layouts as the layout switches, and hybrid synthesis back to QMF bands for each channel's synthesis bank.
- Errors behave as in FFmpeg: invalid PS data (a mode out of range, data that reads past its extension) stops PS until the next PS header, and both channels carry the mono signal meanwhile.

A seek also resets parametric stereo, which resumes with the next PS header. With a header in every frame, output after a seek matches continuous decoding except for the phase of the SBR noise generator. Parametric stereo streams decode about 80 times faster than real time at 48 kHz output on the test machine.

## Precision

Spectra, TNS and long-window overlap use single precision; noise scaling, the IMDCT, short-window assembly and stereo mixing use double precision. TNS reflection coefficients are the correctly rounded `sin()` values of the ISO formula. FFmpeg's tables differ by one float step for three coefficient values, which matters only for near-unstable filters, and FFmpeg applies its own window definitions to window-sequence transitions that encoders do not produce.

## Verification

`python3 tests/verify-aac.py` checks:

- 26 FFmpeg-encoded M4A files: tones, noise and transients at all twelve rates, 48–320 kb/s, FFmpeg's two-loop and fast coders with M/S, intensity, PNS and TNS switched on and off, mono, and 3.0, 4.0, 5.0, 5.1 and 7.1 layouts. Mono and stereo files match FFmpeg's decode within 2.4e-7 (at least 138 dB SNR); multichannel files match FFmpeg's channels mixed with LAMP's speaker weights. A coverage probe records which coding tools each file used.
- Six of them as ADTS, Matroska and fragmented MP4: 18 files equal the M4A decode exactly after the priming samples, and the ADTS files match FFmpeg's decode.
- 48 random valid streams (`tests/aac_vectors.py`) with every coding tool, including pulse data, all TNS parameters and escape values: at least 138 dB against FFmpeg. The generator avoids the cases where FFmpeg 6.1 differs from ISO (correlated noise, intensity with an all-band M/S mask, nonstandard window transitions, and the three rounded TNS constants); a separate stream checks that correlated noise bands give identical channels.
- 60 exact seeks in three M4A files and one ADTS file without noise substitution.
- 16 rejected streams: a coupling channel, gain control, prediction, AAC Main and SSR in ADTS and LTP or escaped object types in MP4, a reserved codebook, intensity in a single channel, an escape overflow, a scalefactor out of range, too many bands, pulses in short windows, the wrong element for the configuration, a block running past its packet, and a truncated file.
- Cancelled open and read, and playback through the Linux null sink.

`python3 tests/verify-heaac.py` checks SBR. No HE-AAC encoder is available to the tests, so `tests/sbr_vectors.py` writes SBR data drawn by the Python model `tests/sbr_model.py` into fill elements after the channel elements of FFmpeg-encoded, full-band AAC-LC streams; the core is a real encoder's while every SBR field is known:

- The model's own rendering of one stream matches FFmpeg at 134 dB, so the streams carry what the writer intended.
- 13 streams, mono to 7.1 (single-element encodes combined element by element) at core rates from 11.025 to 48 kHz, match FFmpeg's decode at 125 dB or better (multichannel through LAMP's speaker weights). The writer's coverage set proves every frame class, coupling mode, delta direction, envelope resolution, master table shape, patch count, limiter and smoothing setting, sinusoids, transients, header resets, extended data and a limiter table ending below the top subband were used.
- The stereo stream in MP4 with implicit, explicit (object type 5) and backward-compatible signalling, in Matroska and in fragmented MP4 equals the ADTS decode exactly; `sbrPresentFlag` 0 and SBR first seen after the first frame play the core as FFmpeg does; CRC-protected payloads match FFmpeg; SBR data before the first channel element is skipped (FFmpeg 6.1 does not skip its payload and loses the frame).
- 12 streams with corrupted SBR payloads match FFmpeg, which turns SBR off for the same errors, and 60 more heavily corrupted streams decode without errors. FFmpeg references use its C code path (`-cpuflags 0`): its x86 gain filter writes one subband past an odd number of SBR subbands from uninitialized memory, which corrupted streams can read back.
- 14 seeks into mono and stereo streams with a header in every frame return the requested positions and match continuous decoding at 55 dB or better.
- Downsampled SBR rejects as unsupported.

For parametric stereo, `tests/ps_model.py` draws PS data (written as SBR extended data) and renders it, also structured as FFmpeg's decoder:

- The model's rendering of one stream matches FFmpeg at 129.8 dB.
- 12 mono streams at core rates from 11.025 to 24 kHz match FFmpeg's stereo decode at 128 dB or better, and their channels differ. The writer's coverage set proves every IID and ICC mode (and frames without them), both frame classes with every envelope count, IPD/OPD, an appended last envelope, 20- and 34-band layouts and switches between them were used.
- The first PS stream in MP4 with implicit, object type 29 and backward-compatible signalling equals the ADTS decode exactly; `psPresentFlag` 0 plays mono as FFmpeg does. Stereo and multichannel SBR streams above carry PS data that is skipped.
- 6 streams with corrupted PS data match FFmpeg, and 20 more heavily corrupted PS streams decode without errors.
- 7 seeks into a PS stream with headers in every frame match continuous decoding at 74 dB or better.

`src/sbr_tables.inc` holds the SBR Huffman trees and start-frequency offsets (from the same PacketVideo files), the ISO QMF window and noise table, and the parametric stereo Huffman trees, filter prototypes, all-pass constants and band groupings with the tables derived from them (from JAADec, public domain), generated by `python3 tests/generate-sbr-tables.py`, which fetches pinned files, checks their hashes and verifies its output with `--check`.

The codebooks, scalefactor band tables and TNS limits in `src/aac_tables.inc` are generated by `python3 tests/generate-aac-tables.py`, which fetches the PacketVideo AAC decoder (Apache License 2.0) at a pinned Android Open Source Project commit, checks file hashes, and runs its Huffman lookup decoder over every input to recover each codeword. `--check` verifies the committed include.
