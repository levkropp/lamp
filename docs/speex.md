# Speex decoder development

Speex playback is **not implemented yet**. The source now contains assembly
decoder components and mono/stereo frame paths for all three bands, checked against the BSD
Speex 1.2.1 reference:
bounded bit access, identification headers, canonical packet inspection,
the three spectral codebook reconstruction paths, LSP interpolation/LPC
reconstruction, bandwidth expansion, IIR synthesis, high-pass filtering,
pitch/gain reconstruction, split innovation and seeded noise, plus connected
mono/stereo narrowband/wideband/ultra-wideband frame decoding, comb enhancement,
high-band folding/innovation and QMF synthesis, DTX, packet-loss concealment
and recovery.
The CLI and window still
reject Speex files; no container mapping or audio format claim is added.

The intended decoder covers narrowband, wideband and ultra-wideband, all
their submodes, mono and in-band stereo, packet grouping, VBR/VAD/DTX and
stateful recovery. It still needs container integration,
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
`src/speex_nb.s` and `speex_nb_math.inc` connect those components following
`nb_celp.c`, `modes.c` and `filters.c`. The mathematical gain lookup generator
stores separately rounded float global/voicing gains without a runtime libm
dependency. The recovery exponential uses a bounded double Taylor series
and squaring before its final float conversion; complete decoded PCM and
history are compared with the reference's libm path.
`src/speex_decoder.s` connects the NB, WB and UWB layers following `sb_celp.c`
and `modes_wb.c`; `src/speex_qmf.s` follows the synthesis operation in
`filters.c`. `tests/generate-speex-high-tables.py` verifies the release hash
before extracting 64 float QMF coefficients and 16 high-band gain entries.
It also generates the 32 mathematical folding-gain lookups. Every generated
float is stored with an explicit bit pattern and LF line endings.
`src/speex_stereo.s` follows the intensity-stereo control and float smoothing
path in `stereo.c`, retaining Jean-Marc Valin's 2002 BSD attribution. Its
64 mathematical float balance values are generated from `exp(+/- .25*q)`
by `tests/generate-speex-stereo-tables.py`, with every control byte compared
against the original callback.
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
preserve that ordering. The connected frame decoders now do so in every band.

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
unverified. Those packet/spectral tests alone do not establish frame synthesis
or file/player integration.

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
execution remains unverified. These component tests alone do not establish
frame or file playback; the separate connected narrowband tests follow.

## Connected narrowband frame decoder

`spx_nb_init(arena, bytes)` initializes or completely resets an 8,192-byte
caller-owned arena. Capacity below 8,192, null pointers and address overflow
fail before writes. The first 2,912 bytes are defined live history; the rest
holds a complete shadow state and bounded working buffers. The layout is
private and callers must retain it unchanged between decoder calls.

`spx_nb_set_flags(arena, flags)` selects comb enhancement (bit 0), output
high-pass filtering (bit 1), and embedded-wideband high-pass coefficients
(bit 2). The default is 3. The embedded flag does not implement wideband
audio. Flags outside 0–7 and uninitialized state reject. As in Speex, the
lost-frame path always uses the narrowband output high-pass filter.

`spx_nb_frame(arena, bits, output, capacity)` returns 160 samples, zero for
a clean packet end, or -1 for malformed/unsupported input or damaged state.
Capacity counts floats. Samples retain Speex's signed-16-bit amplitude units;
this API does not normalize them to [-1,1]. A null bit reader synthesizes DTX
comfort noise when DTX is enabled, otherwise one lost frame. Coded modes
0–8 include low-rate vocoder synthesis, both subframe-gain layouts, double
innovation, pitch selection, comb enhancement, the one-subframe LPC delay,
activity levels, gain-ring history and recovery memory/excitation scaling.

