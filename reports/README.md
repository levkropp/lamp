# Recorded verification

Current 0.4.0-dev reports cover the assembly runtime, five-format smoke checks, WASAPI lifecycle checks, 34 Opus component/packet/Ogg suites against the RFC 8251 updated reference, modern-libopus PCM comparisons, and official Opus conformance vectors. Reference C is compiled only into test executables.

| Report | Recorded coverage |
| --- | --- |
| [opus-conformance-verification.json](opus-conformance-verification.json) | All 120 official vector/rate/channel checks: 12 vectors at 8/12/16/24/48 kHz, mono/stereo; 200,750 packets and 798,079,240 PCM/history values; zero observed reference error, exact final ranges and every output accepted by unmodified normative `opus_compare` |
| [opus-verification.json](opus-verification.json) | 51 independent modern-libopus files: tones, noise, transients, silence, three input rates, mono/stereo, 2.5–120 ms packets, CBR/VBR/constrained VBR and FEC; peak error below 0.000023 at tolerance 0.00004 |
| [opus-stream-verification.json](opus-stream-verification.json) | 18,381 packet PCM/history calls, all 32 TOC configurations/five API rates/channel layouts/four framing codes, padding, FEC/loss/DTX, malformed packets, canaries and deterministic scratch |
| [opus-ogg-verification.json](opus-ogg-verification.json) | 393 updated-reference streams, signed gain/pre-skip/end trimming, cropped origins, continued headers/audio, 4,157 bounded reads/canaries, 27 malformed streams, late failure and cancellation |
| [engine-verification.json](engine-verification.json) | WAV/FLAC/MP3/Vorbis/Opus playback, pause/resume, stop/reopen, sequential/paused seek and cancelled open |
| [seek-verification.json](seek-verification.json) | 1,470 sample-exact WAV direct and native FLAC fixed/variable seek-table/frame-search checks across 98 PCM fixtures; unknown duration, changing compression, CRC-valid payload decoys, bounded fallback and cancellation; 11 malformed indexes, six noncanonical numbers and one contradictory frame sequence rejected |
| [mp3-seek-verification.json](mp3-seek-verification.json) | 1,650 byte-exact seeks across 110 independently compared files; all MPEG rates, CBR/VBR, delay/padding, absent tags, intensity/short/mixed/CRC/Huffman vectors; 65,537-frame index compaction, allocation release, cancelled seek/open and two contradictory Xing counts |
| [vorbis-seek-verification.json](vorbis-seek-verification.json) | 1,305 byte-exact seeks across 87 independently compared files; supported rates/channels, noise/transients, residue/codebooks, continued packets/comments, positive/cropped origins and initial long-to-short prefixes; 65,537-packet adaptive index compaction, allocation release, cancelled seek/open and three contradictory timestamps rejected |
| [runtime-verification.json](runtime-verification.json) | x86-64 architecture, GUI/console subsystems, 0.4.0-dev resources, icon sizes and Windows-only runtime imports |
| [branding-smoke-verification.json](branding-smoke-verification.json) | Current five-format PCM smoke checks |

The remaining `opus-*-verification.json` files record the 34-suite decoder stages. The RFC 6716 archive and RFC 8251 patch are hash-verified before reference compilation. Updated NLSF stabilization resolves the previous invalid vectors; the full resampler FIR history is now checked without an uninitialized-tail exclusion. Component-only reports describe their own test boundaries. [Decoder documentation](../docs/opus.md) gives current interfaces, counts, tolerances and prerequisites.

[opus-modern-reference-progress.json](opus-modern-reference-progress.json) is a historical **incomplete** snapshot from before RFC 8251 updates. It records 42 tonal passes and the first noise mismatch. Hybrid folding resolves that regression; the current 51-file report above records the passing rerun. Cancellation coverage also found released COM pointers being reused; cleanup clears resource pointers and all cancelled-open checks pass.

WAV/FLAC, MP3 and Vorbis PCM reports include the current regression reruns. Fuzz/stress/benchmark reports retain their original scope and binaries. Historical executable-size fields in CPU benchmark reports refer to the earlier unbranded binary. They do not establish an advantage over mpv/VLC, or uninterrupted playback on other systems. PCM report `snr_db: null` means exact equality (infinite SNR) for those cases.

See [technical test instructions](../docs/technical.md#verification) to reproduce the checks. The published v0.3.0 download retains the earlier four-format build; these development reports describe current source.
