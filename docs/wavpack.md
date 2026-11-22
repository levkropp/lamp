# WavPack

LAMP 0.4.0-dev decodes WavPack 4 and 5 audio (block versions 0x402-0x410) in native `.wv` files and Matroska (`A_WAVPACK4`) with a handwritten decoder (`src/wavpack.s`, `src/wavpack_block.inc`). Native hybrid files automatically use a matching `.wvc` companion to restore lossless audio. Entropy decoding, decorrelation and output conversion follow FFmpeg's decoder; correction reconstruction follows David Bryant's BSD WavPack 5.9.0 reference, attributed in `THIRD_PARTY_NOTICES`. Frames pass through the shared [track layer](matroska.md#track-layer); each frame decodes on its own, so seeks restart exactly at the frame holding the target.

## Coverage

- Lossless and hybrid (lossy) integer audio of 8, 16, 24 and 32 bits, and 32-bit float. Hybrid blocks bisect each residual within the error limit from the bit rate accumulators, with and without the bit-rate (slow level and balance) mode; lossy 32-bit audio clips as 24-bit, as the WavPack library does.
- The adaptive Golomb-like residual code with its three medians, holding one and zero states, zero runs and escapes; every decorrelation term (1-8, the extrapolating 17 and 18, and the cross-channel -1, -2 and -3) with any delta, weights and history; joint (mid/side) stereo; false stereo (one decoded channel played in both).
- INT32INFO: extra bits (sent in their own bit stream, checked by their CRC), and shifts filling with zeros, ones or copies of the low bit; the header's shift. Float blocks with FLOATINFO: shift and maximum exponent, values beyond 24 bits, and the mantissa, exponent and sign details that the extra bit stream sends for each of its flags.
- Frames of several mono and stereo blocks carry up to eight channels, laid out by the first block's channel information (a WAVE channel mask of one to four bytes, the extended form, or no mask for the default layout of that count); blocks for channels beyond the count are ignored. Rates from the header table or a custom rate sub-block, 8-192 kHz.
- Blocks of up to 150000 samples (FFmpeg's limit). Output keeps FFmpeg's sample presentation: values in the 16-bit domain (8- and 16-bit audio) as int16 divided by 2^15, the 32-bit domain divided by 2^31, floats unchanged. Multichannel audio mixes to stereo with the shared WAVE speaker weights.

Every block's CRC is checked (FFmpeg checks them only with `-err_detect crccheck`), and so is the extra bit stream's; a failed CRC, a malformed block, a frame missing channels or a frame whose rate, channel count or sample format differs from the first stops decoding with `decode_error` 100.

DSD audio (the DSD flag or sub-block), block versions outside 0x402-0x410 (including WavPack 3 files), rates below 8 kHz and more than eight channels reject with `decode_error` 101. Matroska correction side data remains unsupported.

Mono blocks without decorrelation terms output their residuals, as libwavpack does; FFmpeg 6.1 outputs silence for them (and its CRC check then fails).

## Files

A `.wv` file is a sequence of blocks (`wvpk` headers), optionally after an ID3v2 tag. A frame runs from a block with audio to its final block; blocks without samples between frames (such as metadata blocks) are skipped. The file ends at a block header that is invalid or truncated, an APEv2 or ID3v1 tag, or the end of the data; a partial final frame is dropped. Matroska frames hold the sample count once and each block's flags, CRC and (in multi-block frames) size; the two-byte CodecPrivate version is optional.

## Native hybrid correction companions

Open the `.wv` file normally in either player. For a native hybrid stream,
LAMP appends `c` to the complete input pathname and maps that file, just as
the reference library does: `album.wv` uses `album.wvc`, and `album.WV` uses
`album.WVc` on a case-sensitive filesystem. The same rule applies to files
recognized by their contents without an extension. Windows uses UTF-16
paths; Linux and macOS use UTF-8. A missing companion retains the original
hybrid lossy decode. An ordinary lossless file ignores an unrelated companion.
An existing empty, unreadable, malformed or mismatched companion fails with
`decode_error` 100 instead of silently falling back to lossy audio.

The correction path reconstructs the residual's exact position within its
lossy interval, then applies corrected cross-channel prediction, joint stereo
and old/new noise shaping while the main adaptive histories continue to use
lossy samples. It handles legacy two-byte shaping weights, logarithmic error
and weight accumulators, per-sample deltas and correction-side extra-bit
streams. Corrected 32-bit integer samples retain their precision; block and
extra-bit CRCs verify the reconstructed samples before stereo conversion.
Float bit details and special values pass through the existing float path.

Main and companion frames share a bounded index, so seeks find both halves
of a frame and output the same PCM as sequential decoding. The index permits
at most 1,048,576 frames (24 MiB), with at most 1 MiB of payload after each
block's eight-byte signature/size prefix. The companion path buffer is 64 KiB;
paths too long to append the suffix reject as unsupported. The mapping and
index remain owned until decoder close, including during seeks, and are
released on failed open, stop and queue replacement. On Windows both mapped
files retain read-sharing handles so they cannot be replaced while in use.
This association applies only to native files; Matroska remains self-contained
and does not consume correction side data.

### Correction verification

Build the optional reference and paired-frame oracle after building LAMP:

```sh
python3 tests/build-wavpack-reference.py
python3 tests/build-wavpack-pair-oracle.py --bin build/wvc-check
python3 tests/verify-wavpack-correction.py --bin build/wvc-check
```

Use the corresponding Windows binary directory on Windows. Native Windows
`--playback` additionally requires an engine-probe build made with
`--probe-exclusive --probe-default-device`; it exercises a silent fixture
through the real WASAPI session lifecycle without changing system defaults.

The pinned official WavPack 5.9.0 source archive has SHA-256
`2a53e50aefd8c9f04a0828a0e1ef77b6f4c17b0ef6964ad234ab295f313b7d6d`.
It is compiled only for tests and is never linked into either player.
The [Linux report](../reports/wavpack-correction-linux-verification.json) and
[native Windows report](../reports/wavpack-correction-windows-verification.json)
record source, fixture and oracle hashes and establish:

- 106 official encoder fixtures: 1–8 channels, integer depths 8/12/16/20/24/32,
  mono/stereo floats and surround floats, several compression/joint-stereo
  choices, positive/negative/automatic shaping, short final blocks, zero runs,
  and floating zero, infinities, NaN payloads and subnormals. Official corrected
  decode equals the original input bits; paired assembly and automatic native
  lookup emit exactly the expected stereo PCM. A lossy control proves that
  the companion restores information absent from the main stream alone.
- Five synthetic legacy-shaping/cross-term fixtures. Prediction metadata in
  official blocks is modified, the reference supplies a proper block prefix,
  and independent sample CRCs are written into the final files. Every final
  fixture passes ordinary full reference decode and its CRC, with and without
  the companion; paired and automatic LAMP output match the corrected PCM.
- 655 invalid-bound calls across these fixtures: short buffers, null input,
  pointer overflow, insufficient output capacity and surplus correction bytes
  reject without modifying output. Input ends and output ends are protected
  by inaccessible pages, and a leading output canary is checked.
- 14 damaged/truncated paired streams and 13 filesystem cases, covering
  missing, empty, malformed, wrong, truncated, incomplete, surplus, CRC-damaged,
  oversized and directory companions, Unicode/case-sensitive path spelling,
  extensionless discovery and lossless files with unrelated companions.
- 14 exact millisecond seeks, a corrected/lossy/corrected queue and a 48-to-44.1
  kHz resampling comparison against identical verified float-WAVE input.
  Native Windows also passes silent exclusive pause/resume, stop/reopen, seek,
  cancelled-open and synthetic default-device restart tests.

The changed shared decoder and platform sources also translate and assemble
for ARM64 macOS. Native Mac correction playback has not been executed; the
older Mac WavPack report covers the earlier lossless/lossy implementation.
These checks do not establish correction support in Matroska or DSD support.

## Speed

On the test machine, a 60-second 44.1 kHz stereo 16-bit file decodes in 0.29 s (FFmpeg's fastest compression level) to 0.45 s (its highest), about 210 and 130 times real time, close to FFmpeg's command line (0.26 and 0.40 s including its start-up). A 60-second 48 kHz 5.1 file with 32-bit samples takes 0.81 s including the stereo mix (FFmpeg 0.49 s without one).

## Verification

`python3 tests/verify-wavpack.py` checks:

- 30 files from FFmpeg's encoder: 8-, 16-, 24- and 32-bit integer and float samples (its float blocks send extra bits), compression levels 0-8, joint stereo on and off, mono, false stereo, 3.0, quad, 5.1 and 7.1, 8-192 kHz including a custom 37.8 kHz rate and 96000-sample blocks. Every decode equals FFmpeg's exactly; layouts beyond stereo equal FFmpeg's channels mixed with LAMP's speaker weights in the same order of operations.
- The Python model `tests/wavpack_model.py` reproduces FFmpeg's decode of seven of them exactly, so the streams written through it carry what was intended.
- Nine Matroska copies (one-block and multi-block frames) decode exactly as their `.wv` files.
- 37 streams written by `tests/wavpack_vectors.py`, covering what FFmpeg's encoder never writes: hybrid stereo and mono with and without the bit-rate mode, lossy 24-bit, 32-bit (clipped as 24-bit) and float audio, integer extra bits at 16, 24 and 32 bits, the zero, one and duplicate shifts, float blocks with every FLOATINFO flag, shift and exponent range (including values beyond 24 bits), every term with every delta, blocks without terms, written false stereo, header shifts, quiet passages with zero runs, 3- to 8-channel frames with one- to four-byte, empty and extended channel information, a surplus block, a side-speaker pair, a custom rate, long and odd sub-block sizes with unknown sub-blocks, and every wp_exp2 input as decorrelation history. The writer drives the model with readers that choose each value: residuals are coded to follow a target signal as the medians and holding states allow, other bits are random, and the CRCs come from the model. The model, FFmpeg (with `-err_detect crccheck`) and LAMP agree exactly, except that the two zero-term mono blocks are compared with the model only (see above). A coverage set confirms every feature listed under Coverage was decoded.
- 75 exact seeks in a 20-second file, its Matroska copy, a written hybrid stream, 5.1 and 96000-sample blocks.
- Files with ID3v2 and APEv2 tags decode as the untagged file, and a file cut inside a frame as FFmpeg decodes it; DSD, versions 0x401 and 0x411, 6 kHz and nine channels reject as unsupported; garbage, metadata-only and truncated single-block files as malformed; a damaged block and a frame missing channels stop decoding with `decode_error` 100 (FFmpeg reports the damage too); a cancelled open stops cleanly.

`src/wavpack_tables.inc` holds WavPack's 8-bit fractional exponent and logarithm tables, generated from their definitions (exp2[i] = round(256 * 2^(i/256)) - 256, log2[i] = round(256 * log2(1 + i/256))) by `python3 tests/generate-wavpack-tables.py`, which checks the file with `--check`; the exp2 sweep above decodes every input through FFmpeg.
