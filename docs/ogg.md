# Ogg streams, FLAC in Ogg and resampling

LAMP 0.4.0-dev reads an Ogg file as a physical stream: a sequence of **links**, each with one or more multiplexed logical streams. This page describes how links and streams are chosen, FLAC-in-Ogg, and the resampler used when links change rate. Vorbis and Opus decoding are described in [Vorbis](vorbis.md) and [Opus](opus.md).

## Links and streams

A link begins with the BOS pages of its logical streams. A BOS page after any other page starts the next link; this is how chained files (for example, concatenated recordings or stream dumps) are formed. Each link plays its **first Vorbis, Opus or FLAC stream**, in BOS order. Other streams in the link, such as Theora video, Speex or a second audio track, are skipped page by page. A link without a supported stream rejects the whole file, rather than silently dropping its audio.

`chain_open` (`src/ogg_chain.s`) walks page headers once, recording each link's byte range and selected stream. It then opens every link with its codec, last to first, so link 0 remains open. Each codec open validates the whole link exactly as a single-stream file is validated: every page CRC of the selected stream, page sequence and continuation, granule order, header placement and every packet's duration. Pages of other streams are bounds-checked and skipped; a page whose stream did not begin in the link, a duplicate BOS, more than 64 streams in a link, junk between pages and a page of the selected stream after its EOS reject the file. Opening therefore reads the whole file, as before. The link table reserves 4 MiB of address space and commits 64 KiB per 1,024 links; at most 65,536 links are accepted.

Links decode independently: each applies its own pre-skip, granule origin, end trimming and channel layout, and a link's last sample is followed directly by the next link's first sample. When a link ends, its codec closes and the next link's codec opens, revalidating the link; its duration and rate must equal those recorded at open. Output stays stereo float, so channel counts may change between links.

## Output rate

Output uses the first link's rate (48 kHz for Opus). `output_rate` and `output_frames` publish the rate and total length of the PCM that `decoder_read` returns; the players and UI use these, while `sample_rate`, `total_frames`, `source_channels` and `codec_kind` describe the link being decoded. A link at another rate passes through the resampler and contributes `ceil(frames × output rate / link rate)` frames.

## Seeking

`chain_seek` finds the link containing the target, opens it and seeks its codec. Vorbis and FLAC links seek exactly, so the PCM after a seek equals continuous playback. Opus links use their usual 80 ms pre-roll, so PCM after a seek into an Opus link equals a seek in that link alone. In a resampled link the codec seeks a filter half-width before the target's input span and the resampler restarts at the first output whose whole span was decoded; with an exact codec seek its output equals continuous playback.

## FLAC in Ogg

The FLAC-in-Ogg 1.0 mapping is supported: a first packet with `0x7F "FLAC"`, mapping version 1.x, the header-packet count and the native `fLaC` signature with STREAMINFO; one packet per further metadata block; then one FLAC frame per packet. The STREAMINFO limits match native FLAC: 1–8 channels, 4–32 bits, 8–192 kHz. A VORBIS_COMMENT channel-mask tag selects the speaker layout as in native FLAC; seek tables are ignored. A nonzero header count must match, audio must begin on a new page, and a second STREAMINFO or the invalid block type rejects.

Opening scans every frame header for its position and block size: positions must be consecutive from sample 0, each page's granule must equal the end sample of its last complete frame, and a nonzero STREAMINFO sample count must equal the total. A 64 KiB index keeps up to 2,048 packet checkpoints, halving its density when full. Frames are decoded by the native FLAC decoder when read, with both CRCs; a packet must hold exactly one frame, and every frame except the last must reach the STREAMINFO minimum block size. Seeks restore the checkpoint at or before the target and are exact.

## Resampler

`src/resample.s` converts stereo float PCM between any two rates with a polyphase windowed-sinc filter. The filter has 64 sinc zero crossings per side at a cutoff of 0.955 of the lower rate's Nyquist frequency, under a Kaiser window with beta 9: about 128 taps when upsampling, widening in proportion to the ratio when downsampling (3,072 taps from 192 kHz to 8 kHz). Output frame *k* is the input interpolated at *k × in / out*; the filter is symmetric, so there is no delay. Each phase is normalized to unit DC gain. Positions advance with exact integer arithmetic, without drift.

Coefficients are computed once per rate pair with SSE2 only (sine by a reduced-argument Taylor series, I0 by its power series), so Windows and Linux build identical tables. When the reduced output rate gives at most 2^20 phase-taps, each phase has its own row; otherwise rows are interpolated linearly. Tables are stored as duplicated floats for SSE stereo products, at most 8 MiB. The input buffer holds three half-widths plus 4,096 frames. Link edges are zero-padded.

`tests/verify-resample.py` checks 11 rate pairs, including 192 kHz to 8 kHz and the interpolated 44.1 to 44.101 kHz and 48 to 47.999 kHz paths. Every output frame is compared with a direct long-double evaluation of the filter at the exact instant (maximum observed difference 2.2e-7); restarts from later input frames reproduce the continuous output exactly; passband tones up to 0.88 of the lower Nyquist frequency stay at least 93.4 dB below the ideal resampled sine; and tones above the output Nyquist frequency are attenuated by at least 92.8 dB.

## Verification

`tests/verify-ogg-chain.py` builds chains by concatenating independently encoded links: three Vorbis links with mono, stereo and 5.1; a same-serial chain; Vorbis, Opus, FLAC and 5.1 Opus links together; an Opus-first chain; six links at 44.1, 48, 96, 22.05 and 32 kHz resampled to 44.1 kHz; and 48 short FLAC links. The reference is each link's own decode, resampled by the assembly resampler where the rate differs; continuous decodes and seeks to every link boundary and inside every link must match it exactly, and seeks inside Opus links must equal standalone seeks. Multiplexed links pair Opus with Vorbis, Speex with Vorbis, Vorbis with FLAC, and Theora video with Vorbis; each must play its first supported stream exactly. Eight FLAC-in-Ogg files (8–192 kHz, 16/24-bit, 1–8 channels, frame sizes 256–4,608) must match FFmpeg's lossless decode exactly, or for multichannel downmixes LAMP's native decode of the same frames. Seventeen malformed chains and mappings reject, and cancelled opens and reads stop cleanly.
