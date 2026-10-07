# AC-3 (Dolby Digital)

LAMP 0.4.0-dev decodes AC-3 (ATSC A/52) in raw `.ac3` files, Matroska (`A_AC3`) and MP4/MOV (`ac-3` sample entries) with a handwritten decoder (`src/ac3.s`, `src/ac3_block.inc`). Its structure, fixed-point mantissa path and error concealment follow FFmpeg's decoder, which the tests compare against. Packets pass through the shared [track layer](matroska.md#track-layer), so MP4 edit lists, sample durations and seeking work as for the other codecs.

## Coverage

- Bit stream ids 0-10: the standard syntax, the alternate bit stream syntax of bsid 6 (its extra downmix fields are read and ignored), and the half- and quarter-rate ids 9 and 10 (16-24 and 8-12 kHz). 32, 44.1 and 48 kHz, every frame size code (32-640 kb/s), all eight channel modes (1+1 dual mono, mono, 2/0 to 3/2) with or without LFE.
- Block switching (one 512-point or two 256-point transforms per channel and block, mixed across channels), dither flags, dynamic range words (both of dual mono), coupling with band structures, coordinates and phase flags, rematrixing with two, three or four bands, all exponent strategies (D15, D25, D45, reuse) with bandwidth changes, the parametric bit allocation with coupling leaks, delta bit allocation (new, reused and none), skip fields, every bit allocation pointer (grouped quantizers for bap 1, 2 and 4, symmetric 3 and 5, two's complement 6-15) and the additional bit stream information field.
- Mantissas become 24-bit fixed-point values shifted by their exponents; coupling, rematrixing and dither removal stay in integers; coefficients become floats scaled by the dynamic range gain, as in FFmpeg. The IMDCT (a DCT-IV through a 128- or 64-point complex FFT), the Kaiser-Bessel-derived window (alpha 5) and overlap run in double precision.
- Dither noise comes from FFmpeg's lagged Fibonacci generator seeded the same way, so dithered coefficients match FFmpeg's decode; after a seek the noise differs but has the same level.
- Multichannel output mixes to stereo with the shared WAVE speaker weights (1+1 plays its two programs as left and right; 2/2 and 3/2 surrounds count as side speakers). The stream's own downmix levels are not applied. Dynamic range compression is applied, as FFmpeg's default does.

Frames pass a CRC check over the whole frame. A frame whose CRC fails, and a block that does not decode (an exponent outside 0-24, a bandwidth code above 60, an invalid coupling range, a reserved delta strategy, missing block-0 information), repeat the last good block for the rest of the frame, as FFmpeg's concealment does.

A partial [E-AC-3 conventional-mantissa profile](eac3.md) now shares this decoder; AHT, spectral extension and dependent channel substreams remain unsupported. Reserved ids and malformed streams reject.

## Containers and timing

Raw `.ac3` files are sequences of sync frames (0x0B77), optionally after an ID3v2 tag and before an ID3v1 tag; every frame must keep the first frame's sample rate, bit stream id range and channel mode, and a truncated final frame is dropped. A file is recognised when its first frame is followed by another of the same stream or its first frame's CRC holds. Matroska and MP4 packets may hold one or more whole frames.

MP4 files written by FFmpeg's encoder carry an edit list that removes its 256 samples of encoder delay and the end padding; raw and Matroska files carry no such information and play every decoded sample.

A seek restarts one frame before the target and discards that frame's output, which rebuilds the overlap. Frames send every parameter in their first block, so streams without dither seek exactly; dithered blocks differ only in their noise.

## Precision

Decoding matches FFmpeg 6.1's float decoder at about 138-140 dB SNR, the difference being FFmpeg's single-precision transform. FFmpeg 6.1 starts as if its overlap buffers held a downmix: at the first block of a stream whose channels use different transform lengths, it copies or clears some channels' overlap, a one-block error LAMP does not reproduce. Written test streams therefore begin with such a block, when the overlap is still zero.

Decoding runs about 185 times faster than real time for 5.1 at 448 kb/s and 340 times for stereo at 192 kb/s on the test machine.

## Verification

`python3 tests/verify-ac3.py` checks:

- 20 FFmpeg-encoded raw files: mono to 5.1 (2.1, 3/0, 2/1, 3/1, 2/2, 3/2 and 3/2 with LFE), 32, 44.1 and 48 kHz, 32-640 kb/s, with coupling on and off, early coupling, rematrixing, transients and the alternate bit stream syntax: at least 138 dB against FFmpeg (multichannel through LAMP's speaker weights).
- The Python model `tests/ac3_model.py` reproduces FFmpeg's channels (at least 138 dB), so the streams written through it carry what was intended.
- 24 streams written by `tests/ac3_vectors.py` over every channel mode with and without LFE, all rates and bit stream ids 0, 4, 6, 8, 9 and 10: at least 138 dB against FFmpeg. FFmpeg's encoder uses neither short blocks, delta bit allocation, dynamic range words, skip fields, dual mono, phase flags nor bsid 9 or 10, so the writer drives the model with a reader that chooses valid values and records them, and the bit allocation sizing each mantissa is the model's own. The coverage set proves every tool above and all 16 bit allocation pointers were used.
- Matroska, MP4 and fragmented MP4 copies of three fixtures equal the raw decode exactly; a directly encoded 44.1 kHz MP4 with its priming edit matches FFmpeg; ID3v2/ID3v1 tags are skipped and a truncated final frame is dropped.
- 12 streams with corrupted frames match FFmpeg: six whose CRCs fail (FFmpeg with `-err_detect crccheck`) and six whose recomputed CRCs cover the corruption, which exercises the block errors. 60 more heavily corrupted streams decode without errors.
- 60 exact seeks in three dither-free written streams (2/0, 3/2 with LFE, mono) and their Matroska copy.
- Dependent E-AC-3 rejects as unsupported; a channel mode change, garbage after the frames and an invalid frame size reject as malformed.
- Cancelled open and read, and playback through the Linux null sink.

`src/ac3_tables.inc` holds the A/52 frame sizes, band boundaries, log-addition, hearing threshold and bit allocation parameter tables, taken from codec-ac3 (MIT License) at a pinned commit and converted back from that decoder's representation, with the mantissa levels, dynamic range gains, window, twiddles, CRC table and dither generator state computed. `python3 tests/generate-ac3-tables.py` fetches the source, checks its hash, cross-checks the tables against the standard's formulas (the log-addition table, band sizes, frame sizes and bap runs) and verifies its output with `--check`.
