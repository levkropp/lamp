# RIFF/RF64/BW64, Wave64 and RIFX audio, precision and speaker layouts

Current 0.4.0-dev source accepts little-endian RIFF/RF64/BW64 audio framing with 1–8 channels and rates from 8–192 kHz. PCM containers are unsigned 8-bit or signed 16/24/32-bit; IEEE input can be float32 or float64. Both basic and extensible headers are supported. G.711, IMA and Microsoft ADPCM, MPEG audio and AC-3 data also play; see [compressed audio](#compressed-audio). Sony Wave64 and big-endian RIFX files use the same fmt and data rules; see [Wave64 and RIFX](#wave64-and-rifx). The public v0.3.0 download retains its earlier mono/stereo RIFF PCM/float32 implementation.

## Precision and numeric conversion

Extensible PCM accepts valid precision from 1 bit through the physical container width. Samples are left-aligned as specified by [Microsoft's WAVEFORMATEXTENSIBLE documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-waveformatextensible). Unused low bits are ignored, so 24-bit precision in a 32-bit container is read as four bytes per sample. Zero valid precision is interpreted as the full container width. Float valid precision must equal the container width or be zero.

Every integer sample converts exactly to double before scaling and mixing; the final stereo value rounds once to float. Float32 input is promoted exactly. NaN and infinity become silence. Finite float64 samples are bounded to the representable float32 range before mixing, and mixed outputs receive the same bound before conversion. This prevents float overflow while retaining finite headroom above unit amplitude. Extremely large cancelling float64 samples therefore follow this bounded input policy, rather than arbitrary double-range algebra. Export and WASAPI output remain stereo float32; native float64/surround output and configurable headroom/limiting remain unfinished.

## Channel assignment and mixing

Basic headers lack speaker masks; LAMP infers the conventional FLAC/WAVE layouts for 1–8 channels. Extensible headers specify increasing WAVE speaker-bit order. The shared [stereo speaker policy](flac.md#stereo-policy) handles all eighteen defined positions, including height speakers. It uses double coefficients and accumulation, with one shared normalization factor for both output channels.

WAVE-specific rules differ from FLAC comment masks. A nonzero mask with fewer set bits than channels leaves the remaining tracks unassigned and silent. A mask with more bits than channels uses its lowest assigned positions and ignores the extra high bits, following Microsoft's channel-count rule. Reserved speaker bits fail cleanly. A zero mask denotes direct-out data; LAMP presents the first two source ports as stereo, duplicates a single port, and consumes other tracks without mixing them. It does not infer an Ambisonic transform or surround layout from direct-out data.

## Bounds, seeking and cancellation

Container/chunk lengths, format extensions, subtype GUID, channel/rate/container values, byte rate and block alignment are checked before playback. A data payload must contain whole interleaved frames. Unknown chunks are skipped with word padding, including chunks after audio. Duplicate format/data/fact chunks, data preceding the format, missing padding and incomplete trailing headers fail cleanly. One contiguous data chunk is required; segmented data and `wavl` remain unsupported. Declared extension bytes must fit their chunk; future extension bytes can be skipped after the known fields.

The decoder reads directly from its existing file mapping. Multichannel WAV adds no PCM/index allocation. Direct seeking multiplies the frame position by the physical block alignment, regardless of valid precision, and clamps at EOF. Zero-capacity reads write nothing. Cancelled open/read requests fail cleanly; read errors remain sticky until close/reopen. A cancelled seek performs no work and leaves decoding state untouched.

## RF64/BW64 framing and large files

The original assembly parser follows the size-selection rules in [EBU Tech 3306 (2009)](https://tech.ebu.ch/docs/tech/tech3306-2009.pdf) and [ITU-R BS.2088-2](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.2088-2-202511-I!!PDF-E.pdf). RF64/BW64 require a first `ds64` chunk with its complete 28-byte prefix. A `0xffffffff` container or data size selects its 64-bit replacement; finite 32-bit sizes take precedence. The optional table contains at most 4,096 entries and must fit its payload. Other sentinel-sized chunks consume the first unused matching FourCC entry. Repeated IDs consume entries in order; different IDs may appear in another order. Unresolved sentinel sizes and unused entries fail cleanly. A fixed 512-byte bitmap bounds parser state without per-open allocation. Future `ds64` bytes use ordinary word padding.

Frame counts come from effective data length divided by physical block alignment. A nonzero `fact` count must agree; zero means unspecified. An RF64 `fact` sentinel selects the 64-bit sample-count field. Otherwise that field is unused. BW64's corresponding eight bytes are always ignored, as required by its standard, and do not control duration or allocation. BW64 has no defined `fact` sentinel replacement. Addition, payload ends, padding and mapped-file bounds use checked 64-bit arithmetic. Unknown multi-gigabyte metadata is skipped by offset without scanning or copying its contents. Direct seeks retain 64-bit positions, including more than `2^32` frames. Whole-file mapping still depends on available virtual address space and Windows mapping support.

BW64 support covers audio framing and the existing WAVE speaker policy. ADM XML, `chna` track relationships, scene/object rendering, embedded control/bitstream channels, metadata display and native surround output remain unfinished. Metadata can be skipped without interpreting scene semantics. RIFX, WAVE64 and compressed WAV also remain roadmap work; this is partial WAV/BW64 coverage.

Run `python3 tests/verify-containers.py rf64` for the [recorded report](../reports/rf64-verification.json): 538 files, 16 sparse large-file fixtures, 8,950 exact seeks and 312 malformed-input rejections, including 256 seeded size/table mutations. Tests cover basic/extensible PCM/float across all channel counts, every valid PCM precision with mono/eight-channel input, finite/sentinel precedence, `fact` replacement, repeated/reordered entries, the table limit, trailing chunks, future bytes and Unicode paths. NTFS sparse inputs reach 17,179,877,476 logical bytes with large data/metadata and more than `2^32` frames. Guarded reads around 4 GiB offsets, EOF clamping, cancellation and 64 open/close cycles per file operate on original inputs. Sparse files are flushed before measuring allocation and removed after verification. Actual WASAPI lifecycle checks also cover ordinary RF64 and BW64 silence, including a nonzero BW64 dummy.

Independent FFmpeg comparisons use original containers where supported. FFmpeg n8.0.1's [WAV demuxer](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/wavdec.c) skips the optional size table, reads BW64's dummy as a signed RF64 count, uses `ds64` data length even when the data header is finite, and omits odd `ds64` padding. Cases outside those limits use its raw physical-PCM reader at a known data offset. The large BW64 comparator pass zeros only the ignored dummy after LAMP verifies the original nonzero value. Reports identify each reference path; they do not claim complete independent container conformance. The precision suite below also records FFmpeg's valid-bit header limitation.

## Wave64 and RIFX

Sony Wave64 (`.w64`) replaces RIFF's FourCCs with GUIDs and its sizes with 64-bit ones that count each chunk's 24-byte header, and pads chunks to 8 bytes. Standard chunk GUIDs (a FourCC followed by `F3AC-D311-8CD1-00C04F8EDB8A`) are matched by their FourCC; others are skipped, and the last chunk may end the file unpadded. Its fmt, fact and data chunks then follow the WAVE rules above, compressed tags included, except that a fact count below the data's frames trims them (FFmpeg's Wave64 muxer counts the padding as data and FFmpeg plays it).

RIFX is RIFF with every integer big-endian: chunk sizes, fmt fields (basic or extensible) and the PCM and float samples, as the RIFF specification and libsndfile define it. G.711 is byte-sized; compressed tags reject in RIFX. FFmpeg 6.1 reads RIFX sample data as little-endian and accepts only 16-byte fmt chunks, so RIFX is checked against the WAVE files it was converted from.

`python3 tests/verify-caf-wave64.py` ([report](../reports/caf-wave64-verification.json)) checks 11 Wave64 files from FFmpeg's muxer (8-32-bit PCM, float32/64, G.711, IMA and Microsoft ADPCM, mono to 5.1), exact against FFmpeg up to the fact count; a Wave64 file with an unknown chunk and an unpadded last chunk; eight RIFX files converted from FFmpeg's WAVE files (8-32-bit PCM, float32/64, G.711, mono to 5.1, extensible headers) decoding exactly as the originals; seeks; and malformed GUIDs, sizes and truncation.

## Compressed audio

These WAVE format tags (in a basic fmt chunk, or as an extensible chunk's subformat) are decoded:

| Tag | Audio |
| --- | --- |
| 6, 7 | G.711 A-law and mu-law: 8-bit codes expanded to 16 bits by ITU-T G.711's rules (tables in `src/adpcm_tables.inc`), then read as 16-bit PCM, with direct seeks; 1-8 channels |
| 0x11 | IMA ADPCM with 4-bit samples, 1-8 channels (each channel's four-byte groups interleaved, as the IMA specification lays them out), decoding as FFmpeg's `adpcm_ima_wav` does |
| 2 | Microsoft ADPCM, mono or stereo, with the standard seven predictors |
| 0x45, 0x14, 0x40, 0x64 | G.726 (ITU-T G.726 and the G.721/G.723 tags), 16–40 kbit/s: 2-, 3-, 4- or 5-bit codes (the fmt chunk's bits per sample), packed from the most significant bit, mono, decoding as FFmpeg's `adpcm_g726` does |
| 0x28f | G.722 at 64 kbit/s: one 8-bit codeword (a 6-bit low and a 2-bit high band) per two output samples, mono |
| 0x31 | [GSM 06.10](#gsm-0610) full-rate speech, Microsoft's 65-byte blocks of two 20 ms frames, mono |
| 0x50, 0x55 | MPEG audio Layers I-III: the data chunk opens as a raw [MPEG audio](mp2.md) stream |
| 0x2000 | AC-3: the data chunk opens as a raw [AC-3](ac3.md) stream |

ADPCM blocks (block_align bytes, each starting with its channels' predictor state) are packets of the shared [track layer](matroska.md#track-layer), so seeks restart at the block holding the target. A short final block decodes the whole sample groups it holds; one too short for its headers is dropped. A `fact` sample count trims the padding of the last block (FFmpeg ignores it and plays the padding). A step index above 88 or a predictor above 6 stops decoding with `decode_error` 100. IMA ADPCM with 2, 3 or 5-bit samples and Microsoft ADPCM with more than two channels reject as unsupported (101); FFmpeg decodes only one or two IMA channels and lays out Microsoft ADPCM beyond two channels its own way. Other ADPCM variants and other compressed tags reject.

G.726 and G.722 carry no block headers: the decoder's state runs on through the data, which LAMP splits as FFmpeg's demuxer does into packets of 4096 bytes (4095 for 3- and 5-bit codes, so that packets hold whole codes). Data ending inside a code decodes the whole codes before it. A seek restarts three packets (1.5–6 seconds) before the target from a reset state. The adaptive state converges on the continuous decode within them: every seek tested equals continuous decoding, though nothing in the format guarantees it. G.726 and G.722 with more than one channel, and G.726 codes outside 2–5 bits, reject as unsupported (101). The decoders (`src/g72x.s`) follow FFmpeg's `g726.c` and `g722.c`, including G.726's 11-bit floating-point products; their tables are G.726's and G.722's quantizer, scale and filter tables as FFmpeg lists them.

### GSM 06.10

GSM 06.10 full-rate speech (RPE-LTP, 13 kbit/s at 8 kHz) decodes in WAVE (tag 0x31), in AIFF-C (`GSM `), in [QuickTime MOV](mp4.md) (`agsm`) and in raw `.gsm` files with a handwritten decoder (`src/gsm.s`). The decoder works in 16-bit fixed point, bit-exact with libgsm, the reference implementation from TU Berlin. It implements RPE decoding (APCM inverse quantization and grid positioning), long-term synthesis, decoding and interpolation of the log-area ratios, the short-term synthesis lattice, and de-emphasis. Each 20 ms frame of 160 samples holds 260 bits:

- eight log-area ratios;
- then, for each 5 ms subframe, the long-term lag and gain, the grid position, the block maximum and 13 pulses.

Raw and AIFF-C frames are 33 bytes: a 0xD nibble, then the bits from the most significant. Microsoft's WAVE blocks pack two frames in 65 bytes from the least significant bit. A raw stream is recognised when it holds two or more 33-byte frames that each begin with the 0xD nibble; `--check` reports codec 19. In WAVE and AIFF-C the nibble is not checked, as FFmpeg does not check it.

The Windows player includes `.gsm` in folder discovery and the Open dialog's audio filter. Its list regression covers lower/uppercase extensions, a Unicode filename, natural ordering and dialog path joining; [the focused Wine report](../reports/player-selected-verification.json) records those checks. Folder scans continue to leave out files whose final extension is unrelated, such as `voice.gsm.txt`.

The decoder's state runs on from frame to frame. Frames go to the [track layer](matroska.md#track-layer) in packets of 20 (20 WAVE blocks), and a seek decodes three packets (1.2–2.4 seconds) from a reset state before the target. A lag outside 40–120 keeps the previous lag, as GSM 06.10 (4.3.2) and libgsm specify; FFmpeg's own decoder clips it instead. That decoder also saturates differently at extremes, so it departs from libgsm on random frames, though encoders write neither case. A cut last frame or block is dropped. Stereo GSM rejects as unsupported (101). The tables are GSM 06.10's tables 4.1–4.6, checked against libgsm 1.0.22's by `tests/check-gsm-tables.py` (see `THIRD_PARTY_NOTICES`).

`python3 tests/verify-gsm.py` ([report](../reports/gsm-verification.json)) checks:

- 15 files written by FFmpeg's libgsm encoders: speech-like, tonal, noise, silent and clipping signals in WAVE, in raw `.gsm`, and wrapped by the test in AIFF-C. Each equals both libgsm's and FFmpeg's own decodes exactly.
- 32 streams of random frames, which reach every parameter value including out-of-range lags, exact against libgsm.
- Raw and WAVE files cut inside a frame, which equal libgsm's decode of their whole frames.
- 60 seeks equal to continuous decoding.
- Stereo WAVE and AIFF-C files rejecting; a cancelled open; playback through the Linux null sink.

`python3 tests/verify-wav-codecs.py` ([report](../reports/wav-codecs-verification.json)) checks 24 files from FFmpeg's encoders (G.711 in WAVE and AIFF-C, mono to 7.1; IMA and Microsoft ADPCM at 8-96 kHz with 32- to 8192-byte blocks, including an extensible header), exact against FFmpeg (ADPCM up to the `fact` count); 30 random valid ADPCM streams from `tests/adpcm_model.py` with every Microsoft predictor, every IMA step index, negative and large deltas, edge predictors, small blocks and short final blocks, exact against the model and FFmpeg (IMA with three to eight channels against the model); MPEG Layer II/III and AC-3 copied into WAVE files, exact against LAMP's raw-stream decodes and 124.8-139.6 dB against FFmpeg's float decoders; 105 exact seeks; and 12 unsupported, malformed or invalid files.

`python3 tests/verify-telephony.py` ([report](../reports/telephony-verification.json)) checks G.726 and G.722: 14 FFmpeg-encoded files exact against FFmpeg. They are G.726 at 2–5 bits in WAVE at 8 and 16 kHz and in AU at 8 kHz (with each code size's AU encoding), and G.722 in WAVE and AU. Also checked: G.726's other WAVE tags; 32 random code streams (every code size, G.722, data ending inside a code), exact against FFmpeg; 105 exact seeks; and nine unsupported or malformed files.

## Verification and reference limits

Run `python3 tests/verify-containers.py wav-layouts`. Tests require Node.js, FFmpeg, Python and a C compiler for isolated oracle executables; runtime code remains assembly without a codec DLL or CRT.

The [recorded report](../reports/wav-layout-verification.json) checks 965 files and 14,475 byte-exact seeks. It covers every supported PCM container/valid-precision combination across all eight channel counts; basic/extensible float32/64; maximum finite values, nonfinite values, signed zero and subnormals; all speaker bits; zero/partial/excess masks; padded metadata; zero valid precision and future extension bytes; and a Unicode filename. A separate set of 144 FFmpeg-produced files spans six PCM/float encodings, every channel count and three rates. Twenty-eight malformed header/chunk/data cases fail cleanly.

FFmpeg n8.0.1's [WAVE header parser](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/riffdec.c) selects the PCM codec using valid precision. When that falls into a smaller byte-size bucket, it can misread the physical sample size. For example, 1-bit precision in a 16-bit container appears as unsigned 8-bit PCM and twice as many frames. The test report identifies those cases and compares their source channels through FFmpeg's raw physical-container reader. It retains the original WAVE input for LAMP and uses Microsoft semantics for header construction; it does not change implementation behavior to match the comparator error. Other clean samples use the original WAVE header for the independent channel comparison. Four dirty-padding files intentionally test LAMP's low-bit discard policy without claiming FFmpeg equality.

An independent numeric speaker calculation supplies expected stereo floats. Direct C checks protect output boundaries, vary capacity, verify untouched tails/EOF/closed-state refusal, exercise cancellation and repeat 64 open/close cycles per file. Existing WAV/FLAC PCM and 1,470 seek regressions pass; the shared mixer also retains the 404-file FLAC regression suite. Actual WASAPI lifecycle checks add 24-bit and float64 5.1/7.1 silence playback, pause/resume, stop/reopen, seek, paused seek and cancelled open. Performance reports from older builds retain their original hashes and do not measure these new paths.
