# Speex decoder development

Speex playback is **not implemented yet**. The source now contains the first
assembly decoder components, checked against the BSD Speex 1.2.1 reference:
bounded bit access, identification headers, canonical packet inspection and
the three spectral codebook reconstruction paths. The CLI and window still
reject Speex files; no container mapping or audio format claim is added.

The intended decoder covers narrowband, wideband and ultra-wideband, all
their submodes, mono and in-band stereo, packet grouping, VBR/VAD/DTX and
stateful recovery. It still needs LPC/pitch/innovation synthesis, enhancement,
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
`tests/generate-speex-tables.py` extracts exactly 2,944 signed-byte codebook
coefficients from `lsp_tables_nb.c` and `high_lsp_tables.c`; `--check` verifies
the tracked include. The project and separate codebook-author BSD notices are
retained in `THIRD_PARTY_NOTICES` and included in source/binary packages.

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
unverified. Complete synthesis and file/player integration remain open.
