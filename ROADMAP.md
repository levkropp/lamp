# LAMP roadmap

**Goal:** an assembly-first media player that eventually handles everything relevant people use mpv for: common audio/video codecs and containers, subtitles, local and network playback, reliable seeking, hardware acceleration, and configurable controls.

The current deliverable is an audio prototype for Windows and Linux x86-64 and Apple Silicon macOS, sharing assembly decoders. This document describes intended work, not implemented support. No milestone has a promised date. Additions must earn their CPU, memory, dependency, maintenance, and testing cost.

## How we define coverage

Use the [stable mpv manual](https://mpv.io/manual/stable/) as a feature inventory and a recorded mpv build as one interoperability comparator. mpv's available formats depend on its build and dependencies; there is no fixed list of 30 formats that means complete parity. Codec profiles, container variants, channel layouts, subtitles, transports, and playback behavior need separate coverage entries.

The initial [compatibility matrix](docs/compatibility.md) records the v0.3.0 baseline and remaining capability areas. Expand it with reference build/version, fixtures, profiles, licensing/provenance, implementation status, and known limits. Prioritize current real-world media, then broaden legacy coverage by demonstrated demand. The eventual target includes the relevant long tail, rather than stopping at a few advertised file extensions.

"Everything relevant" includes usable playback behavior as well as formats: seeking, track selection, synchronization, rendering, subtitles, network sources, configuration, automation and diagnostics. Record platform-specific or dependency-bound exceptions explicitly, with a reason and an alternative where possible. A missing capability stays visible in the matrix until implemented or explicitly scoped out; milestone completion alone is not complete mpv coverage.

## 0 — Assembly audio foundation: present

- [x] Windows x86-64 assembly runtime and native UI.
- [x] Event-driven WASAPI, separate decode/render workers, bounded PCM queue.
- [x] WAV PCM/float, native FLAC, MP3 Layer III, single-stream Ogg/Vorbis within documented limits.
- [x] Play/pause, volume, asynchronous sequential seeking; implemented open/drop UI paths.
- [x] Reference PCM comparisons, malformed-input tests, bounded stress tests, primitive Opus oracles.
- [x] LAMP branding, embedded application icon, README and static website source.

The public repository includes build/test tooling, a Windows prerelease and a website published from `gh-pages`. Optional Actions templates live in `docs/workflows/`; enabling them requires GitHub workflow permission. Desktop UI paths have not yet been comprehensively exercised.

## 0a — Apple Silicon macOS foundation

- [x] Rhun-style build-time translation of shared decoder assembly into native ARM64, with retained source provenance.
- [x] Native ARM64 libSystem service adapters and Apple ABI bridges; Xcode command line tools build.
- [x] Core Audio float stereo output with bounded buffers, pause/resume, indexed/paused seeking, EOF and stop/reopen recovery.
- [x] AppKit shell written in assembly: Open, Finder open/drop handlers, native controls, keyboard shortcuts and fullscreen.
- [x] App bundle, Retina icon, local ad-hoc signing and ZIP packaging with notices and hashes.
- [x] Native six-format PCM/regression checks and all 35 Opus oracle suites.
- [ ] Complete manual Open/drop/focus, fullscreen and Retina/multiple-display testing.
- [ ] Asynchronous seeking, output-device selection/reconnection and Mac performance measurements.
- [ ] Developer ID signing/notarization and published macOS releases.

[Mac build and verification notes](docs/macos.md) record the native coverage and platform differences. Windows benchmark and official-vector reports retain their original platform scope. Linux/Windows x86-64 roadmap work on `claude` remains separate from this main-based Mac backend.

## 1 — Finish Opus

- [x] Reference-checked packet framing, range decoding, CELT energy stages and SILK pulse primitives.
- [x] CELT static bit allocation, pulse budgets, fine-energy split, band skipping and stereo allocation decisions.
- [x] CELT base PVQ band reconstruction, normalization, spreading and collapse masks.
- [x] CELT Haar time/frequency kernels, Hadamard layout transforms and vector renormalization.
- [x] CELT frame flags/postfilter parameters, energy integration, TF decisions and dynamic allocation, checked against the normative frame prefix.
- [x] CELT recursive/stereo split-angle decoding, gains/allocation deltas, inversion and fill masks, with exact entropy and integer-math comparisons.
- [x] CELT recursive band splits, stereo/folding, and complete normalized spectral band reconstruction, including the frame loop.
- [x] CELT inverse MDCT, denormalization, overlap, anti-collapse and postfilter/deemphasis kernels, checked against the normative reference.
- [x] Assemble the stateful CELT frame decoder and validate packet-to-PCM, including energy/postfilter history, frame/bandwidth transitions and final entropy checks.
- [x] CELT packet-loss concealment, pitch/LPC reconstruction and comfort noise, with loss/recovery state validation.
- [x] SILK side-information indices, persistent entropy state and NLSF selector/predictor unpack, connected to excitation pulses.
- [x] SILK fixed-point gain/state and pitch/LTP parameter reconstruction.
- [x] SILK predictive NLSF residuals, codebook reconstruction, Laroia weights and stabilization, with invalid-result rejection.
- [x] SILK fixed-point NLSF-to-LPC conversion, inverse prediction gain and bandwidth expansion, with exact stability/coefficient comparisons.
- [x] Stateful SILK parameter orchestration, NLSF interpolation, reset/loss handling and gain/NLSF history, with atomic failure checks.
- [x] SILK gain division/rewhitening and source-rate mono excitation/LTP/LPC synthesis, checked against normative PCM/history and connected indices/pulses.
- [x] SILK decoder resampling across all fifteen input/output-rate pairs, including delay compensation, defined history and connected core PCM.
- [x] SILK comfort-noise estimation/synthesis, rate resets and loss-state history, with exact PCM/state and connected core/resampler comparisons.
- [x] SILK voiced/unvoiced packet-loss concealment and recovery glue, with exact prediction/core history, PCM, energy and connected CNG/resampling comparisons.
- [x] SILK stereo predictor/mid-only entropy decoding and adaptive mid/side-to-left/right reconstruction, with exhaustive codebook and exact PCM/history checks.
- [x] Stateful source-rate SILK channel frames: indices/pulses/parameters/core/PLC/output history/glue/CNG, with exact full-frame reference comparisons, loss/FEC, reset/rate transitions and sticky failure handling.
- [x] SILK packet VAD/LBRR headers and normal-playback redundant-data skipping, with exact metadata/entropy/history and connected mono frame checks.
- [x] SILK stereo/channel transitions and packet/API-rate orchestration, with exact connected PCM/defined history, loss/FEC/recovery, rate changes and sticky failure checks.
- [x] Connected SILK/hybrid/CELT mode frames, bandwidth/frame transitions, mono/stereo conversion, shared entropy, transition redundancy/crossfades, FEC and loss/recovery against the full RFC decoder.
- [x] Complete normal Opus packet-to-PCM dispatch: CBR/VBR framing and padding, up to 48 frames/120 ms, DTX/FEC/loss, output bounds and defined histories.
- [x] Mapping family 0, signed header gain, pre-skip, cropped granule origins and end trimming, with reference PCM and malformed-stream checks.
- [x] Integrate single-stream Ogg/Opus with cancellation, queueing, pause and sequential seeking; verify playback, stop/reopen and paused seeking.
- [x] Apply RFC 8251 decoder updates and compare updated reference PCM, including hybrid folding, stereo resets and arithmetic bounds.
- [x] Official decoder vectors, reference PCM tolerance/state checks, and malformed/truncated stream tests across modes and frame sizes.

**Gate:** actual audio playback and validated PCM for CELT-only, SILK-only and hybrid streams. Existing packet/range/energy/pulse tests alone do not satisfy this gate.

Passed in 0.4.0-dev source: 34 updated-reference suites, 51 independent modern-libopus files and all 120 official RFC 8251 vector/rate/channel checks. Mapping family 0 playback and lifecycle checks pass; multichannel/multistream and Ogg chaining belong to milestone 2.

## 2 — Reliable daily audio use

- [ ] Indexed seeking for existing formats; quick reopen/seek without blocking the UI.
- [ ] Ogg chaining, multichannel Vorbis/Opus/FLAC and channel-layout handling.
- [ ] WASAPI device selection/reconnection; explicit resampling and mixing policy; shared/exclusive output options where useful.
- [ ] Gapless playlists, repeat, queue navigation, metadata/cover art, chapters and resume.
- [ ] Unicode paths, large files, tag boundaries, cancellation and malformed-input/resource caps throughout.
- [ ] DPI-scaled typography/controls, accessible keyboard navigation, fullscreen/compact modes, DPI and drop/open testing.
- [ ] Same-machine mpv/VLC CPU, wakeup, RAM, startup and seek comparisons, including idle and loaded-system runs.

**Gate:** repeated device/seek/track transitions without deadlocks or unintended paused playback; measured queue behavior and regression fixtures. No claim of immunity to arbitrary driver or system stalls.

Current seeking progress: sample-exact WAV direct seeks and native FLAC fixed/variable seek-table or bounded frame-search seeks pass 1,470 checks across 98 PCM fixtures, with 18 malformed-index/frame rejections and a cancellation check. FLAC without usable tables resumes within one frame in ordinary fixtures, including unknown duration and sharply varying compression; a dense false-frame fixture verifies the bounded sequential fallback. MP3 sparse frame/reservoir indexes add 1,650 byte-exact seek checks across 110 independently compared files, adaptive compaction of a 65,537-frame stream, contradictory Xing-count rejections and cancelled seek/open checks. Vorbis adds 1,305 byte-exact seeks across 87 independently compared files, continued audio/comments, positive/cropped granule origins, initial long-to-short prefixes, two index compactions in a 65,537-packet stream, three contradictory-timestamp rejections and cancelled seek/open checks. Its 64 KiB index rebuilds overlap from one preceding packet. Opus adds 6,768 sample-position and reset-reference PCM checks across 141 files, all 32 TOC configurations/four framing codes, mode/channel/DTX changes, gain/pre-skip, continued/cropped streams and a nonzero 65,537-packet compaction case. Its 64 KiB index skims packet headers to at least 80 ms before the target. Playback and paused-seek lifecycle checks cover all five formats.

Reopen/seek measurements now cover five runs with six distant silence/noise targets in ten-minute fixtures for each format. An eight-byte Ogg CRC update lowers median Vorbis reopening from 32.7 to 12.5 ms and Opus from 13.8 to 5.3 ms on the recorded machine, while preserving full CRC checks. Independent bitwise tests accept 4,096 guarded streams and reject 8,191 checksum/payload mutations. Decoder timings exclude process startup, WASAPI, UI and audible endpoint latency.

A separate [headless playback benchmark](docs/playback-benchmark.md) compares the assembly WASAPI engine with mpv 0.41.0 and VLC 3.0.24 on the same machine. Thirty player/format/load scenarios record three startup/seek runs and eight-second CPU/RAM windows during noise playback, pause and idle. Repeated pause/paused-seek/resume checks pass; LAMP reports no queue underruns or empty-endpoint refills in the measured scenarios. Background user processes remain running, and the loaded condition adds four CPU workers. Controller/IPC and clock differences limit timing comparisons. Wakeups, shipping-GUI responsiveness, device changes and other milestone features remain unfinished; the seeking/reopen and full comparison checkboxes stay open.

Multichannel progress: Opus mapping family 1 now supports 1–8 speaker channels and all valid stream/coupling/map counts, including duplicated, silent and unmapped channels. Separate mono/stereo histories feed the RFC 7845 stereo downmix; double accumulation preserves accuracy when channel values cancel. Tests pass 86 generated reference streams, 1,032 reset-reference seeks, 112 modern-libopus files and 5.1/7.1 WASAPI lifecycle checks. Native FLAC adds 1–8 channels at every 4–32-bit depth, 33-bit stereo side channels, and default/tagged speaker layouts. Its suite checks 404 generated/modern-encoder files and 6,060 exact seeks, guarded reads, cancellation and allocation release; 32-bit 5.1/7.1 WASAPI lifecycle checks pass. WAV adds 1–8 channels with shared speaker mixing, left-aligned valid PCM precision, float64 and explicit direct-out/partial-mask policy. Its suite checks 965 files and 14,475 exact seeks, including 144 modern-encoder files, all container/valid-bit combinations, nonfinite/extreme floats, Unicode paths, guarded reads and cancellation; 24-bit/float64 5.1/7.1 WASAPI lifecycle checks pass.

Vorbis now adds 1–255 native channels within the documented floor 1/mapping 0 profile. Standard layouts use shared stereo speaker weights; application-defined counts above eight output ports 0/1 while all channels are decoded and validated. The suite passes 797 files, 23,910 exact native/stereo seeks and 14 malformed/resource rejections, with independent Xiph/specification PCM, guarded/mixed reads, cancellation and allocation release. A 65,537-packet multichannel stream exercises two index compactions; 5.1/7.1 WASAPI lifecycle checks pass. [Vorbis notes](docs/vorbis.md) explain comparator limits and the bounded shared setup/channel arena. Current output remains stereo. Native surround routing remains unfinished, so the combined checkbox stays open.

Ogg chaining: files are read as sequences of links, each playing its first Vorbis, Opus or FLAC stream; multiplexed video, Speex or second audio streams are skipped. Links decode independently with their own trimming and layouts. Later links at another rate pass through a new assembly windowed-sinc resampler to the first link's rate. Seven chained/multiplexed files (up to 48 links) match their links' own decodes exactly, continuously and after 370 seeks; Opus-link seeks equal standalone seeks; 16 malformed chains and FLAC-in-Ogg mappings reject. The resampler matches a direct long-double filter evaluation within 2.2e-7, keeps passband tones at least 93.4 dB below the ideal sine and attenuates aliases by at least 92.8 dB. A chained file with a resampled link plays bit-exact through the Linux null sink. See [Ogg notes](docs/ogg.md).

## 3 — Broad audio and container coverage

Current container progress: RIFF/RF64/BW64 audio framing now uses checked 64-bit lengths, occurrence-aware `ds64` tables and validation of chunks after audio. The suite passes 538 files, 16 sparse inputs up to 17,179,877,476 logical bytes, 8,950 exact seeks and 312 malformed-input rejections. It covers large data/metadata, more than `2^32` frames, bounded table state, cancellation and guarded output. RF64/BW64 WASAPI lifecycle checks pass. ADM rendering, segmented WAV data, RIFX/WAVE64, compressed WAV and the broader containers/codecs below remain unfinished.

Matroska/WebM audio tracks now play through a new container-neutral packet track layer: Opus, Vorbis, FLAC, MPEG Layers I–III and PCM, with Xiph/EBML/fixed lacing, unknown-size elements, default-track selection and final DiscardPadding. 24 FFmpeg-muxed files match FFmpeg (exact for FLAC/PCM) and LAMP's Ogg/native decodes; 42 re-muxed lacing/size/track variants decode identically; 90 seeks are exact and Opus seeks equal Ogg Opus seeks; nine malformed files reject. See [Matroska notes](docs/matroska.md).

MPEG audio Layers I and II now share the Layer III framing, index and synthesis: MPEG-1 and MPEG-2 lower rates, every allocation table and quantizer, all stereo modes and CRC checks. 96 random valid streams and 34 FFmpeg/libtwolame encoder files match FFmpeg's float decoders at 108.7 dB SNR or better, three files pass exact seek checks and seven malformed streams reject. See [Layer I/II notes](docs/mp2.md).

FLAC in Ogg (mapping 1.0) now uses the native FLAC decoder with frame-position checks at open and exact indexed seeks; eight files from 8 to 192 kHz, 16/24-bit and 1–8 channels match FFmpeg or native FLAC exactly. Chained and multiplexed Ogg files are supported as described above.

AIFF/AIFC now adds signed 1–32-bit PCM, AIFC byte-order/fixed-container variants, float32/64 and ordered Core Audio channel layouts with stereo output. Its suite passes 1,977 files, 19 sparse inputs up to 4,294,901,832 logical bytes, 30,443 exact seeks and 303 malformed-input rejections. Sparse fixtures allocate at most 393,216 bytes. Six WASAPI lifecycle scenarios pass. Declared frames, sound offsets, block padding, empty streams and cancellation are checked; [coverage and comparator limits](docs/aiff.md) distinguish original-container and raw-PCM references. Compressed AIFC codecs, native surround, newer/spatial layouts and exact fractional-rate output remain unfinished.

| Area | Planned coverage, in approximate priority order |
| --- | --- |
| Mainstream lossy audio | AAC LC/HE-AAC, AC-3/E-AC-3, MPEG Layers I/II (implemented); then DTS families, WMA variants and other relevant legacy formats |
| Lossless and PCM | ALAC, WavPack, APE, AIFF/AIFC, RF64, FLAC-in-Ogg, broader PCM/float and FLAC depths/layouts |
| Other audio | Musepack, Speex, AMR and telephony ADPCM; further formats from the compatibility inventory as demand and feasibility justify |
| Common containers | MP4/M4A/MOV, Matroska/WebM (audio tracks implemented), MPEG TS/PS, AVI, ASF; broader Ogg stream mappings |
| Media structure | Track selection, timestamps, edit lists, duration/seeking, attachments, chapters, tags and large-file indexing |

**Gate per format:** versioned feature/profile coverage, PCM comparisons, seek/trim cases, parser bounds and fuzzing, and a provenance review. Raw support for one sample file is insufficient. Prefer handwritten assembly; any permissive assembly implementation must retain its original notices.

## 4 — Video and synchronization

- [ ] Timestamped demux queues, an audio-master clock, A/V synchronization, late-frame policy, accurate video seeking and frame stepping.
- [ ] Windows GPU presentation and hardware-decoder integration, initially through supported Windows graphics/video APIs.
- [ ] Prioritize H.264, HEVC, VP9 and AV1; then VP8, MPEG-2, MPEG-4 Part 2, MJPEG and relevant legacy codecs.
- [ ] Assembly software decoding where needed, selected by profile, hardware availability, correctness and measured total system cost.
- [ ] Aspect/rotation, scaling, deinterlacing, color-space/range handling, HDR and tone mapping; progressively add higher-quality rendering controls.
- [ ] Screenshots and image playback when the common presentation pipeline supports them.

**Gate:** reference video vectors/images and synchronized mixed-media fixtures; measured dropped frames, latency, CPU/GPU use and fallback behavior. Hardware paths must have explicit supported-profile limits. Implementing mature software video codecs is a substantial project, not a quick extension of the audio decoder.

## 5 — Subtitles and network media

- [ ] External and embedded SRT, WebVTT and MP4 text; ASS/SSA styling, font attachments and layout.
- [ ] Bitmap subtitles (PGS, VobSub and relevant DVB mappings), offsets, track selection and secondary subtitles.
- [ ] HTTP/HTTPS, redirects, range requests, buffering/cancellation and seeking; then HLS/DASH and relevant live-stream behavior.
- [ ] Proxy/auth configuration, transport error recovery, bounded caches and live latency controls.
- [ ] Playlist URL support and explicit integration strategy for site-specific extraction when useful.

**Gate:** subtitle timing/layout fixtures, network failure/retry/seek fixtures and measured cache limits. Transport and extraction support must document external dependencies and cannot silently add a heavyweight runtime.

## 6 — mpv-relevant feature breadth and continued optimization

- [ ] Configurable input bindings, configuration files, playback speed with pitch handling, A-B loops, track/chapter controls and diagnostics.
- [ ] A documented command/property interface and IPC; decide scripting and mpv command compatibility using real use cases.
- [ ] Filters/equalization and advanced GPU options where demand and measured cost justify them.
- [ ] User shaders, scaling/debanding controls, display synchronization, color management and ICC/HDR behavior, with documented GPU/platform limits.
- [ ] File/URL playlists, stdin and pipe input, image sequences and other relevant mpv input types, with bounded parsing and cancellation.
- [ ] Profiles and per-file configuration, watch-later state, screenshot/export controls and playback statistics.
- [ ] Optical/disc and specialist inputs where relevant and legally distributable; record platform/dependency limits explicitly.
- [ ] Close high-value gaps in the versioned codec/profile/container/feature matrix, including relevant legacy media.
- [ ] Compare scalar/SSE2 and optional newer x86 SIMD paths; dispatch safely and keep a baseline build.
- [ ] Additional desktop platforms, preserving the x86 assembly architecture. One GNU-syntax source tree now builds Windows (LLVM) and a static, libc-free Linux `lamp-cli` with decode checks and export, following Rhun's approach. Linux playback uses the PulseAudio native protocol (PulseAudio or PipeWire) without libpulse, and is checked bit for bit through a null sink. Direct ALSA output, the Linux desktop window and other platforms remain.

**Gate:** users can evaluate exact implemented coverage against a published mpv reference version. This is a capability target, not a promise of identical internals, every mpv option, or universal bit-for-bit output.

## Rules for every milestone

1. Keep runtime code and codecs in assembly; keep test-only C/oracle executables outside runtime links.
2. Use original work or compatible permissive references, preserve attribution, and review the actual source/data license. Do not assume an mpv/FFmpeg component has the same license as another component.
3. Publish working support and limits together. Unsupported profiles fail cleanly instead of producing invalid audio/video.
4. Use bounded parsing, memory, buffers and cancellation; add meaningful regression cases for new failure modes.
5. Measure CPU time, RAM, wakeups, latency and output accuracy on named hardware with repeatable inputs. Optimize based on those results.
