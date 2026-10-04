# Opus implementation progress

LAMP's Opus work is handwritten MASM x86-64 assembly, based on the BSD normative RFC 6716 reference. The code remains **development-only**: the player still rejects Opus and none of these objects is linked into the playback executables.

## Implemented stages

| Stage | Assembly | Current validation |
| --- | --- | --- |
| Ogg Opus headers/packet framing | `opus_packet.asm` | 1,216,672 framing comparisons |
| Range/raw-bit decoder | `opus_range.asm` | 524,288 operations with exact entropy state |
| Signed-pulse enumeration | `opus_cwrs.asm` | 90,678 comparisons |
| CELT coarse/fine/final energy | `opus_energy.asm` | 131,072 Laplace and 12,288 energy-stage comparisons |
| SILK shell/excitation pulses | `opus_silk_pulses.asm` | 69,632 shell and 24,576 excitation comparisons |
| CELT static band allocation | `opus_allocation.asm` | 271,160 allocation/entropy and 52,479 pulse-cache comparisons |
| CELT normalized PVQ bands/spreading | `opus_vq.asm` | 13,416 band/entropy, 15,864 spreading and 8,192 renormalization comparisons |
| CELT Haar/Hadamard layout helpers | `opus_band_transform.asm` | 3,280 Haar and 5,888 layout/inverse comparisons |
| CELT frame-prefix controls and dynamic allocation | `opus_controls.asm` | 48,909 frame-prefix/entropy comparisons (including 13 real frames), 48,896 standalone TF comparisons and 33 invalid-request guards |
| CELT recursive/stereo split angles | `opus_theta.asm` | 157,936 split-angle/entropy comparisons, 16,384 cosine, 131,072 log-tangent, 262,144 integer-square-root checks and 26 invalid-request guards |
| CELT recursive bands and full spectral frame loop | `opus_band.asm`, `opus_bands.asm` | 75,104 individual bands and 24,589 spectral frames; 8,205 connected prefixes including 13 real frames; 31,254,098 coefficients and 80 invalid-request guards |
| CELT anti-collapse and energy denormalization | `opus_spectral.asm` | 21,632 anti-collapse and 21,632 denormalization frames; 1,310,721 exponent checks (maximum one ULP); 29,763,849 coefficient checks and 57 guards |
| CELT inverse FFT/MDCT and overlap synthesis | `opus_fft.asm`, `opus_mdct.asm` | 12,288 FFTs, 12,288 MDCT/TDAC transforms, 16,384 long/transient overlap frames; 26,645,400 coefficients and 49 guards |
| CELT postfilter and deemphasis/output rates | `opus_filter.asm` | 29,792 comb filters, 24,576 stateful deemphasis/downsample frames; 21,242,014 coefficients and 51 guards |
| Stateful CELT frame-to-PCM | `opus_decoder.asm` | 26,326 decoded frames, 98,382,620 PCM/history coefficients, 311 strict entropy rejections with sticky failure/reset and 53 guards; zero observed error |

The new suites also cover 83 invalid-request cases, output canaries, entropy non-consumption on rejected requests, unit-energy checks and inverse layout recovery. Allocation/cache/entropy and Haar/layout/renormalization comparisons are exact. The tested PVQ/spreading outputs also had zero observed error; their allowed absolute tolerance is 0.000003 for differences between platform math implementations. These numbers concern component outputs, not complete decoded audio.

## Allocation interface

`op_celt_allocate(request*)` returns the number of coded bands, or -1 for invalid parameters. `src/opus_celt_layout.inc` defines the 88-byte request:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | pointer | 64-byte range decoder context |
| 8, 16 | pointer | Input offsets and caps, 21 int32 entries each |
| 24, 32, 40 | pointer | Output shape-bit budgets, fine-energy bit counts and fine priorities, 21 int32 entries each |
| 48, 52 | int32 | Start/end band, 0 ≤ start < end ≤ 21 |
| 56, 60, 64, 68 | int32 | Channels 1/2, LM 0–3, allocation trim 0–10, total budget in eighth-bits |
| 72, 76, 80, 84 | int32 | Output intensity, dual stereo, balance and coded-band count |

The mode is the normative 48 kHz/120-sample short-MDCT mode. Negative total budgets clamp to zero; budgets above 81,600 eighth-bits are rejected. Input offsets are 0–32,768 and caps 0–65,536. Buffers are caller-owned, correctly sized, and nonoverlapping with writable outputs. Scalars and active-band input values are checked before outputs or entropy state change.

