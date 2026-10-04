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

1. Add anti-collapse, energy denormalization, inverse MDCT, overlap and postfilters.
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

The test calls the unchanged normative `quant_band` and extracts `quant_all_bands` directly from the verified archive, exposing only scratch and final-budget observations. It compares every coefficient, mask, folding buffer, complete entropy context, remaining budget, seed and allocation balance, including canaries and rejected-request non-mutation. The observed coefficient error is zero on this machine; allowed absolute tolerances are 0.00001 for vectors and 0.00004 for scaled folding output. Random payloads cover all LM/channel values, band ranges, short/long blocks, TF modes, allocation limits and primed entropy. Connected tests feed actual frame-prefix outputs into the band loop, including the committed Ogg/Opus fixture. These are normalized spectral coefficients, not PCM: anti-collapse, final-frame energy handling and synthesis still need integration.

[Normative reference](https://www.rfc-editor.org/rfc/rfc6716.html) · [Roadmap](../ROADMAP.md) · [Required notices](../THIRD_PARTY_NOTICES)
