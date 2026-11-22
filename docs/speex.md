# Speex decoder development

Speex playback is **not implemented yet**. The source now contains the first
assembly decoder components, checked against the BSD Speex 1.2.1 reference:
bounded bit access, identification headers, canonical packet inspection,
the three spectral codebook reconstruction paths, LSP interpolation/LPC
reconstruction, bandwidth expansion, IIR synthesis, high-pass filtering,
pitch/gain reconstruction, split innovation and seeded noise.
The CLI and window still
reject Speex files; no container mapping or audio format claim is added.

The intended decoder covers narrowband, wideband and ultra-wideband, all
their submodes, mono and in-band stereo, packet grouping, VBR/VAD/DTX and
stateful recovery. It still needs frame parameter/gain orchestration,
complete frame synthesis, comb enhancement,
high-band folding and QMF, stereo reconstruction, container integration,
granule/delay trimming, exact seeking and playback lifecycle verification.
The eventual format gate is PCM and playback, not packet inspection alone.

## Source and provenance

The reference is the official release archive
[speex-1.2.1.tar.gz](https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz),
SHA-256 `4b44d4f2b38a370a2d98a78329fefc56a0cf93d1c1be70029217baae6628feea`,
matching Xiph's published
[release checksum list](https://downloads.xiph.org/releases/speex/SHA256SUMS.txt).
`tests/build-speex-reference.py` verifies this hash before extraction or use.
Its extracted C files are test-only and never linked into the player.

`src/speex_packet.s` follows the published format and bit-access contracts in
`bits.c`, `speex_header.c`, `nb_celp.c`, `sb_celp.c`, `modes.c`, `modes_wb.c`
and `speex_callbacks.c`. `src/speex_lsp.s` follows `quant_lsp.c`.
`src/speex_filters.s` follows `lsp.c`, `math_approx.h` and `filters.c`,
including David Rowe's original LPC reconstruction and Valin's modifications.
`src/speex_excitation.s` follows `ltp.c`, `cb_search.c` and the reference noise
generator in `math_approx.h`.
`tests/generate-speex-tables.py` extracts exactly 2,944 signed-byte codebook
coefficients from `lsp_tables_nb.c` and `high_lsp_tables.c`; `--check` verifies
the tracked include. The project and separate codebook-author BSD notices are
retained in `THIRD_PARTY_NOTICES` and included in source/binary packages.
`tests/generate-speex-excitation-tables.py` similarly extracts 5,728 signed
bytes for the two pitch gain books and eight innovation books, retaining
both the original Xiph-form and separate author-form notices. Both table
generators support `--check` and write identical LF output on every host.

## Assembly contracts

These functions use the shared Microsoft x64 convention and caller-owned
state. No heap, system calls or global mutable decoder state are used.

- `spx_bits_init(state, data, bytes)` initializes a 24-byte reader, at most
  1 MiB. An empty reader may have a null data pointer. Other null inputs,
  oversized buffers and pointer overflow fail; a valid state is cleared and
  marked failed on invalid initialization. Bit fields are MSB first.
- `spx_bits_read(state, width)` and `spx_bits_peek(state, width)` read 0–32
  bits. `spx_bits_advance(state, count)` advances without reading memory;
  `spx_bits_remaining(state)` returns remaining bits or -1. Truncation, invalid
  widths and position overflow set a sticky error without advancing. Peeking
  leaves position unchanged. Zero is a valid value as well as the failed-read
  return, so consumers inspect the error or preflight the available bits.
- `spx_header_parse(data, bytes, summary)` validates an 80-byte or extended
  identification header up to 64 KiB. It accepts format versions 0/1,
  bitstream version 4, modes 0/1/2, 1–2 channels, playback rates 8–192 kHz,
  frame sizes 160/320/640, VBR 0/1, at most 64 extra headers and 64 frames per
  packet. Zero frames per packet means one, as in the reference file decoder.
  Bitrate is -1 or 0–10,000,000. Version text and reserved words are not used.
  Success writes eight 32-bit fields: rate, mode, channels, frame size,
  normalized frames per packet, extra headers, VBR and signed bitrate.
- `spx_packet_scan(data, bytes, outputMode, summary)` inspects canonical
  packets, returning 1–64 frames or -1. It validates the nine narrowband
  submodes, five first higher-band submodes and null/folding ultra-wideband
  modes, with no more than two higher layers per frame. It consumes up to
  1,024 standard/user in-band controls with their declared sizes; stereo
  controls are counted. Packets begin with a narrowband frame or control,
  and end at a complete frame, canonical zero/ones alignment padding or an
  explicit terminator followed by at most seven alignment bits. A four-bit
  null higher-band layer at the exact end is valid. The eight summary fields
  are frame count, projected sample count, coded bits excluding final
  padding/terminator, control count, wideband-layer count, ultra-wideband-layer
  count, stereo-control count and zero. Output mode 0/1/2 selects the sample
  count multiplier; this scan establishes structure, not valid audio content.
- `spx_lsp_unquant(bits, output, kind, capacity)` reconstructs NB30 (kind 0),
  low-rate NB18 (1) or high-band 12-bit (2) spectral parameters, returning
  10/10/8 coefficients or zero. All source bits are preflighted. Truncation
  marks the reader failed without moving it, and failed output stays intact.
  The reference's decimal **double** scale constants and each stage's separate
  float rounding are retained; replacing them with exact powers of two changes
  decoded coefficients. This stage does not enforce LSP margins or synthesize
  PCM; those follow later in the decoder.

Header and packet summary buffers are 32 bytes and cannot overlap their input.
LSP output cannot overlap the reader or its complete source buffer. All
capacities are caller responsibilities; source bytes and fields are bounded
before access, and failed parses do not write summaries.

## LPC and stateful filter contracts

`src/speex_filters.s` provides these additional caller-owned kernels. The
floating-point contract is ordinary masked-exception SSE2 round-to-nearest
arithmetic, retaining the reference's individual float rounding and absence
of fused multiply-add. It does not change the caller's floating-point mode.

- `spx_lsp_interpolate(old, current, output, order, subframe, total, margin)`
  supports orders 8 and 10, 1–64 subframes, `subframe < total` and a finite
  margin from 0 to 0.25. Finite input values with magnitude at most 16 cover
  every supported codebook sum. The weighting, first/last endpoint clamps and
  sequential interior margin adjustments follow the reference, including the
  double-precision `pi - margin` comparison and its later float assignment.
- `spx_lsp_to_lpc(lsp, output, order, capacity)` supports orders 8 and 10 and
  finite angles between zero and float(pi). It uses Speex's published float
  polynomial cosine approximation, its double-precision reflection above
  pi/2, and the reference's paired P/Q impulse reconstruction. It needs no
  libm calls. Output capacity must hold the selected order.
- `spx_bw_lpc(input, output, order, gamma)` applies successive float powers of
  finite gamma in [0,1] to 8 or 10 finite coefficients. Interpolation, LPC
  conversion and bandwidth expansion read all input before committing output,
  so their source/output ranges may overlap. Failed calls leave output intact.
- `spx_iir_mem(input, denominator, output, samples, order, memory)` filters up
  to 640 samples with order 8 or 10 and that many persistent memory floats.
  It retains the float path's unsaturated samples and per-tap update order.
- `spx_highpass(input, output, samples, filterId, memory)` supports the five
  reference filters (IDs 0–4) and two persistent memory floats, also up to
  640 samples. IDs outside 0–4 reject, unlike the reference helper's clamp
  of positive larger IDs; codec callers use only defined IDs.

The stateful filters accept exact input/output aliasing, reject other partial
input/output overlaps, and require persistent state to be disjoint from input,
output and coefficients. Output cannot overlap coefficients. All source,
coefficient and state values must be finite; arithmetic producing nonfinite
output or state fails too. The entire block and state commit together only
after successful computation. A 2,720-byte local frame holds bounded scratch
output and history without allocating a heap buffer or skipping a Windows
stack guard page. Zero samples is a successful no-op for valid order/filter
selection and does not inspect pointers. Invalid sizes, null pointers,
arithmetic overflow, forbidden overlaps and nonfinite values fail without
changing caller output or persistent memory.

The spectral interpolator prepares each next subframe's LPC coefficients;
the narrowband reference intentionally synthesizes with the previously active
LPC before installing those new coefficients. Full decoder orchestration must
preserve that ordering. Packet/frame orchestration, comb and high-band
paths still belong to the remaining
implementation.

## Pitch and innovation contracts

`src/speex_excitation.s` uses the shared 24-byte bit reader and caller-owned
buffers. It has no mutable global decoder state, heap or operating-system
calls. Its public entry points are:

- `spx_pitch_decode(bits, request)` accepts the 80-byte request/result layout
  in `src/speex_excitation.inc`. It supports the full narrowband gain/pitch
  books (7/7 bits), low-rate books (5/7), very-low-rate fixed delay (5/0), and
  forced pitch. The request supplies the current excitation pointer, separate
  output, available negative-index history (1–512 floats), 1–80 output samples,
  start/end delays in 1–144, kind, lost-frame count, subframe offset,
  last pitch gain, forced-pitch coefficient and output capacity.
  Success returns one and writes decoded pitch, three gains, their reference
  one-tap-equivalent sum and a zero reserved word. Three-tap decoding reads
  only preceding history and leaves the excitation buffer unchanged. Forced
  pitch recursively reconstructs current excitation and commits it together
  with the separate output. A three-tap request needs at least `pitch+1`
  history floats; forced pitch needs `pitch`. The full reference bit-consumption
  order, tap accumulation order and lost-frame gain limiting are retained.
  The decoded delay must fit the declared end; unsupported metadata rejects.
- `spx_innovation_decode(bits, excitation, book, capacity)` adds one of eight
  split-vector codebooks to exactly 40 finite excitation floats, returning
  40 on success or zero. Capacity must hold 40 floats. Indices and optional
  signs are read before any output commits; addition retains the reference's
  double scale and final float rounding. The book IDs below describe every
  split innovation configuration used by the supported Speex modes.
- `spx_noise_decode(output, samples, seed, deviation)` overwrites up to 640
  samples and advances a caller-owned 32-bit seed, returning one or zero.
  It preserves the reference LCG's unsigned wrap, low-23-bit mantissa,
  centering and double `3.4642 * deviation * centered` calculation before
  each float conversion. Deviation is finite and nonnegative, including
  signed zero; output and seed must be disjoint. Zero samples succeeds without
  inspecting pointers. Nonfinite arithmetic rejects the whole block.

| Innovation book ID | Reference table | Subvector width × count | Index bits | Sign bit |
| --- | --- | --- | --- | --- |
| 0 | `exc_10_16_table` | 10 × 4 | 4 | No |
| 1 | `exc_20_32_table` | 20 × 2 | 5 | No |
| 2 | `exc_10_32_table` | 10 × 4 | 5 | No |
| 3 | `exc_5_64_table` | 5 × 8 | 6 | No |
| 4 | `exc_8_128_table` | 8 × 5 | 7 | No |
| 5 | `exc_5_256_table` | 5 × 8 | 8 | No |
| 6 | `hexc_10_32_table` | 10 × 4 | 5 | No |
| 7 | `hexc_table` | 8 × 5 | 7 | Yes |

Pitch requests, bit-reader state, the reader's complete source byte range,
excitation/history range and separate output must be pairwise disjoint.
The current excitation range must be writable for forced pitch; three-tap
decoding does not access current samples. Innovation excitation cannot overlap
the bit reader or its source. Null pointers, address overflow, insufficient
capacities, unsupported metadata, forbidden aliases and nonfinite referenced
history/additive excitation fail without committing output or results.
Bit position commits only after successful reconstruction. With otherwise
valid arguments, short coded input sets the original reader's sticky error
without advancing it. Late numeric failure also preserves the request result,
current excitation, output and seed. Scratch remains bounded: 576 bytes for
pitch, 384 for innovation and 2,640 for noise, before saved registers.

## Verification and remaining gate

After a Windows test build in `bin/speex-check`:

```powershell
python tests/verify-speex-packet.py --bin bin/speex-check
python tests/generate-speex-tables.py --check
```

On Linux the same verifier assembles just the two modules and builds its
test-only C reference automatically:

```sh
python3 tests/verify-speex-packet.py --bin build/speex-check
```

The [Linux report](../reports/speex-packet-linux-verification.json) and
[native Windows report](../reports/speex-packet-windows-verification.json)
record source and oracle hashes. Both establish:

- 262,144 differential read/peek/advance operations, including partial final
  bytes and sticky truncation, plus null/oversize/overflow argument checks.
- 883 header cases, including every 0–64 frame grouping, mono/stereo and all
  modes, every short header prefix, extended-size bounds and invalid fields.
- 792 official encoder packets at qualities 0–10 across all modes,
  mono/in-band stereo, 1/2/5/64 frames per packet and CBR/VBR/VAD+DTX policies.
  Each is inspected at all three projected output rates; frame counts and
  consumed bit positions agree with full official C decoding. All narrowband
  and first higher-band submodes are observed.
- 448 standard/user control and null-higher-layer packets, including both
  ultra-wideband modes across written and official encoder cases. Their final
  bit positions also agree with the full reference decoder.
- 581 protected input prefixes and 4,096 mutated packets. Accepted mutations
  are only structurally accepted; no PCM validity is inferred. Reference
  encoders use each platform's floating-point math, so mutation acceptance
  counts can differ between platforms.
- 352,256 spectral codebook cases and 3,514,368 bit-exact float coefficients:
  exhaustive 64³ low-rate and 64² high-band index combinations, adjacent
  narrowband index pairs and additional random five-index combinations at
  unaligned bit positions. 480 truncated bit ranges and invalid capacities,
  aliases and pointers reject without writing output.

Input ends and output ends are protected by inaccessible memory pages; leading
output canaries are checked. These are component checks, not a claim of Speex
PCM playback, seek correctness or packet-loss concealment. The changed
modules translate and assemble for ARM64 macOS; native Mac execution remains
unverified. Complete frame synthesis and file/player integration remain open.

### LPC and filter verification

After building the corresponding assembly objects, run:

```sh
python3 tests/verify-speex-filters.py --bin build/speex-check
```

Use `python` and `--bin bin/speex-check` for native Windows. The verifier
compiles the original pinned `lsp.c` and `filters.c` through two generated
test-only wrappers. Only their exported definitions are renamed; the original
source bytes stay untouched. Real codec callers reach wrappers that save
inputs, execute the reference operation and independently run the assembly
kernel, comparing every output and persistent-memory word. Internal calls
inside those two included translation units are not intercepted. The encoder,
pitch/innovation, comb, QMF and outer decoder remain the reference C code.
This establishes connected component behavior, not a complete LAMP decoder.

The [Linux filter report](../reports/speex-filter-linux-verification.json) and
[native Windows filter report](../reports/speex-filter-windows-verification.json)
record source, wrapper and executable hashes. Both pass:

- 32,768 cases each for interpolation/margins, cosine/LPC reconstruction and
  bandwidth expansion, including exact in-place operation, both orders,
  interval endpoints, pi/2 and randomized spectra.
- 19,456 IIR and 6,080 high-pass cases, with lengths from 1 through 640,
  subframe boundaries, all five high-pass filters, persistent histories,
  split-call equivalence, exact in-place processing and protected input/output
  ends. Output and state canaries stay intact.
- 128 finite-edge vectors for positive/negative zero, minimum and maximum
  subnormals and minimum normal values. Negative-zero interpolation and
  bandwidth factors retain their reference bit patterns.
- 306 invalid-input cases: null/overflow pointers, sizes, unsupported
  orders/IDs, subframe/margin bounds, nonfinite input/coefficients/history,
  forbidden overlaps and late arithmetic overflow. Failed blocks leave
  output and caller-owned history unchanged, even after earlier samples were
  computed successfully in scratch storage.
- 19,008 real reference encoder/decoder frames across all three bands,
  qualities 0–10, mono/in-band stereo and CBR/VBR/VAD+DTX. The sequence includes
  2,376 lost packets with recovery, 198 resets and enhancement toggles.
  It mirrors 354,494 interpolation calls, 358,284 LPC conversions, 271,686
  bandwidth expansions, 359,501 IIR calls and 34,358 high-pass calls, covering
  23,954,320 filter samples. The combined suite compares 51,670,804 float
  words bit for bit, including the evolving histories.

The new filter module also translates and assembles for Apple Silicon; native
Mac execution remains unverified. No file playback, seeking, container trimming
or full frame/comb/QMF implementation is established by these tests.

### Pitch, innovation and noise verification

After building the assembly objects, run:

```sh
python3 tests/verify-speex-excitation.py --bin build/speex-check
python3 tests/generate-speex-excitation-tables.py --check
```

Use `python` and `--bin bin/speex-check` on native Windows. The verifier
includes the original pinned `ltp.c` and `cb_search.c` in test-only wrappers,
renaming their four decoder entry points and mirroring real codec calls into
the assembly kernels. The surrounding packet parser, spectral reconstruction,
comb, synthesis, QMF and stereo paths in this verifier remain reference C.
This is connected excitation verification, not full LAMP Speex playback.

Both the [Linux excitation report](../reports/speex-excitation-linux-verification.json)
and [native Windows excitation report](../reports/speex-excitation-windows-verification.json)
record source, oracle and wrapper hashes and pass:

- 61,536 three-tap cases: every pitch/gain index pair for all three layouts,
  with loss-free, short-loss and long-loss gain limiting, varied subframe
  offsets and lengths 1/2/17/39/40/41/80. Guarded history starts/ends and
  output ends check negative-index access and output bounds. Output samples,
  pitch, all gains, the gain sum and unchanged source history match reference.
- 7,056 forced-pitch cases: all delays 1–144, seven coefficients including
  signed zero and clamp cases, every tested length, recursive current-history
  updates and exact final state.
- 2,448 split-innovation cases, covering every codebook index at each relevant
  subvector position, both high-band signs and zero/negative-zero/nonzero
  additive excitation. Coded-bit positions and output floats match exactly.
- 9,681,344 seeded noise samples across arbitrary seeds and deviations. One
  complete 2²³-step mantissa cycle is checked with a visited-value bitset:
  all 8,388,608 mantissas occur once, with exact output floats and final seed.
  Partial output lengths leave the unused destination tail unchanged.
- 332 malformed/invalid cases, including every short coded-bit prefix,
  capacities, delay/history bounds, ownership aliases, malformed reader
  position, nonfinite referenced history or excitation, invalid gain metadata,
  and late pitch/noise overflow. Failed calls preserve results, samples,
  history, seed and bit position; short valid-input reads set only sticky error.
- 19,008 real NB/WB/UWB reference codec frames at all qualities with
  mono/in-band stereo and CBR/VBR/VAD+DTX, including 2,376 lost frames with
  recovery and decoder resets. The wrappers compare 35,660 three-tap,
  18,612 forced-pitch, 68,208 innovation and 9,020 noise calls. All four pitch
  kinds and all eight innovation books are observed. The combined suite
  compares 20,078,855 float words bit for bit.

The module also translates and assembles for Apple Silicon; native Mac
execution remains unverified. Full frame parameter/global-gain orchestration,
comb/QMF/stereo, loss-state synthesis, containers, trimming, exact seeking and
player lifecycle checks still remain before Speex playback can be claimed.