`op_celt_init_caps(cap*, channels, LM)` builds all 21 caps. `op_celt_bits2pulses(band, LM, bits)` maps a 0-81,600 eighth-bit budget to a pseudo pulse index; `op_celt_pulses2bits(band, LM, index)` returns its cost. Both cache helpers support LM -1 through 3, reject invalid bands/missing cache entries, and return -1 on error. Pulse indices use the normative nonuniform pulse-count mapping; they are not raw K values.

The integer tables in `opus_celt_tables.inc` are extracted by `tests/generate-celt-tables.js`. `--check` verifies their contents against the SHA-1-verified normative archive, with line-ending normalization.

## PVQ and transform interfaces

`op_celt_unquant(request*)` accepts a 40-byte request: output float pointer at 0, range context pointer at 8, N/K/spread/blocks int32 fields at 16/20/24/28, gain float at 32, and output collapse mask at 36. It returns 1 on success, 0 on invalid input.

N is 2–1024, K is 1–32767 with an explicit unsigned-32-bit enumeration limit, spreading is 0–3, and blocks are 1/2/4/8/16 dividing N. Sixteen blocks cover increased time resolution during recursive reconstruction. Gain must be a nonnegative finite float from 0 to 1. It decodes integer pulses, accumulates their energy in normative order, normalizes with the gain, reverses spreading, and reports active block masks. It handles a **base PVQ vector**; the recursive caller handles splits, stereo and folding. Anti-collapse remains separate.

`op_celt_spread(X*, N, direction, blocks, K, spread)` exposes the rotation kernel; direction is -1 inverse or +1 forward. Its cosine approximation uses SSE2 doubles after reproducing the reference's float angle. It has no libm or CRT dependency.

`op_celt_renormalize(X*, N, gain)` accepts N 1–1024, rejects nonfinite accumulated energy before writes, and uses the normative epsilon. Its third argument is a float in XMM2 under the Windows x64 ABI.

`op_celt_haar(X*, N0, stride)` transforms an even N0 with total N0 × stride ≤ 1024. Its caller supplies finite normalized floats.

`op_celt_reorder(request*)` accepts a 24-byte request: X pointer at 0 and N0/stride/hadamard/inverse int32 fields at 8/12/16/20. Stride is 1/2/4/8/16, total length is at most 1024, and Hadamard ordering requires stride ≥2. Inverse 0 deinterleaves; inverse 1 interleaves. Permutations preserve raw float bits, including NaNs and signed zeros.

Pulse enumeration and layout permutations use bounded static scratch. They are single-instance producer-side routines. Allocation/rotation work uses bounded stack storage. No per-vector heap allocation occurs. Pulse-vector conversion and float scaling use packed SSE2 in groups of four; energy sums keep the normative scalar order.

## Reproduce checks

```powershell
.\build.ps1
.\tests\verify-opus-components.ps1
```

Requirements: Windows x64, Visual Studio Build Tools with the C tools and Windows SDK, Node.js and Windows tar. The C compiler builds reference **test** executables only. FFmpeg and an audio device are unnecessary for these suites.

## Next dependencies

1. Complete CELT packet-loss concealment, pitch/LPC reconstruction and comfort noise; compare loss/recovery sequences against the complete decoder.
2. Complete SILK parameters, prediction, synthesis and resampling; handle hybrid transitions.
3. Integrate Ogg Opus pre-skip/gain/end trimming with the playback engine.
4. Validate complete CELT/SILK/hybrid audio against official decoder vectors and reference PCM.

## Frame-prefix interface

`op_celt_controls(request*)` consumes the actual CELT frame prefix, from silence/postfilter/transient/intra decisions through coarse energy, time/frequency decisions, spreading, dynamic boosts, static allocation and fine energy. It returns the coded-band count, or -1 for invalid input. The remaining entropy state is ready for normalized shape decoding. For mono frames it merges the two channels' energy history as the normative decoder does. It supports the standard 48 kHz mode, LM 0–3, mono/stereo and arbitrary valid band ranges, including hybrid high-band prefixes after earlier entropy consumption.

