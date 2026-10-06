# Monkey's Audio

LAMP 0.4.0-dev decodes Monkey's Audio (`.ape`) files of versions 3930–3990 with a handwritten decoder (`src/ape.s`). That covers files from Monkey's Audio 3.93 on, up to version 3990, which Monkey's Audio 3.99 and JMAC write. Range decoding, filters, predictors and the decoding pass follow FFmpeg's decoder (`libavcodec/apedec.c`) and demuxer (`libavformat/ape.c`); the tests compare against FFmpeg and against the encoded sources.

## Coverage

- Mono and stereo, 8, 16 and 24 bits, 8–192 kHz, compression levels 1000 (fast) to 5000 (insane).
- Headers: the descriptor and header of versions 3980 and later, with any frame length. Earlier versions use the 32-byte header, with an optional peak level, seek element count and stored WAV header; their frames are fixed at 73,728 blocks before 3950 and 294,912 from 3950. A stored WAV header and a WAV tail are skipped. ID3v2 tags may come before the header.
- Residuals: the range coder with two adaptive Rice parameters. Version 3990 codes overflow multiples of a pivot, with escapes and pivots of 16 bits or more. Earlier versions code bits above k−1, with escapes that send the bit count, including counts above 16. Channels are interleaved block by block.
- The cascade of sign-LMS filters of each level: none; 16; 64; 32 and 256; or 16, 256 and 1280 taps. Each tap moves with the residual's sign. Adaption values follow version 3980 and later (8, 16 or 32 by the output against its running average), or earlier versions (±4).
- The 3950 predictor (versions 3950 and later): two four-tap stages, with the other channel's five-tap stage in stereo. Before 3950, the 3930 predictor. The output is mid/side decorrelated.
- 24-bit stereo files predicted in 32-bit arithmetic, as Monkey's Audio 3.99 and JMAC do, or in 64-bit arithmetic. As FFmpeg does, each 4,608-block pass is decoded both ways until one leaves 24 bits; the other way is kept from then on.
- Frame flags: stereo or mono silence, and pseudo-stereo (one channel coded, played in both). A flag marking one channel silent is ignored, as FFmpeg ignores it.
- Output: 8-bit samples as int8 divided by 2^7, 16-bit by 2^15, 24-bit (in 32) by 2^31, FFmpeg's sample presentation. Mono plays in both channels.

Every frame's CRC is checked; FFmpeg checks it only with `-err_detect crccheck`. Decoding stops with `decode_error` 100 on a failed CRC, on data read past the frame's end (a damaged or cut frame), on a symbol out of range, or on a frame that starts beyond the end of the file. Audio decoded before the failure has played; a failed frame's last pass does not.

Rejected with `decode_error` 101: versions before 3930 (their entropy coders and predictors differ, and no encoder for them was at hand to test with) and after 3990, more than two channels, other sample sizes, and rates outside 8–192 kHz. Malformed headers reject with `decode_error` 100. That covers a compression level that is not a multiple of 1000 in 1000–5000, no frames, a final frame longer than a frame, a seek table shorter than the frame count or out of order, and a descriptor shorter than 52 bytes. FFmpeg instead skips a frame whose seek entry goes backwards.

### Differences from FFmpeg

A filter's rounded sum, `(sum + 2^(bits−1)) >> bits`, is added in 32 bits, as Monkey's Audio 3.99 and JMAC do. FFmpeg 6.1 adds it in 64 bits. The two differ only when the sum lies within the rounding term of 2^31, which happens in loud 24-bit stereo at level 5000. There, FFmpeg's decode departs from the source and fails its own CRC check, while LAMP's equals the source.

## Files

The header gives the frame count, the blocks per frame and in the last frame, and a seek table of each frame's byte position (relative to the `MAC ` header). Frame data is a byte stream stored as little-endian 32-bit words, and a frame may start at any byte of a word. LAMP reads a frame as FFmpeg's demuxer cuts it: from the word holding its start to the next frame's start. The last frame runs to the end of the file less the WAV tail. Each frame holds a big-endian CRC (bit 31 announcing a flags word), the flags, an unused byte, and the range coder's bytes. Versions before 3950 may read two zero bytes past their data, as FFmpeg allows them.

