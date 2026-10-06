# Matroska and WebM audio

LAMP 0.4.0-dev plays the audio track of Matroska (`.mka`, `.mkv`) and WebM (`.webm`) files: audio-only files, and the audio of video files while video remains future work. The demuxer (`src/mkv.s`) follows RFC 9559 (Matroska) and RFC 8794 (EBML). It feeds a container-neutral packet track layer (`src/track.s`) that the [MP4 demuxer](mp4.md) shares.

## Track selection

The demuxer selects one audio track: the first enabled audio track with a supported codec whose FlagDefault is set, or else the first enabled audio track with a supported codec. Video, subtitle and other tracks, unsupported audio tracks, and tracks with ContentEncodings (header stripping, compression or encryption) are skipped. A file without a usable audio track rejects. Manual track selection is not available yet.

| CodecID | Decoder |
| --- | --- |
| `A_OPUS` | Opus families 0/1 (OpusHead in CodecPrivate); pre-skip from OpusHead |
| `A_VORBIS` | Vorbis (three Xiph-laced headers in CodecPrivate) |
| `A_FLAC` | FLAC (`fLaC` and metadata blocks in CodecPrivate) |
| `A_ALAC` | Apple Lossless (`ALACSpecificConfig` in CodecPrivate); see [MP4 notes](mp4.md#apple-lossless) |
| `A_AAC` | [AAC-LC or HE-AAC (v1 and v2)](aac.md) (AudioSpecificConfig in CodecPrivate); the legacy `A_AAC/MPEG2/...` and `A_AAC/MPEG4/...` IDs are not recognised |
| `A_AC3` | [AC-3](ac3.md); `A_EAC3` is recognised and rejects as unsupported |
| `A_MPEG/L1`, `A_MPEG/L2`, `A_MPEG/L3` | MPEG audio Layers I–III, one frame per packet |
| `A_PCM/INT/LIT`, `A_PCM/INT/BIG`, `A_PCM/FLOAT/IEEE` | PCM: unsigned 8-bit, signed 16/24/32-bit in either byte order, float32/64; 1–8 channels; integral 8–192 kHz SamplingFrequency |

AC-3, E-AC-3, DTS and other CodecIDs are not decoded yet; such tracks are skipped.

## Structure

The EBML header must name DocType `matroska` or `webm`. Element sizes are checked against their parents. Segment and Cluster may have unknown sizes, as live recorders write them; an unknown-size Cluster ends at the next Segment-level element. Other elements must have known sizes. SimpleBlock and BlockGroup/Block frames of the selected track become packets in file order, with Xiph, EBML and fixed lacing; laced sizes must fit their block and fixed lacing must divide it exactly. Timestamps are not used for decoding: the codec's own packet durations place samples, so gaps or overlaps in timestamps do not change output.

DiscardPadding on the final packet trims the end, converted from nanoseconds to samples at the codec's rate with rounding to nearest, as FFmpeg does. DiscardPadding on any other packet rejects, as does a negative value. Opening reads every cluster, so opening a long video file reads most of it; Cues are not used yet.

## Track layer

A demuxer lists packets as pointers into the mapped file and names the codec, its private data and start/end trimming. `track_finish` opens the codec and asks it for every packet's duration: Opus TOC, Vorbis block sizes and overlap, FLAC frame headers (positions must be consecutive), ALAC frame headers, MPEG audio headers (layer, version, rate and channels must not change), and PCM sizes, which must be whole frames. Each decoded packet must produce exactly its scanned duration. A track may hold 16,777,216 packets; the table reserves 384 MiB of address space and commits 192 KiB per 8,192 packets, so memory follows the file. Packets of up to 65,536 decoded frames are supported.

Seeking finds the packet holding the target and restarts there with the codec's pre-roll: FLAC, ALAC and PCM packets decode independently, Vorbis decodes one primer packet whose output is skipped, MPEG audio decodes two frames before the target and Layer III also earlier frames holding up to 2 KiB of bit-reservoir data, and Opus starts at least 80 ms before the target. Layer III frames whose reservoir lies before the restart point emit silence and are discarded; once a frame finds all of its main data, later frames are exact. Vorbis, FLAC, PCM and MPEG audio seeks therefore equal continuous decoding; Opus seeks equal LAMP's Ogg Opus seeks.

## Verification

`python3 tests/verify-matroska.py` muxes fixtures with FFmpeg:

- 24 files: Opus stereo/mono CBR/5.1 and Vorbis stereo/mono/5.1 as both `.mka` and `.webm`; FLAC 16/24-bit and 5.1; MP3; MP2; PCM s16/s24/s32be/f32/f64/u8 and 5.1. Mono and stereo outputs are compared with FFmpeg's decode of the same file: exact for FLAC and PCM, and within the codec suites' tolerances for Opus, Vorbis and MPEG audio. Opus and FLAC must also equal LAMP's decode of the same stream remuxed to Ogg, 5.1 PCM its WAV remux, and 5.1 Vorbis a direct Ogg encode.
- A test-only muxer rewrites seven of them with Xiph, EBML and fixed lacing, unknown-size Segment and Clusters, a second track with FlagDefault, and an unsupported AC-3 track and a VP9 video track before the audio; all 42 variants decode identically.
- 90 exact seeks on six files (Vorbis, FLAC, PCM, MP3, MP2, 5.1 Vorbis WebM) and ten Opus seeks equal to Ogg Opus seeks.
- Nine malformed files reject: a truncated file, a wrong DocType, no supported audio, a ContentEncodings track, Opus without CodecPrivate, a corrupt FLAC frame, Xiph and fixed lacing that do not fit, and DiscardPadding before the last packet. Cancelled open and read stop cleanly, and a WebM Opus file plays through the Linux null sink.

FFmpeg's Ogg remux from Matroska drops DiscardPadding and rounds granules from millisecond timestamps. LAMP therefore compares Opus against the Matroska presentation range, ignores FLAC-in-Ogg granules (FLAC frames carry exact positions), and uses a direct Ogg encode for the Vorbis comparison, because LAMP rejects Vorbis granules that contradict packet durations.