The reader, its whole source buffer, output and arena must be pairwise
disjoint. Inputs are bounded before access. A failed frame preserves all
live history, output and the original reader position; truncation only sets
the reader's sticky error. Shadow/work bytes may change on failure. A clean
end may consume framing controls and record the last stereo control byte,
without producing audio. Stereo reconstruction is pending. At most two
higher-band layers and 1,024 in-band controls are skipped while searching for
a narrowband frame; four-bit null upper layers are handled explicitly.

Numeric history must remain finite, stored old LSP magnitudes may not exceed
16, and structural fields are checked. The loss counter is bounded at
1,000,000,000 before a call, keeping the reference's random-pitch float-to-int
conversion within signed range. Initialization restores all history and seeds.
This is a mono frame API; the player still rejects Speex files.

### Connected frame verification

After building the assembly objects, run:

```sh
python3 tests/verify-speex-nb.py --bin build/speex-check
python3 tests/generate-speex-nb-tables.py --check
```

Use `python` and `--bin bin/speex-check` on native Windows. Unlike the earlier
component verifiers, this links the unchanged official decoder beside the
assembly frame decoder and compares their actual output and independent
histories. The full narrowband assembly path executes all its own kernels.
It compares first/mode/loss/DTX flags, seed, pitch and gain histories, vocoder
memory, LSP/LPC/filter state, all 500 excitation-buffer samples, innovation
and all 160 output PCM samples. The reference encoder is test-only too.

The [Linux frame report](../reports/speex-nb-linux-verification.json) and
[native Windows frame report](../reports/speex-nb-windows-verification.json)
record source and executable hashes. Coverage includes all qualities 0–10,
all nine modes, all eight enhancement/high-pass flag combinations,
CBR/VBR/VAD+DTX, mono and stereo-control packets, grouping 1/2/5/64 frames,
silence, tones, noise, loss bursts up to 16 frames and recovery. All 32 global
gain codes and 16 voicing codes are independently swept. Every truncated bit
prefix of each coded mode is tested at protected memory boundaries, along
with late overflow, aliases, corrupt history, invalid modes and controls.

Each platform passes 69,413,735 checks, comparing 66,271,746 float words
exactly across 76,438 frames. These include 11,774 DTX null frames, 11,896
lost frames, 1,448 recoveries, 4,096 explicit gain/voicing sweeps and 288
standard/user-control and upper-layer compatibility cases. The sequence
contains 17,920 grouped packets; all nine narrowband modes are observed.
Another 3,597 rejected/no-frame cases verify the failure and capacity rules.

ARM64 macOS translation and assembly pass; native execution is unverified.
The three-band API below now connects the higher layers and stereo synthesis.
Container mapping, granule/delay trimming, seeking and actual player lifecycle
checks remain necessary before advertising Speex file playback.

## Wideband and ultra-wideband frame synthesis

`spx_decoder_init(arena, bytes, mode)` initializes or fully resets a 65,536-byte
opaque caller-owned decoder. Mode 0/1/2 chooses narrowband/wideband/
ultra-wideband output and returns 160/320/640 samples per frame, or zero on
invalid initialization. The first 16,384 bytes hold live decoder data;
the rest is a complete shadow and bounded scratch. No heap, system calls,
mutable globals, reference C or runtime libm are used. Frames retain the
reference's signed-16-bit amplitude units; file normalization comes later.

`spx_decoder_set_flags(arena, flags)` accepts 0–3: comb enhancement (bit 0)
and high-pass output filtering (bit 1), default 3. Embedded-wideband high-pass
coefficients are selected automatically for modes 1 and 2. Flags can change
between frames without resetting history.

`spx_decoder_set_channels(arena, channels)` selects one or two output channels,
default one, preserving stereo smoothing across changes. It rejects other
counts and uninitialized state. Stereo controls update balance even while
mono output is selected; smoothing advances only when stereo is rendered.

