# AVI

LAMP 0.4.0-dev plays the audio of AVI files (`.avi`) with a handwritten demuxer (`src/avi.s`) following Microsoft's AVI RIFF format and the OpenDML extensions: a `RIFF AVI ` list, then any `RIFF AVIX` continuations. `LIST hdrl` must come before the first `LIST movi`; its stream lists (`strh`, `strf`) choose the first audio stream (`auds`) whose format LAMP decodes (or, with `--track N`, the Nth one; see [track selection](tracks.md)), and that stream's `NNwb` chunks are read from every `movi` list, including chunks grouped in `LIST rec`. Video and other streams, `JUNK`, `idx1`, OpenDML `indx`/`ix##` indexes and unknown chunks are skipped; LAMP reads the chunks in file order and needs no index.

| WAVE format tag | Audio |
| --- | --- |
| 1, 3 (or extensible) | PCM 8/16/24/32-bit and float32/64, 1–8 channels with WAVE speaker masks, as in [WAV](wav.md) |
| 6, 7 | [G.711](wav.md#compressed-audio) A-law and µ-law |
| 0x11, 2 | [IMA and Microsoft ADPCM](wav.md#compressed-audio) |
| 0x61, 0x62 | [Duck DK4 mono/stereo and DK3 stereo](wav.md#duck-dk3-and-dk4) |
| 0x50, 0x55 | [MPEG audio](mp2.md) Layers I–III, constant or variable bit rate |
| 0x2000 | [AC-3](ac3.md) |
| 0xFF | [AAC-LC and HE-AAC](aac.md): with an AudioSpecificConfig after the WAVEFORMATEX, each chunk is one raw frame; without one, the chunks are ADTS frames |

AVI audio is a byte stream cut into chunks of any size, so chunks may split ADPCM blocks, MPEG frames or PCM frames. LAMP gathers the selected stream's chunks behind a Wave64 header carrying its `strf` format, and the [WAV reader](wav.md#wave64-and-rifx) opens that image: decoding, timing and seeking are those of the same audio in WAVE (PCM and G.711 seek exactly and directly, ADPCM through the track layer, MPEG audio and AC-3 as raw streams). MPEG audio and AC-3 formats with a zero block alignment are accepted. AAC with a configuration goes through the [track layer](matroska.md#track-layer) one frame per chunk; ADTS chunks are gathered and open as an ADTS stream. Nothing trims AAC's encoder delay, as AVI has no field for it (FFmpeg's output is the same). A file truncated inside an audio chunk plays its whole frames.

AVI reports codec kind 14 for PCM, G.711 and ADPCM, and the inner codec's kind for MPEG audio (3), AAC (10) and AC-3 (11), as MPEG-TS/PS do.

Unsupported: other audio formats (DTS, WMA, Vorbis, FLAC, Yamaha and other ADPCM variants and so on) and stream numbers above 99; the `strh` start delay is ignored. Files with no audio stream LAMP decodes reject with `decode_error` 101; `movi` before `hdrl`, a second `hdrl`, `hdrl` outside the first RIFF list, or no `movi` reject with 100. An `strf` the WAV reader refuses (for example PCM with a wrong block alignment) rejects as a malformed WAV file does.

## Verification

`python3 tests/verify-avi.py` ([report](../reports/avi-verification.json)) checks:

- From FFmpeg's muxer, alone and interleaved with MJPEG video: 30 files of PCM (8–32-bit integers, float32/64), G.711 and IMA/Microsoft ADPCM, mono and stereo, and 8-bit mono in odd-sized chunks, exact against FFmpeg; 5.1 and 7.1 PCM exact against the same audio in WAVE; MPEG Layer II, constant and variable bit rate MP3 and AC-3 exact against the raw streams and at 124 dB SNR or better against FFmpeg's float decoders; AAC exact against its ADTS copy and at 138 dB against FFmpeg (the test requires 110 dB).
- The first decodable audio stream is chosen, past an unsupported Yamaha ADPCM stream.
- Files rewritten by the test: OpenDML (RIFF AVI and two RIFF AVIX lists, also exact against FFmpeg), `LIST rec` groups, `JUNK` and unknown chunks, PCM, ADPCM, MP3 and AC-3 chunks re-cut to odd sizes splitting blocks and frames, AAC as ADTS frames without a configuration, and a file truncated inside its last audio chunk, each exact against the original audio.
- Exact seeks in PCM, G.711, float64, ADPCM, MP3 (constant and variable), AC-3 (a dither-free stream, as FFmpeg's encoder dithers), AAC, ADTS, OpenDML, 5.1 and re-cut files.
- Nine malformed or unsupported files reject with the expected code; a cancelled open stops cleanly.
