# LAMP roadmap

**Goal:** an assembly-first media player that eventually handles everything relevant people use mpv for: common audio/video codecs and containers, subtitles, local and network playback, reliable seeking, hardware acceleration, and configurable controls.

The current deliverable is a Windows x86-64 audio prototype. This document describes intended work, not implemented support. No milestone has a promised date. Additions must earn their CPU, memory, dependency, maintenance, and testing cost.

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

## 1 — Finish Opus

- [x] Reference-checked packet framing, range decoding, CELT energy stages and SILK pulse primitives.
- [x] CELT static bit allocation, pulse budgets, fine-energy split, band skipping and stereo allocation decisions.
- [x] CELT base PVQ band reconstruction, normalization, spreading and collapse masks.
- [x] CELT Haar time/frequency kernels, Hadamard layout transforms and vector renormalization.
- [x] CELT frame flags/postfilter parameters, energy integration, TF decisions and dynamic allocation, checked against the normative frame prefix.
- [x] CELT recursive/stereo split-angle decoding, gains/allocation deltas, inversion and fill masks, with exact entropy and integer-math comparisons.
- [x] CELT recursive band splits, stereo/folding, and complete normalized spectral band reconstruction, including the frame loop.
- [ ] CELT inverse MDCT, denormalization, overlap, anti-collapse and postfilters.
- [ ] SILK parameter decoding, NLSF/LPC/prediction, synthesis and resampling.
- [ ] Hybrid modes, bandwidth/frame transitions, stereo, channel mapping, output gain, pre-skip and end trimming.
- [ ] Integrate Ogg/Opus with cancellation, queueing, pause and seeking.
- [ ] Official decoder vectors, reference PCM tolerance/state checks, and malformed/truncated stream tests across modes and frame sizes.

**Gate:** actual audio playback and validated PCM for CELT-only, SILK-only and hybrid streams. Existing packet/range/energy/pulse tests alone do not satisfy this gate.

## 2 — Reliable daily audio use

- [ ] Indexed seeking for existing formats; quick reopen/seek without blocking the UI.
- [ ] Ogg chaining, multichannel Vorbis/Opus/FLAC and channel-layout handling.
- [ ] WASAPI device selection/reconnection; explicit resampling and mixing policy; shared/exclusive output options where useful.
- [ ] Gapless playlists, repeat, queue navigation, metadata/cover art, chapters and resume.
- [ ] Unicode paths, large files, tag boundaries, cancellation and malformed-input/resource caps throughout.
- [ ] DPI-scaled typography/controls, accessible keyboard navigation, fullscreen/compact modes, DPI and drop/open testing.
- [ ] Same-machine mpv/VLC CPU, wakeup, RAM, startup and seek comparisons, including idle and loaded-system runs.

**Gate:** repeated device/seek/track transitions without deadlocks or unintended paused playback; measured queue behavior and regression fixtures. No claim of immunity to arbitrary driver or system stalls.

## 3 — Broad audio and container coverage

| Area | Planned coverage, in approximate priority order |
| --- | --- |
| Mainstream lossy audio | AAC LC/HE-AAC, AC-3/E-AC-3, MPEG Layers I/II; then DTS families, WMA variants and other relevant legacy formats |
| Lossless and PCM | ALAC, WavPack, APE, AIFF/AIFC, RF64, FLAC-in-Ogg, broader PCM/float and FLAC depths/layouts |
| Other audio | Musepack, Speex, AMR and telephony ADPCM; further formats from the compatibility inventory as demand and feasibility justify |
| Common containers | MP4/M4A/MOV, Matroska/WebM, MPEG TS/PS, AVI, ASF; broader Ogg stream mappings |
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
- [ ] Consider additional desktop platforms after the Windows backend is stable, while preserving the x86 assembly architecture.

**Gate:** users can evaluate exact implemented coverage against a published mpv reference version. This is a capability target, not a promise of identical internals, every mpv option, or universal bit-for-bit output.

## Rules for every milestone

1. Keep runtime code and codecs in assembly; keep test-only C/oracle executables outside runtime links.
2. Use original work or compatible permissive references, preserve attribution, and review the actual source/data license. Do not assume an mpv/FFmpeg component has the same license as another component.
3. Publish working support and limits together. Unsupported profiles fail cleanly instead of producing invalid audio/video.
4. Use bounded parsing, memory, buffers and cancellation; add meaningful regression cases for new failure modes.
5. Measure CPU time, RAM, wakeups, latency and output accuracy on named hardware with repeatable inputs. Optimize based on those results.