`spx_decoder_frame(arena, bits, output, capacity)` returns 160/320/640 frames
per channel, zero at a clean packet end, or -1 on failure. Capacity counts
floats and must hold `frames * channels`; stereo output is interleaved.
A null reader means one lost or DTX frame. The opaque arena,
output, reader and its complete source must be disjoint. Failed frames leave
all live decoder data, audio output and the original reader position intact,
including when the narrowband frame succeeds and a higher layer is truncated.
Short input sets only the original reader's sticky error. Scratch may change.
Clean packet ends may consume controls without producing audio. The caller
still needs packet grouping and stream metadata; this is not a file reader.

All five WB modes and both UWB modes are implemented. Active layers decode
their 12-bit spectra, interpolate with the high-band margin, compute low/high
filter response ratios, reconstruct folded or split-codebook excitation and
gain, and synthesize using the previous subframe's excitation and LPCs.
WB's double-innovation mode and UWB's sparse WB-innovation folding are
included. Per-layer RMS, energy, seed, spectra, filter memory and synthesis
history persist. Missing higher layers synthesize their null mode; coded
DTX and lost packets follow the reference's distinct energy/filter behavior.
Input bands may change while retaining the chosen output band.

Every layer checks new numeric history before it commits, including final
subframe excitation and energy that will not reach audio synthesis until the
next call. Nonfinite old/new data, invalid modes and structural state reject.
Old stored LSP magnitudes are limited to 16 as in the component contracts.

### QMF contract

`spx_qmf_init(arena, bytes)` initializes a 6,144-byte synthesis arena;
`spx_qmf_synth(arena, low, high, output, samples, capacity)` returns 1/0.
Samples must be 4–640 and divisible by four. Each input contains half that
many floats. The fixed 64-tap filter preserves the reference's tap order,
separate float operations, factor-of-two output normalization and odd-slot
history updates. The first 512 bytes are live low/high histories, with even
slots retained unchanged. All input/history values and computed output must
be finite. Input/output ranges may overlap freely because both complete
inputs are copied to scratch before output commits. The full arena must be
disjoint from them. On failure, output and live history are unchanged.

### Three-band verification

After building the matching assembly objects, run:

```sh
python3 tests/verify-speex-wideband.py --bin build/speex-check
python3 tests/generate-speex-high-tables.py --check
```

Use `python` and `--bin bin/speex-check` on native Windows. The
[Linux three-band report](../reports/speex-wideband-linux-verification.json)
and [native Windows report](../reports/speex-wideband-windows-verification.json)
compare independent complete decoders, with unchanged Speex 1.2.1 compiled
only into the test executable. Each platform passes 170,909,073 checks,
including 161,024,095 bit-exact float comparisons:

- 104,141 complete frames over all qualities, bands, submodes and four filter
  flag combinations, with CBR/VBR/VAD+DTX, stereo-control packets, silence,
  tones/noise and 1/2/5/64-frame grouping across 27,280 encoder packets.
- 17,944 lost frames, 5,685 DTX frames and 2,180 recoveries, with loss bursts
  through 16 frames. PCM and every reference-owned NB and SB numeric history
  are checked, including all excitation buffers, LPC/filter/energy/RMS data,
  both complete QMF histories and outer saved innovation.
- 640 explicit folding/codebook gain cases and 6,912 compatibility frames
  changing source bands and filter flags while keeping decoder histories,
  including skipped higher layers between grouped lower-band output frames.
- 6,400 QMF cases covering every permitted length, sequential histories,
  arbitrary nonzero even/odd history slots, exact in-place and partially
  overlapping source/output ranges.
- 5,205 rejected/no-frame cases: every protected bit prefix of the four WB
  coded modes and UWB folding, null/capacity/alias/overflow pointers, invalid
  modes, corrupted structural or numeric history, and late synthesis overflow.
  Exact lower-layer boundaries correctly succeed with missing upper layers;
  truncated higher layers roll back the whole decoder and preserve output.