`src/opus_controls_layout.inc` defines the 136-byte request. Eight pointers at offsets 0–56 select entropy state, 42 float energies and six 21-entry integer arrays (TF, offsets, caps, shape budgets, fine energy bits and priorities). Start/end/channels/LM occupy offsets 64–76. Outputs at 80–132 record silence/transient/intra, spreading, postfilter pitch/gain/tapset, trim, anti-collapse reservation, allocation balance/intensity/dual stereo/coded bands and the allocation budget. Reservations and budgets use eighth-bits; gain is float32. `op_celt_tf_decode` also exposes the TF stage using this request's entropy, TF, band range, LM and transient fields.

Null buffers, invalid ranges/channels/LM, nonfinite energy history and structurally invalid entropy state are rejected before writes. Buffers remain caller-owned, correctly sized and nonoverlapping. Empty/short payloads use normative entropy padding at the component level; the eventual complete decoder must apply the packet-loss policy and final entropy-error checks.

The oracle extracts the frame-prefix decisions and TF helper directly from the hash-verified RFC source, then compares all output scalars, energies, complete band arrays, canaries and the full entropy context. It covers empty/short/maximum-size payloads, zero/one/random bits, all LM/channel values, active band ranges, prior entropy consumption and the committed Ogg/Opus fixture. These are exact prefix comparisons, not complete decoded PCM.

## Split-angle interface

`op_celt_theta(request*)` decodes recursive mono or stereo split angles. It implements the normative angle-resolution budget, triangular/uniform/stereo-step probability models, intensity-stereo inversion, bit-exact cosine/log-tangent gains and allocation deltas, entropy cost and collapse-fill masks. It returns 1 on success and 0 for invalid requests, with validation before output or entropy writes. The recursive band caller applies the measured cost and time-split allocation adjustments; it then uses the gains to reconstruct both vectors.

`src/opus_theta_layout.inc` defines the 88-byte request: entropy and remaining-budget pointers at 0/8; N, bit budget, band, LM, stereo, blocks, original blocks, intensity and input fill at 16–48; angle, integer mid/side gains, allocation delta, entropy cost, inversion, output fill and angle resolution at 52–80. Budgets use eighth-bits. Valid ranges are N 2–1024, band 0–20, LM -1–3, power-of-two block counts 1–16, intensity 0–21, and a budget from -16,384 to 81,600. The remaining-budget value is read, not changed. Gains are normalized by 32,768 at the band caller.

The test extracts the angle decisions directly from the normative source, compares every output and the full entropy state, and covers all three probability models, zero/short/maximum payloads, primed entropy, intensity cutoffs and request guards. The integer helpers are checked separately, including every Q14 cosine input below 16,384 and integer-square-root boundaries throughout the uint32 range. These checks support recursive decoding work; they do not establish complete Opus PCM output.

## Recursive band and spectral-frame interfaces

`op_celt_band(request*)` now implements the complete normal-mode normalized band decoder: N=1 signs, recursive entropy-limited PVQ splits, budget rebalancing, N=2 orthogonal stereo, mid/side merging, intensity inversion, low-band folding with deterministic dither/noise, TF transforms, collapse masks and scaled folding output. It returns 1 on success or 0 on invalid input/helper failure. `src/opus_band_layout.inc` defines its 112-byte request. Pointers at offsets 0–56 select entropy, X/Y, optional lowband/output, remaining budget, seed and scratch. N/budget/band/LM/spread/blocks/intensity/TF/level/fill occupy 64–100; gain is float32 at 104 and output mask is uint32 at 108. Public calls use level zero and the normative band width at LM 0–3. Inputs remain unchanged; remaining budget, seed, entropy and output buffers advance.

`op_celt_bands(request*)` reconstructs all active bands in spectral order. It manages the shared entropy budget, rolling allocation balance, folding positions and conservative masks, dual stereo and the transition to intensity stereo. `src/opus_bands_layout.inc` defines its 144-byte request: nine pointers at 0–64; start/end/LM/short-blocks/spread/dual/intensity/total/balance/coded at 72–108; final remaining budget/balance at 112/116; X/Y/norm/scratch/mask capacities at 120–136. Budgets use eighth-bits. X and optional Y require 100 × 2^LM floats each; norm requires that many floats per channel, scratch requires 22 × 2^LM floats, and masks require 21 entries per channel. TF and pulse arrays each hold 21 int32 entries.

