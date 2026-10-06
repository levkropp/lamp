# Core Audio Format

LAMP 0.4.0-dev plays Apple Core Audio Format files (`.caf`) with a handwritten reader (`src/caf.inc`) following Apple's CAF specification: a `caff` header (version 1), then big-endian chunks with 64-bit sizes. `desc` must come first; `data` (after its four-byte edit count) may be sized -1 to run to the end of the file; `pakt`, `kuki` and `chan` are read; other chunks (`free`, `info`, `uuid`, `strg` and so on) are skipped.

| Format ID | Audio |
| --- | --- |
| `lpcm` | Signed 8-32-bit integers and float32/64, big- or little-endian, one frame per packet, the sample size filling its bytes; read directly like [AIFF-C](aiff.md), with direct seeks |
| `alaw`, `ulaw` | [G.711](wav.md#compressed-audio), read directly |
| `ima4` | QuickTime IMA ADPCM (34-byte blocks per channel, 64 frames), through the [ADPCM decoder](wav.md#compressed-audio) |
| `alac` | [Apple Lossless](mp4.md#apple-lossless); the cookie is the 24-byte ALACSpecificConfig or the older `frma`/`alac` atoms around it |
| `aac ` | [AAC-LC and HE-AAC](aac.md); the cookie is an MPEG-4 ES_Descriptor holding the AudioSpecificConfig |
| `.mp1`, `.mp2`, `.mp3` | [MPEG audio](mp2.md) |
| `ac-3` | [AC-3](ac3.md) |
| `opus` | [Opus](opus.md), mono or stereo, from a mapping family 0 header LAMP builds (CAF carries no OpusHead) |

Linear PCM and G.711 with a `chan` chunk use its Core Audio layout (tag, bitmap or descriptions) exactly as AIFF-C's CHAN chunk is read; without one, the default WAVE layout of the channel count mixes to stereo. Packetized formats go through the shared [track layer](matroska.md#track-layer): packets of `desc`'s constant size, or of the sizes in `pakt`, whose priming and remainder frames trim the start and end. Seeks restart at the packet holding the target with each codec's pre-roll.

IMA4 block headers keep only the top nine bits of the predictor, and a header close to the running state continues it (as FFmpeg and QuickTime decode it), so every block depends on the ones before. A seek decodes one primer block; afterwards the output can differ from continuous decoding by an offset of at most 127/32768 (the predictor's low seven bits), which the tests measure.

Unsupported: variable frames per packet (`desc` frames per packet 0), other format IDs (MACE, iLBC, AMR, FLAC in CAF and others), linear PCM whose sample size leaves its bytes partly unused, more than eight channels and rates outside 8-192 kHz reject with `decode_error` 101. A missing or misplaced `desc`, a missing `data` chunk, chunks or packet tables running past their bounds, other chunks sized -1 and missing cookies reject with 100.

## Verification

`python3 tests/verify-caf-wave64.py` ([report](../reports/caf-wave64-verification.json)) checks:

- From FFmpeg's muxer: 28 files of linear PCM at every integer size and float32/64 in both byte orders, G.711 and IMA4, mono and stereo, exact against FFmpeg; 3.0, quad, 5.1 and 7.1 linear PCM with FFmpeg's `chan` layout tags, exact against the same audio in WAVE; ALAC (16- and 24-bit, mono to 5.1) exact against its Matroska copy, and mono and stereo against FFmpeg; MPEG Layer II/III and AC-3 exact against the raw streams and close to FFmpeg's float decoders; Opus exact against its Ogg copy after the pre-skip.
- CAF written by the test: AAC with an ES_Descriptor cookie and a packet table trimming 2112 priming and 700 remainder frames, exact against the trimmed ADTS stream; a new-style ALAC cookie with a data chunk sized -1 and a `uuid` chunk; 5.1 linear PCM with a channel bitmap or no `chan` chunk, exact against WAVE.
- Exact seeks in linear PCM, G.711, ALAC, MP3, AAC and 5.1 files, and IMA4 seeks within 127/32768.
- 13 malformed or unsupported CAF files reject with the expected code; a cancelled open stops cleanly.
