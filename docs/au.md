# Sun/NeXT AU

LAMP 0.4.0-dev plays Sun/NeXT audio files (`.au`, `.snd`) with a handwritten reader (`src/au.inc`): a `.snd` header of six big-endian 32-bit fields (data offset, data size, encoding, rate, channels), an annotation up to the data offset, then interleaved samples that the PCM reader reads directly, with exact seeks. G.726 and G.722 data go through the same packets as in WAVE files. FFmpeg's AU muxer labels every G.726 code size 23, so such files decode as 4-bit codes, as FFmpeg decodes them.

| Encoding | Samples |
| --- | --- |
| 1, 27 | [G.711](wav.md#compressed-audio) µ-law and A-law |
| 2, 3, 4, 5 | Signed 8-, 16-, 24- and 32-bit big-endian PCM |
| 6, 7 | Big-endian IEEE float32 and float64 |
| 23, 25, 26, `7262` | [G.726](wav.md#compressed-audio) with 4-, 3-, 5- and 2-bit codes (G.721, G.723 at 24 and 40 kbit/s, G.726 at 16 kbit/s), packed from the least significant bit, mono |
| 24 | [G.722](wav.md#compressed-audio), mono |

A data size of 0xFFFFFFFF (written by streaming encoders) runs to the end of the file; a declared size beyond the file ends with the file, and bytes after the declared data are ignored. Whole frames play when a file ends inside one. Channels (1–8) mix to stereo with the default WAVE speaker layout of their count; rates must be 8–192 kHz.

The annotation's `Title=`, `Artist=`, `Album=`, `Track=` and `Genre=` lines (any case, as FFmpeg writes and reads them) are the file's [tags](tags.md).

Unsupported: other encodings, G.726 and G.722 with more than one channel, more than eight channels and rates outside 8–192 kHz reject with `decode_error` 101; no channels, a zero rate, a data offset below 24 or past the end of the file reject with 100.

## Verification

`python3 tests/verify-au.py` ([report](../reports/au-verification.json)) checks 16 FFmpeg-written files (signed 8–32-bit, float32/64, A-law and µ-law, mono and stereo, 8–96 kHz) exact against FFmpeg, 5.1 exact against the same audio in WAVE, rewritten headers (an unknown size, a long annotation, no annotation, trailing bytes) and two files cut inside a frame exact against the original's audio, exact seeks in six files, and nine malformed or unsupported headers. G.726 and G.722 in AU are checked by `tests/verify-telephony.py` (see [WAVE notes](wav.md#compressed-audio)).