The new frame and QMF modules translate and assemble for Apple Silicon;
native Mac execution remains unverified. These tests establish mono frame
decoding. The separate stereo checks below establish stereo reconstruction;
file/container support, granule/delay trimming, seeking and player lifecycle
behavior remain pending.

## Intensity stereo reconstruction

The full frame decoder now connects in-band stereo controls to left/right
gain reconstruction and persistent smoothing in NB, WB and UWB. Its live
stereo record occupies a private 24-byte slot within the existing arena.
The complete mono/high-band decode and stereo expansion share one atomic
commit: a malformed higher layer or a late stereo failure preserves all
decoder histories, original bit position and caller audio output. Truncation
sets only sticky reader error. Control-only clean packet ends may update
balance without producing audio. Missing controls retain previous balance;
loss and DTX frames continue smoothing when stereo output is selected.

`spx_stereo_init(arena, bytes)` initializes a standalone 6,144-byte stereo
arena and returns 1/0. Its first 24 bytes contain balance, energy ratio,
left/right smoothed gains and two preserved reserved words.
`spx_stereo_control(state, byte)` updates only balance and energy ratio from
one complete 0–255 control byte, returning 1/0. This operation needs only the
24-byte live prefix. Balance uses a separately rounded mathematical float
lookup, including all 32 positive and negative logarithmic balance choices.

`spx_stereo_apply(arena, mono, output, frames, capacity)` accepts 1–640 mono
samples and capacity for twice that many floats. It returns the frame count
or zero on failure. Complete source/output overlap, including exact in-place
expansion, is supported; both spans must be disjoint from the entire arena.
The live state and interleaved output commit together. Scratch may change on
failure. Nonfinite active state, nonpositive balance/ratio, nonfinite input,
pointer/size/alias faults and nonfinite results reject. Reserved words are
preserved without interpretation.

The target gains retain the reference's double response/square-root
operations and its explicit float casts before division and multiplication.
Smoothing uses float 0.98/0.02 products and addition, visiting samples in
reverse order exactly as `speex_decode_stereo` does. No clipping or output
normalization is added here. There is no reference C or libm runtime link.

### Stereo verification

After building the corresponding objects, run:

```sh
python3 tests/verify-speex-stereo.py --bin build/speex-check
python3 tests/generate-speex-stereo-tables.py --check
```

Use `python` and `--bin bin/speex-check` on native Windows. Both the
[Linux stereo report](../reports/speex-stereo-linux-verification.json) and
[native Windows report](../reports/speex-stereo-windows-verification.json)
pass 54,716,002 checks and 19,416,100 bit-exact float comparisons:

- 1,024 control cases cover all 256 bytes at four initial smoothing states.
  The unchanged reference callback determines balance and energy ratio.
- 25,088 standalone stereo cases cover lengths 1/2/17/40/80/160/320/640,
  persistent smoothing, signed zero, minimum subnormals, large finite gains,
  exact in-place and partial overlap, plus protected source/output/state ends.
- 15,637 complete NB/WB/UWB frames across qualities 0–10, CBR/VBR/VAD+DTX,
  grouped packets, varying balance/coherence, missing and repeated controls,
  1,759 losses and 198 DTX frames. Mono/stereo transitions include 1,083 mono
  output frames while preserving callback state. Every output sample and all
  stereo state words agree with the reference decoder plus stereo callback.
- 34 invalid/rollback cases cover capacities, sizes, null/overflow pointers,
  state/output/source aliases, damaged numeric state, late sample overflow,
  invalid channels and a stereo-control-plus-truncated-high-band packet.
  A control-only terminator updates balance and leaves output untouched.

The previous 104,141-frame mono three-band suite also passes against the
updated shared decoder. Apple Silicon translation/assembly passes; native
Mac execution is unverified. Actual Speex file playback, container mapping,
delay/granule trimming, seeking and player lifecycle checks remain open.
