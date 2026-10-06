# FLV

LAMP 0.4.0-dev plays the audio of Flash Video files (`.flv`) with a handwritten demuxer (`src/flv.s`) following Adobe's Video File Format Specification (version 10.1, annex E): an `FLV` version 1 header of at least nine bytes, then tags with a type, a 24-bit data size, a timestamp and the previous tag's size. The first audio tag's sound format chooses the stream, and audio tags of that format are read in file order; video tags, script data (`onMetaData`), encrypted tags and audio tags of another sound format are skipped. Timestamps are not used.

| Sound format | Audio |
| --- | --- |
| 0, 3 | PCM, 8-bit unsigned or 16-bit little-endian (format 0, "platform byte order", read as little-endian as FFmpeg does on x86), mono or stereo, 11.025, 22.05 or 44.1 kHz |
| 7, 8 | [G.711](wav.md#compressed-audio) A-law and µ-law at 8 kHz |
| 1 | Flash ADPCM with 2-, 3-, 4- or 5-bit codes, mono or stereo |
| 2, 14 | [MPEG audio](mp2.md) (format 14: 8 kHz MP3) |
| 10 | [AAC-LC and HE-AAC](aac.md): the first sequence header's AudioSpecificConfig, then one raw frame per tag |

PCM, G.711 and MP3 tag data is gathered behind a Wave64 header and opens through the [WAV reader](wav.md#wave64-and-rifx), as [AVI](avi.md) audio does: tags may cut MP3 frames anywhere, and PCM tags whose flags differ from the first one's (another rate, size or channel count) are skipped. AAC frames and Flash ADPCM tags are packets of the [track layer](matroska.md#track-layer), so seeks restart at the tag holding the target.

Flash ADPCM (the SWF and FLV ADPCM sound data) starts each tag with a 2-bit code size, then blocks of 4096 samples per channel: each channel's 16-bit first sample and 6-bit step index, then 4095 interleaved codes. Codes expand like IMA ADPCM's, with shifts and adds over the code's magnitude bits, and update the step index through the SWF specification's tables for each code size; a last block holds as many code groups as its bits allow. Decoding follows FFmpeg's `adpcm_swf`, sample counts included, and every tag decodes independently. The decoder lives with the other ADPCM decoders in `src/adpcm.s`.

FLV reports codec kind 15 for PCM, G.711 and Flash ADPCM, and the inner codec's kind for MP3 (3) and AAC (10). FFmpeg's FLV muxer flags stereo G.711 as mono, and both FFmpeg and LAMP then read such files as mono.

Unsupported: Nellymoser, Speex and other sound formats, 5.5 kHz PCM and ADPCM, and Flash ADPCM tags above 65535 bytes reject with `decode_error` 101, as do files without a decodable audio tag. A header size below nine bytes, a file too short for its header and AAC without a sequence header reject with 100. A file ending inside a tag keeps the PCM, G.711 or MP3 bytes it holds and drops a cut AAC frame or ADPCM tag.

## Verification

`python3 tests/verify-flv.py` ([report](../reports/flv-verification.json)) checks:

- From FFmpeg's muxer: 24 files of PCM (8- and 16-bit at 11.025-44.1 kHz), G.711 and Flash ADPCM, mono and stereo, alone and with Sorenson video, exact against FFmpeg (stereo G.711 with the test setting the stereo flag); constant and variable bit rate MP3 at 44.1 and 22.05 kHz exact against the raw streams and at 128 dB SNR or better against FFmpeg's float decoder; stereo and mono AAC exact against their ADTS copies and at 138 dB against FFmpeg (the test requires 110 dB).
- Flash ADPCM written by the test with 2-, 3-, 4- and 5-bit codes, mono and stereo: random codes, step indexes and first samples, one or two blocks per tag and partial last blocks, exact against FFmpeg.
- MP3 at 8 kHz (sound format 14) in tags cutting frames, exact against the raw stream; Nellymoser, encrypted, other-layout PCM and script tags between PCM tags skipped; a 32-byte header; AAC with a second sequence header; files cut inside their last PCM or AAC tag.
- Exact seeks in PCM, G.711, Flash ADPCM (2-, 4- and 5-bit), MP3 (constant, variable, 8 kHz) and AAC files.
- Nine malformed or unsupported files reject with the expected code; a cancelled open stops cleanly.
