# FLV

LAMP 0.4.0-dev plays the audio of Flash Video files (`.flv`) with a handwritten demuxer (`src/flv.s`) following Adobe's Video File Format Specification (version 10.1, annex E): an `FLV` version 1 header of at least nine bytes, then tags with a type, a 24-bit data size, a timestamp and the previous tag's size. The first audio tag's sound format chooses the stream, and audio tags of that format are read in file order; video tags, script data (`onMetaData`), encrypted tags and audio tags of another sound format are skipped. All supported audio paths now use signed tag timestamps for gaps, overlap/negative clipping and media-time seeks. See [packet clock rules](flv-clock.md) and [PCM/G.711/MPEG fragment ownership](flv-gathered.md).

| Sound format | Audio |
| --- | --- |
| 0, 3 | PCM, 8-bit unsigned or 16-bit little-endian (format 0, "platform byte order", read as little-endian as FFmpeg does on x86), mono or stereo, 11.025, 22.05 or 44.1 kHz |
| 7, 8 | [G.711](wav.md#compressed-audio) A-law and µ-law at 8 kHz |
| 1 | Flash ADPCM with 2-, 3-, 4- or 5-bit codes, mono or stereo |
| 2, 14 | [MPEG audio](mp2.md) (format 14: 8 kHz MP3) |
| 10 | [AAC-LC and HE-AAC](aac.md): the first sequence header's AudioSpecificConfig, then one raw frame per tag |
| 11 | [Speex](speex.md), 16 kHz mono, 1–64 frames per packet within the bounds below |

PCM, G.711 and MPEG payload bytes are gathered unchanged, then a bounded second pass creates whole-sample/frame packet views and associates them with original tags. Samples and MPEG frames can cross tag boundaries without losing bytes. PCM tags whose flags differ from the first one's (rate, size or channels) are still skipped. All audio now uses the [track layer](matroska.md#track-layer); [frame ownership and continuation clock adjustments](flv-gathered.md) define fragmented input and seeking.

Flash ADPCM (the SWF and FLV ADPCM sound data) starts each tag with a 2-bit code size, then blocks of 4096 samples per channel: each channel's 16-bit first sample and 6-bit step index, then 4095 interleaved codes. Codes expand like IMA ADPCM's, with shifts and adds over the code's magnitude bits, and update the step index through the SWF specification's tables for each code size; a last block holds as many code groups as its bits allow. Decoding follows FFmpeg's `adpcm_swf`, sample counts included, and every tag decodes independently. The decoder lives with the other ADPCM decoders in `src/adpcm.s`.

FLV reports codec kind 15 for PCM, G.711 and Flash ADPCM, and the inner codec's kind for MP3 (3) and AAC (10). FFmpeg's FLV muxer flags stereo G.711 as mono, and both FFmpeg and LAMP then read such files as mono.

Unsupported: Nellymoser and other sound formats, 5.5 kHz PCM and ADPCM, and Flash ADPCM tags above 65535 bytes reject with `decode_error` 101, as do files without a decodable audio tag. A header size below nine bytes, a file too short for its header and AAC without a sequence header reject with 100. A file ending inside a tag keeps the PCM, G.711 or MP3 bytes it holds and drops a cut AAC frame, ADPCM tag or Speex packet.

## Speex

FLV sound format 11 has no identification or sequence header. It implies
wideband Speex at 16 kHz, mono, following [Adobe specification 10.1, annex E](https://ossrs.io/lts/en-us/assets/files/flv_v10_1-5244d3059e5425eb03a15eb24537bd59.pdf).
The low audio flags are ignored, accepting both Adobe's `0xb2` and
[FFmpeg's legacy `0xb6`](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/flvenc.c).
Complete audio payloads become packets in the common track layer. Each
packet holds 1–64 frames (at most 1 MiB); Adobe Flash Player's historical
eight-frame limit does not restrict LAMP's bounded decoder. Actual frame
counts may change between tags. Unused final-group slots containing repeated
Speex end markers are accepted, with at most 64 markers and seven alignment
bits. Control-only payloads and invalid modes reject; empty tags are ignored.

`src/speex_track.s` parses the implied stream configuration and connects the
same assembly frame decoder used by Ogg. It normalizes float samples by
1/32768 and duplicates mono, without int16 clipping. Every coded frame is
decoded without inferred Ogg pre-skip or granule trimming. The selected tag
timestamps now place that PCM into media time, including gaps and clipping
([clock contracts](flv-clock.md)). Video/A/V synchronization remains open.

Seeks reset and decode/discard from the beginning, retaining exact prediction,
noise, filter and QMF histories at the target. They are cancellable, but cold
seeks in long recordings may be slow. The adapter adds no per-packet allocation:
it uses the existing track index and 2 MiB PCM buffer, plus a static 65,536-byte
decoder arena and 5,120-byte frame buffer. Decoder failures make the owning
track fail; partially decoded packet output/history is discarded on close.
FLV reports codec kind 22 (Speex).

`python3 tests/verify-speex-flv.py --bin build/speex-flv-check` compares
independently extracted FLV packets with the unchanged Speex 1.2.1 float
decoder. On Windows use `python`, `--bin bin/speex-flv-check` and optionally
`--probe` after a `--tests --probe-default-device --probe-exclusive --probe-silent`
build. `--fixtures PATH` reuses the same encoded corpus without FFmpeg.
The [Windows report](../reports/speex-flv-windows-verification.json) and
[Linux report](../reports/speex-flv-linux-verification.json) each pass:

- 25 files, including FFmpeg qualities 0–10, grouped 1/2/5/8-frame packets,
  VBR/VAD/DTX, interleaved Sorenson video, both conventional flag values,
  all changing low flags, varying packet group sizes, 64-frame null groups,
  larger headers, skipped tags, empty tags and a cut final packet.
- Exact official float PCM and 375 exact seeks, including EOF/clamping.
- 59,622,120 guarded checks, 856,960 exact float words, 235 protected file
  prefixes and 512 single-bit mutations. Accepted mutations establish bounded
  behavior, not correct damaged-file audio. Input pages are read-only and
  output canaries are checked; close clears public track state.
- Six malformed/resource-cap cases, cancelled open/read and successful reopen.

Native Windows also passes muted play/pause/resume/stop/reopen, active/paused
seek, cancelled open, simulated active/paused default-output callback recovery
and exclusive 48 kHz output with an actual grouped FLV/Speex file. This does
not establish captured hardware PCM, audible latency or physical hotplug.
Changed modules translate and assemble for ARM64 macOS; native Mac and Linux
output-device execution remain unverified for this addition. The separate
[67-check native Windows FLV regression](../reports/speex-flv-regression-windows-verification.json)
and [13-check track-selection regression](../reports/speex-flv-tracks-windows-verification.json)
also pass on the new shipping decoder objects.

## Verification

`python3 tests/verify-flv.py` ([report](../reports/flv-verification.json)) checks:

- From FFmpeg's muxer: 24 files of PCM (8- and 16-bit at 11.025-44.1 kHz), G.711 and Flash ADPCM, mono and stereo, alone and with Sorenson video, exact against FFmpeg (stereo G.711 with the test setting the stereo flag); constant and variable bit rate MP3 at 44.1 and 22.05 kHz exact against the raw streams and at 128 dB SNR or better against FFmpeg's float decoder; stereo and mono AAC exact against their ADTS copies and at 138 dB against FFmpeg (the test requires 110 dB).
- Flash ADPCM written by the test with 2-, 3-, 4- and 5-bit codes, mono and stereo: random codes, step indexes and first samples, one or two blocks per tag and partial last blocks, exact against FFmpeg.
- MP3 at 8 kHz (sound format 14) in tags cutting frames, exact against the raw stream; Nellymoser, encrypted, other-layout PCM and script tags between PCM tags skipped; a 32-byte header; AAC with a second sequence header; files cut inside their last PCM or AAC tag.
- Exact seeks in PCM, G.711, Flash ADPCM (2-, 4- and 5-bit), MP3 (constant, variable, 8 kHz) and AAC files.
- The original report has nine malformed or unsupported rejections, including Speex before its implementation. The current regression has eight; Speex is verified separately above. Other malformed or unsupported files reject with the expected code; a cancelled open stops cleanly.