Buffers are caller-owned and nonoverlapping. A supplied lowband requires separate scratch and finite values with magnitude at most 32; normative folding output is bounded by sqrt(N). Capacity, parameter, active-band TF/budget and entropy structure checks precede writes. A later helper failure can leave partially decoded output, so callers must discard failed frames. Kernels still share bounded single-producer scratch; a separate instance is required before concurrent decoding is added.

The test calls the unchanged normative `quant_band` and extracts `quant_all_bands` directly from the verified archive, exposing only scratch and final-budget observations. It compares every coefficient, mask, folding buffer, complete entropy context, remaining budget, seed and allocation balance, including canaries and rejected-request non-mutation. The observed coefficient error is zero on this machine; allowed absolute tolerances are 0.00001 for vectors and 0.00004 for scaled folding output. Random payloads cover all LM/channel values, band ranges, short/long blocks, TF modes, allocation limits and primed entropy. Connected tests feed actual frame-prefix outputs into the band loop, including the committed Ogg/Opus fixture. This suite checks normalized spectral coefficients; the separate stateful frame suite below connects them to decoded PCM.

## Spectral and synthesis interfaces

`op_celt_anti_collapse(request*)` fills collapsed transient blocks with deterministic noise at the normative energy-dependent level and renormalizes affected bands. Its 88-byte layout is in `src/opus_spectral_layout.inc`: six pointers select planar coefficients, masks, current energy, two previous energy histories and pulse budgets. LM/channels/frame size/start/end/seed and four capacities follow. The standard mode uses 120 × 2^LM samples per channel and 21 bands. Histories hold 42 floats, including the second channel history used by mono merging. Seed is passed by value, as in the reference, and stays unchanged. Input coefficient magnitude is bounded by 2; finite history magnitude is bounded by 160; pulse budgets are 0–81,600 eighth-bits. Masks cover the active short blocks.

`op_celt_denormalize(request*)` converts log energies plus normative band means into gains, scales active normalized bands, and clears inactive bands, high-frequency padding and output-rate stop bands. Its 72-byte layout selects planar input/output, log energies and gains, channels/LM/start/end/downsample and four capacities. Buffers contain 120 × 2^LM floats per channel; energy/gain arrays contain 21 per channel. Downsample values 1/2/3/4/6 cover 48/24/16/12/8 kHz output. Active normalized values have magnitude at most 2; finite log energies have magnitude at most 160, with mean-adjusted log gain at most 100. This bound prevents nonfinite synthesis values on malformed streams. `op_celt_exp2(float)` uses an original degree-18 SSE2 double polynomial; the reference uses libm only in tests. An exhaustive 1/4096 grid plus random values observed at most one float ULP difference. The tested anti-collapse and denormalized coefficients matched exactly; allowed tolerances are 0.000003 absolute and 0.0000003 relative, respectively.

`op_celt_ifft(input*, output*, LM)` performs the unscaled inverse transform on 60 × 2^LM complex float pairs. Radices 2/3/4/5 follow the normative butterfly order with packed SSE2 real/imaginary lanes. Buffers are separate and contain finite values with magnitude at most 2^110. Bit-reversal, stage descriptors and twiddles are extracted from the verified static mode data.

`op_celt_imdct(request*)` implements the normative pre/post rotations, de-shuffling, mirroring and time-domain alias cancellation (TDAC). The 48-byte request in `src/opus_mdct_layout.inc` contains input/output/scratch pointers, LM, stride and scalar float capacities. S=120 × 2^LM; stride is 1/2/4/8; input capacity covers (S−1) × stride + 1 floats, output requires S+120 and scratch 2S. Output's first 120 floats contain earlier overlap. Input magnitude is at most 2^106 and existing overlap at most 2^120; these checked bounds leave space for the transform sums.

`op_celt_synthesis(request*)` handles long or interleaved transient transforms and persistent overlap for mono/stereo. Its 64-byte request contains frequency/output/overlap/scratch pointers, channels/LM/short-block flag and four capacities. Frequency/output each hold C × S floats, overlap C × 120, and scratch 3S+120. The function updates overlap for the next frame. The oracle compares against the unchanged normative inverse-synthesis helper across repeated LM and long/transient changes. All FFT, MDCT and overlap outputs observed zero error; the scale-adjusted absolute tolerance is 0.00003.

## Output-filter interfaces

