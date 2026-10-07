# E-AC-3 conventional-mantissa profile

LAMP 0.4.0-dev adds a handwritten E-AC-3 parser in `src/eac3.inc`, sharing the fixed-point mantissas, bit allocation, IMDCT, overlap, speaker mixing and track layer with [AC-3](ac3.md). This is a partial E-AC-3 profile; AHT and spectral extension remain roadmap work.

## Profile v1

- Independent and AC-3-converted substream 0, bitstream ids 11–16, 32/44.1/48 kHz, all eight channel modes with optional LFE, downmixed to stereo using LAMP's speaker weights.
- Frame lengths of 1, 2, 3 or 6 blocks (256, 512, 768 or 1,536 samples), including lengths changing within a stream. Sync frames are bounded to 4,096 bytes. Packets can hold several whole frames; the decoder checks output capacity before every frame.
- Conventional AC-3 mantissa quantizers, per-block and lookup-table exponent strategies, ordinary coupling with default or explicit band structures, implicit first coupling coordinates and leaks, phase flags, rematrixing, block switching, dither, dynamic range, frame-level SNR and FFmpeg-compatible block-0 SNR packing, separate fast gains, delta bit allocation and skip fields.
- Mixing, informational, converter, additional bitstream, transient and SPX-attenuation fields are parsed to preserve bit alignment. Mixing/program-scale metadata does not override LAMP's speaker weights, transient pre-noise processing is not applied, and additional object metadata is not rendered.
- Raw `.ec3`, `.eac3` or `.ac3` sync streams, Matroska `A_EAC3`, progressive/fragmented MP4/MOV `ec-3`, and MPEG-TS using ATSC stream type 0x87, DVB descriptor 0x7a or `EAC3` registration. Raw recognition uses content. CLI track selection works through the existing container layer.

Per-block SNR-offset updates beyond the FFmpeg-compatible block-0 packing are outside this profile. The published Annex E pseudocode describes another packing for those updates; general acceptance of that syntax is not claimed. Each frame must initialize its SNR offsets; older-frame SNR reuse is rejected. If a frame uses coupling, it must begin in block 0; late-start coupling in the block-0 packing could inherit offsets from older frames and prevent exact seeking, so it is explicitly rejected.

AHT (adaptive hybrid transform), SPX (spectral extension), enhanced coupling, dependent channel substreams, additional independent substreams, reduced sampling rates, older-frame SNR reuse, and coupling first activated after block 0 return `decode_error=101`. Unsupported tools fail when their syntax is encountered; they are not replaced by concealment. Atmos/object rendering, dependent-channel reconstruction and complete E-AC-3 conformance are not claimed.

Malformed framing, layout/rate changes, reserved frame types and insufficient output capacity fail. CRC errors conceal the entire frame; invalid block contents conceal the remaining blocks using the previous block, as in the AC-3 decoder. A truncated final raw frame is dropped. Leading ID3v2 and trailing ID3v1 tags are skipped.

## Timing and validation

Sample counts come from each sync frame's block count. The shared track layer honors MP4 edit lists and packet durations, and a seek decodes the preceding packet to rebuild the overlap. Dither-free streams seek exactly; dither after a seek has the same level but a different generator position.

`dbus-run-session -- python3 tests/verify-eac3.py` on Linux compares FFmpeg-encoded profiles and model-written streams against FFmpeg PCM, tests all channel modes, all four block counts, both exponent syntaxes (including all 32 lookup rows), defaults and optional metadata, converted frames, container copies, explicit head/tail trimming, irregular reads/seeks, direct packet capacity, unsupported/malformed inputs, CRC concealment, cancellation and Linux sink playback. `tests/eac3_model.py` reuses the independently checked AC-3 DSP model; `tests/eac3_vectors.py` writes the E-AC-3 syntax using its bit allocation. The suite's report records actual comparisons and coverage; it does not certify the unsupported tools.

After the Linux suite passes, `xvfb-run -a python3 tests/verify-eac3.py --wine-only` compares the shipping Windows CLI under Wine with Linux PCM, millisecond `--start` decodes and rejections. `tests/verify-robustness.py --only tone.ec3,written.ec3,eac3.mka,eac3.mp4,eac3.ts` mutates raw and container inputs, including random starts. The checked-in snapshots use Debian 12.15 x86-64 under QEMU TCG on ARM macOS, FFmpeg 5.1.9, Wine 8.0 and LLVM 14.0.6. The macOS cross-build also passes PE import/resource checks with LLVM 23.1.2. The completed Wine fuzz snapshot used `WINEDEBUG=err+all`. Earlier Wine invocations exited 1 without decoder statistics on two saved mutations; each input produced the expected result in five warmed Windows replays, agreeing with Linux. Those initial exits were not reproduced. Wine helpers holding inherited output pipes were observed separately, so fuzz output now goes to a temporary file while exit-code and timeout checks remain strict. Native Windows remains a separate validation target.

## Provenance

The parser is handwritten from [ATSC A/52:2018 Annex E](https://www.atsc.org/wp-content/uploads/2021/04/A52-2018.pdf). Only numeric data from Tables E2.10 (frame exponent strategies) and E2.12 (default coupling band structure) enter `src/eac3_tables.inc`. `python3 tests/generate-eac3-tables.py --check` downloads the specification, checks SHA-256 `4580b631f5ac1aafdd31034f28d5fc9c29bce72a3d3f6367e3d9746906e0ffa1`, extracts those numeric rows using `pdftotext`, and verifies the generated include. Poppler is a test-generation dependency. The PDF is cached outside version control.

FFmpeg is the external PCM/error-concealment comparator. Its runtime code is not copied or linked into LAMP. The existing AC-3 numeric tables retain their [MIT source notices](../THIRD_PARTY_NOTICES.md). No new runtime dependency is added.
