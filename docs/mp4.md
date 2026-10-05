# MP4, M4A and MOV audio

LAMP 0.4.0-dev plays the audio track of ISO base media files (`.mp4`, `.m4a`) and QuickTime movies (`.mov`), including fragmented files. The demuxer (`src/mp4.s`) follows ISO/IEC 14496-12 and the QuickTime File Format and feeds the same packet track layer as [Matroska](matroska.md). Apple Lossless (`src/alac.s`) is a new decoder; the other codecs reuse LAMP's decoders.

## Track selection

A file is recognised by a leading `ftyp`, `moov`, `mdat`, `wide`, `free` or `skip` box and must hold exactly one top-level `moov`. The first enabled track whose handler is `soun` and whose first sample description is supported is played; video, text and unsupported audio tracks are skipped. Samples that refer to any other sample description reject.

| Sample entry | Decoder |
| --- | --- |
| `alac` | Apple Lossless: 16/20/24/32-bit, 1–8 channels in ALAC channel order, 8–192 kHz, frames of up to 65,536 samples |
| `mp4a` with `esds` object type 0x6B or 0x69, `.mp3` | MPEG audio Layers I–III (MPEG-1 and MPEG-2 rates) |
| `Opus` with `dOps` | Opus families 0/1 |
| `fLaC` with `dfLa` | FLAC |
| `twos`, `sowt`, `in24`, `in32`, `fl32`, `fl64`, `raw `, `lpcm` | QuickTime PCM: 8/16/24/32-bit integer and float32/64 in either byte order (`enda` inside `wave`), version 0/1/2 sound descriptions |
| `ipcm`, `fpcm` with `pcmC` | ISO/IEC 23003-5 integer and float PCM |

AAC (`esds` object type 0x40) is not decoded yet; such tracks are skipped like other unsupported entries.

## Samples and timing

Progressive files list samples from `stsz` or `stz2` (4/8/16-bit fields), `stsc` and `stco` or `co64`; every listed sample must lie inside the file and the tables must agree on the sample count. Fragmented files add the samples of every `moof`/`traf` for the track in file order, from `trun` records with `tfhd` and `trex` defaults, explicit base data offsets, `default-base-is-moof` and implicit offsets that continue the previous run. PCM chunks become packets of up to 4,096 frames. Opening reads every fragment.

Presentation follows the track's timing:

- With an edit list, the first non-empty edit starts at its media time; empty edits insert no gap. The presentation ends after the edit's duration (converted from the movie timescale) or at the end of the media, whichever comes first.
- Without one, it starts at the first sample (Opus: after the `dOps` pre-skip) and ends at the media duration.
- The media duration is the sum of the `stts` deltas, when they cover every sample, plus the fragment sample durations; when a duration is missing, decoding runs to the last packet.

Media units convert to samples at the codec rate with rounding to nearest. FFmpeg applies an edit's start but decodes the last packet whole, so its MPEG audio and Opus output can run past the edit's end; LAMP stops there.

## Apple Lossless

The 24-byte `ALACSpecificConfig` (optionally behind the `alac` box's version and flags) is validated: compatible version 0, frame length 1–65,536, bit depth 16/20/24/32, `kb` 1–32, 1–8 channels and an 8–192 kHz rate. Frames contain single-channel, channel-pair and LFE elements, with fill and data-stream elements skipped. Each element may be uncompressed or use adaptive Golomb-Rice residuals with escapes, the adaptive FIR predictor (including mode 15's two-pass prediction), stereo decorrelation and shifted low bits. A frame may declare fewer samples than the configured length, as final frames do. Channel order follows Apple's layouts and mixes to stereo with the shared WAVE speaker weights. The coupling-channel element and corrupt frames reject when the track is opened or the frame is decoded. Frames decode independently, so seeks are exact without pre-roll.

## Verification

`python3 tests/verify-mp4.py` muxes fixtures with FFmpeg:

- ALAC 16-bit, 24-bit/96 kHz, mono, 5.1 and small frames; MP3 and MP2 in MP4; Opus stereo and 5.1; FLAC 16/24-bit; nine QuickTime PCM layouts (s16/s24 in both byte orders, s32be, f32be, f64le, u8, s8) in MOV. Mono and stereo outputs match FFmpeg's decode of the same file: exactly for ALAC, FLAC and PCM, within the codec suites' tolerances for Opus and MPEG audio, after limiting FFmpeg's output to the presented duration. Source bit depths are checked.
- ALAC, Opus and FLAC files are also written as fragmented MP4 (`frag_keyframe+empty_moov`, and with `default_base_moof` and 200 ms fragments); each decodes exactly like its progressive version. ALAC equals the same stream remuxed to Matroska, FLAC its native FLAC remux and Opus its Ogg remux.
- 120 exact seeks across ALAC (including 5.1 and a fragmented file), FLAC, MP3, MP2 and PCM files, and five Opus seeks equal to Ogg Opus seeks.
- Ten malformed files reject: a truncated file, a missing `moov`, an oversized box, a sample count beyond the sizes, a chunk offset past the end, an empty `stsc`, a reference to a second sample description, an `mp4a` entry without `esds`, an invalid ALAC depth and an ALAC coupling element. Cancelled open and read stop cleanly, and an ALAC file plays through the Linux null sink.