Frames decode independently; a seek restarts at the frame holding the target and decodes up to it. Frames are long (1.7 to 27 seconds at 44.1 kHz), so a seek decodes up to one frame. Decoding runs in passes of 4,608 blocks, so playback starts after one pass, whatever the frame length.

APEv2 tags (and pictures in binary items such as `Cover Art (Front)`) and ID3v2/ID3v1 tags are read as for [other raw streams](tags.md).

## Speed

On the test machine, a 60-second 44.1 kHz stereo 16-bit file (JMAC) decodes in 0.28 s at level 1000 and 0.35 s, 0.36 s and 0.50 s at levels 2000 to 4000. At level 5000 (insane) it takes 1.15 s, 52 times real time; at level 1000 it runs 215 times real time. FFmpeg's command line, on one thread, takes 0.26, 0.36, 0.39, 0.56 and 1.13 s. The filters' products run eight taps at a time with SSE2. A 24-bit stereo file whose predictor arithmetic is still undecided runs its predictor twice per pass.

## Verification

`python3 tests/verify-ape.py` (needs JMAC: `libjmac-java` and a Java runtime) checks:

- 49 files from JMAC (`libjmac-java`, a Java port of Monkey's Audio 3.99). These are stereo, loud stereo, mono, 8-, 16- and 24-bit and 8–192 kHz files at all five levels, silence (silence frames), identical channels (pseudo-stereo frames), and 30-second files of 18, 5 and 2 frames at levels 1000, 4000 and 5000. Every decode equals its source exactly. Each also equals FFmpeg's decode with `-err_detect crccheck`, except the three 24-bit stereo files at level 5000, where FFmpeg fails its own CRC check (see above).
- 52 streams written by `tests/ape_vectors.py`, covering what JMAC never writes:
  - versions 3930, 3940, 3950, 3960, 3970, 3980, 3985 and 3990 at levels 1000–3000 (and 4000 and 5000 for some), stereo and mono;
  - the 32-byte header with a peak level, a seek element count and no stored WAV header; WAV tails;
  - the 3900 residual model with its escapes and counts above 16 bits; the 3990 model's escapes and wide pivots;
  - the 3930 predictor; adaption before 3980;
  - 24-bit stereo from the 64-bit predictor (its predictions beyond 32 bits) and from the 32-bit one;
  - frame flags (stereo silence, mono silence, pseudo-stereo, an ignored single-channel silence flag); frames starting at each byte of a word;
  - 8-bit stereo and mono; frames of 73,728 and 294,912 blocks in early versions.

  The writer inverts the decoder step by step, so the PCM written is the reference. LAMP and FFmpeg (checking CRCs) both decode every stream to it exactly. A coverage set confirms all 41 listed features were written.
- 120 seeks (`tests/seek-oracle.c`) in eight files, with frames of 3,000 to 1,179,648 blocks, equal continuous decoding.
- ID3v2 before and APEv2 after the stream: the decode is unchanged; `--tags` reads the APEv2 title and artist, as ffprobe does, and ignores the ID3v2 title, as FFmpeg does. `--cover` writes the APEv2 `Cover Art (Front)` picture.
- Damage: a flipped bit stops decoding with `decode_error` 100 at its frame's CRC. So do a file cut inside its last frame and one cut where its last frame starts. Each output is a prefix of FFmpeg's decode of the same file.
- Six malformed headers reject with `decode_error` 100: a decreasing seek table, levels 6000 and 1500, no frames, a final frame longer than a frame, and a 40-byte descriptor. Versions 3920 and 3991, three channels, 32 bits and 7 kHz reject with `decode_error` 101. A cancelled open stops cleanly.
- With PulseAudio, a 24-bit level 5000 file plays through the private null sink without underruns.

`tests/verify-robustness.py` also mutates two written Monkey's Audio files (versions 3990 and 3950) 500 times each.

Format constants: the cumulative frequency tables of the 3.97 and 3.98 residual models (22 values each), the filter orders and fraction bits of the five levels and the predictors' initial coefficients (360, 317, −109, 98) are as FFmpeg's decoder lists them, from Monkey's Audio. The tests' writer (`tests/ape_vectors.py`) holds its own copy and every written stream decodes to its PCM in FFmpeg and LAMP. The CRC table is built at open from the reflected polynomial 0xEDB88320.