`op_celt_comb_filter(request*)` implements all three postfilter tapsets, the windowed old/new period/gain transition, and the causal in-place decoder path. Its 64-byte layout in `src/opus_filter_layout.inc` contains the input buffer/output pointers, sample/history counts, periods, gains, tapsets, overlap and two capacities. Input X starts after `history` floats in the buffer; history must cover max(periods)+2 and is at most 2,048. Periods are 15–1,022, gains −1 to 1, N 1–960 and overlap 0–min(N,120). Input magnitude is at most 2^110. Output may equal X; a separate output must not overlap the buffer.

`op_celt_deemphasis(request*)` applies standard-mode deemphasis, advances per-channel filter memory through every input sample, scales by 1/32,768 and writes interleaved float PCM at the requested output rate. Its 48-byte request selects planar input/PCM/memory, N/channels/downsample and three capacities. N is 120/240/480/960, C is 1/2 and downsample is 1/2/3/4/6. PCM requires C × N/downsample floats; memory requires C. Finite inputs and memory have magnitude at most 2^120. The test covers separate and causal comb outputs, old/new periods/gains/tapsets, partial/full transitions and persistent deemphasis memory across all output rates. Observed error is zero; the scale-adjusted absolute tolerance is 0.00001.

These stages return 1 on success or 0 on rejected input/helper failure. Capacity, parameter and finite-value checks precede writes. Buffers are caller-owned with the documented overlap exceptions. Synthesis scratch is caller-owned and bounded, with no per-frame allocation. The stateful frame stage below connects these kernels; the player still rejects all Opus input.

## Stateful frame decoder

`op_celt_decoder_init(state*, byte_capacity, output_channels, output_rate)` initializes or resets an independent 18,272-byte state. Channels are 1/2; rates are 48/24/16/12/8 kHz. State contains two bounded 2,168-float decode/overlap planes, energy and postfilter histories, deterministic seed and deemphasis memory. Reserved LPC storage is for the pending loss-concealment stage.

`op_celt_decode_frame(request*)` returns samples per output channel on success, 0 for a rejected public request, or -1 for a late helper/entropy failure. A late failure sets a sticky error: discard its PCM and reset before reuse. Both final entropy overconsumption and the range decoder's error flag reject the frame. The normative decoder reports the latter as a sticky error alongside positive output; LAMP deliberately requires the caller to discard it immediately.

`src/opus_decoder_layout.inc` defines the 72-byte request. State/payload/float-PCM/optional entropy/workspace pointers occupy offsets 0–32. Payload length, stream channels, LM, start/end bands, PCM float capacity, workspace byte capacity and state byte capacity occupy 40–68. Workspace requires 44,048 bytes, PCM requires output_channels × (120 << LM) / downsample floats. Standard-mode LM 0–3 covers 2.5/5/10/20 ms. Active bands satisfy 0 ≤ start < end ≤ 21. Payloads are 2–1,275 bytes; null/zero/one-byte frames currently reject because PLC is unfinished. An optional entropy context must already reference that payload and its exact length, allowing future high-band hybrid orchestration after earlier entropy consumption.

The caller supplies correctly sized, nonoverlapping buffers and owns the state/workspace. Parameter, capacity, entropy-structure and finite-history checks happen before writes. Shared primitive scratch still restricts decoding to one producer at a time. The frame stage merges mono history, decodes controls/shapes/final energy and anti-collapse, synthesizes long/transient overlap, applies causal postfilters, updates energy/background state and outputs interleaved float PCM. Frame-size, band and stream-channel transitions preserve the normative state.

The oracle compiles the complete unchanged RFC CELT decoder/encoder only into a test executable. It compares 26,326 successful frames and 98,382,620 PCM/history values, including the 13 real fixture frames, generated tonal/noise/silent/transient frames, all channel conversions, rates, sizes and bandwidths, high-band starts and primed entropy. It also exercises 8,192 malformed/truncated cases, 311 strict entropy rejections with non-mutating sticky-state refusal and reset recovery, and 53 public guards. Observed PCM and history error is zero; the scale-adjusted absolute tolerance is 0.00004. This establishes the tested CELT frame path, not PLC, complete Opus conformance or Ogg playback.

[Normative reference](https://www.rfc-editor.org/rfc/rfc6716.html) · [Roadmap](../ROADMAP.md) · [Required notices](../THIRD_PARTY_NOTICES)
