# AIFF/AIFC audio and ordered channel layouts

Current 0.4.0-dev source accepts `FORM AIFF` and `FORM AIFC` with 1–8 channels. Original assembly framing code shares the mapped-input PCM reader; playback/export remain stereo float32. The public v0.3.0 archive predates this support.

## Encodings and precision

AIFF uses signed big-endian PCM at every precision from 1 through 32 bits, stored in `ceil(precision / 8)` bytes. Valid bits are left-aligned and unused low bits are ignored, following [Apple's AIFF 1.3 specification](https://mmsp.ece.mcgill.ca/Documents/AudioFormats/AIFF/Docs/AIFF-1.3.pdf). Signed 8-bit input differs from WAVE's unsigned 8-bit convention.

| AIFC identifier | Implemented audio |
| --- | --- |
| `NONE`, `twos` | Signed big-endian PCM, 1–32 valid bits in the smallest whole-byte container |
| `sowt` | Signed little-endian PCM, 1–32 valid bits in the smallest whole-byte container |
| `in24`, `in32` | Signed big-endian PCM in fixed 24/32-bit containers; valid precision must fit |
| `raw ` | Unsigned PCM in an 8-bit container, 1–8 valid bits |
| `fl32`, `FL32` | Big-endian IEEE float32; COMM precision must be 32 |
| `fl64`, `FL64` | Big-endian IEEE float64; COMM precision must be 64 |
| `alaw`, `ALAW`, `ulaw`, `ULAW` | G.711 A-law and mu-law codes in an 8-bit container, expanded to 16 bits as in [WAVE](wav.md#compressed-audio); COMM precision up to 16 |

The numerical policy matches [WAVE](wav.md): double conversion/mixing, one final float rounding, silence for NaN/Inf, and finite float64 inputs/outputs bounded to the float32 range. Native surround/float64 output, configurable limiting and compressed AIFC codecs such as IMA, MACE and GSM remain unfinished.

## Framing, rates and seeking

FORM size, every chunk extent and word padding are checked through the declared container end, including metadata after audio. Chunks may appear in any order. Exactly one COMM is required; SSND may be absent only for zero declared frames. Duplicate COMM/SSND/CHAN/FVER chunks, truncated headers and impossible sound offsets fail cleanly. Unknown chunks are skipped without scanning or allocating their payloads.

COMM frame count controls duration and the effective audio range. SSND offset bytes are skipped before audio; declared frames must fit the remaining payload. Surplus sound bytes can be disk-block padding and are ignored. SSND blockSize is an alignment hint and does not change contiguous sample interpretation. Pascal compression names must fit, including internal padding; their text does not select the decoder. Future bytes are skipped. Following [Apple's AIFF-C reader guidance](https://mmsp.ece.mcgill.ca/Documents/AudioFormats/AIFF/Docs/AIFF-C.9.26.91.pdf), recognizable critical chunks remain usable when FVER is absent or unfamiliar; a present FVER still needs its complete version field.

A positive, normalized 80-bit extended sample rate rounds to the nearest integer hertz, with half-hertz ties upward, then must fit 8–192 kHz. The parser rounds the quotient using the fractional bit, avoiding overflow when the significand is almost `2^64`. Negative, zero, nonfinite and unnormalized rates fail cleanly. Fractional input therefore has a small, explicit clock approximation; exact fractional-rate output/resampling remains unfinished.

Offset and seek products use checked 64-bit arithmetic despite the format's 32-bit FORM/chunk lengths and frame count. Direct seeks use physical block alignment and clamp to declared EOF. Empty streams, zero-capacity reads, closed-state refusal and cancellation are covered; read errors remain sticky and cancelled seeks leave state untouched. Whole-file mapping depends on Windows virtual-address/mapping support. No PCM or seek-index allocation is added.

## Speaker order and CHAN

Untagged mono/stereo/three-channel files use C, L/R and L/R/C. Four channels follow AIFF's L/C/R/Cs convention; six follow L/Lc/C/R/Rc/Cs. Five, seven and eight channels use conventional fallbacks: L/R/C/Ls/Rs; L/R/C/LFE/Ls/Rs/Cs; and L/R/C/LFE/Ls/Rs/Lsd/Rsd. CHAN overrides these inferences, including quad and 5.1.

CHAN follows [Apple Core Audio layout definitions](https://developer-mdn.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html). Tags 100–144 are supported except Mid/Side 104 and Ambisonic 107. This covers positional mono/stereo, quad/cube, MPEG, DVD, AudioUnit and AAC arrangements in that range. Matrix stereo and XY present two ports as stereo; matrix-surround expansion remains unfinished. Tag 147 (discrete in order) and the unknown-layout tag present the first two source ports, duplicate mono and consume extra tracks without mixing them. Other/newer tags fail cleanly.

Bitmaps require exactly as many assigned, defined WAVE speaker bits as channels. Descriptors require one bounded 20-byte record per channel. They support all eighteen WAVE positions, rear-surround aliases, LFE2, center-surround-direct, mono, encoded left/right totals and headphone left/right. Repeated positions mix as separate tracks. Unused/unknown roles are silent; discrete roles present the first two source ports. Coordinate-only, Ambisonic, Mid/Side and unsupported labels fail cleanly; coordinates do not override a recognized positional label.

Ordered channels use the [shared stereo weights/headroom policy](flac.md#stereo-policy) without copying or reordering PCM. Normalization counts assigned tracks, including repeated positions. Native multichannel output and broader role/coordinate/tag rendering remain roadmap work.

## Verification and reference limits

Run `python3 tests/verify-containers.py aiff` (set `LAMP_OUT` for another build directory). Tests require Node.js, FFmpeg, Python, a C compiler for test oracles, and a filesystem with sparse-file support (NTFS, ext4, XFS, Btrfs); C executables remain test-only. The [recorded report](../reports/aiff-verification.json) covers every PCM precision/channel count, integer identifiers, float extremes, layout tags/bitmaps/roles, repeated/discrete/silent descriptors, arbitrary chunk order, sound offsets, block padding, Pascal names, future fields, empty streams, fractional rates, Unicode paths and modern encoders. The complete run passes 1,977 files (including 168 modern-encoder files), 19 sparse inputs, 30,443 exact seeks, 29,595 guarded reads, 9,942 cancellation checks and 127,744 reopen checks. All 303 malformed files, including 256 seeded size/offset mutations, fail cleanly. The largest sparse input is 4,294,901,832 logical bytes; maximum allocated storage is 393,216 bytes. Sparse files approach the FORM limit and cross 2 GiB offsets, with large metadata before/after audio; they are flushed before allocation measurement and removed after testing.

Independent native-channel comparisons use original containers where supported, with a separate numeric speaker oracle for stereo. FFmpeg n8.0.1's [AIFF reader](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/aiffdec.c) fixes sowt to 16-bit PCM, handles COMM counts as signed integers, can overflow extended-rate rounding near powers of two, and skips odd COMM padding twice. Those cases compare physical PCM at a known bounded offset or selected integer rate. Padded sound tails compare only declared samples through the raw reader; dirty unused-bit fixtures test LAMP's discard policy without claiming FFmpeg equality. Each report entry identifies its reference path. Chunk order and odd sound offsets also have original-container comparisons. These checks establish documented coverage, not complete conformance or performance superiority.

The actual assembly renderer also has a synthetic AIFF preview: `tests/render-ui.ps1 -OutputDirectory bin/verify-build -CodecKind 6`. This renders the new codec label without interacting with a desktop window.

Six AIFF/AIFC WASAPI scenarios cover PCM16 in both byte orders plus PCM24/float64 5.1 and 7.1. They verify playback, pause/resume, stop/reopen, seeking, paused seeking and cancelled open. Historical benchmarks retain their original binaries and do not measure these new paths.
