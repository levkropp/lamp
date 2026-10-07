# mpv-relevant compatibility matrix

LAMP's long-term goal is to support everything relevant that mpv supports. This inventory makes gaps visible; it is not a claim of current mpv parity.

**Current source:** LAMP 0.4.0-dev, Windows x86-64 and Apple Silicon macOS; published prerelease baseline 0.3.0. The feature inventory uses the [stable mpv manual](https://mpv.io/manual/stable/), reviewed on 2026-10-03. A [same-machine headless audio comparison](playback-benchmark.md) records mpv 0.41.0 and VLC 3.0.24, their build/executable identities and five audio fixtures. The complete comparator decoder/demuxer/output inventory remains unfinished. The manual URL can change; future coverage comparisons must retain exact reference versions and available capabilities.

**Partial** means implemented within the linked limits. **In development** means components exist without end-to-end support. **Planned** means unavailable today. Milestone numbers refer to the [roadmap](../ROADMAP.md).

| Capability | Current source status | Remaining coverage | Milestone |
| --- | --- | --- | --- |
| WAV / native FLAC / MP3 / Ogg Vorbis | Partial; direct, frame-search or indexed seeking; WAV 1–8 channels, valid PCM precision and float64; native FLAC 1–8 channels/4–32-bit; [Vorbis 1–255 native channels](vorbis.md); documented stereo output policies | Native surround output, broader containers and Ogg chaining | 2–3 |
| Opus | Development playback: Ogg families 0/1, SILK/hybrid/CELT, RFC 8251 updates, family 1 layouts with 1–8 speaker channels downmixed to stereo, header gain/pre-skip/end trimming; [all 120 official elementary-vector checks pass](opus.md) | Native surround output, other mapping families, Ogg chaining | 1–2 |
| Other audio codecs | Planned | AAC/HE-AAC, ALAC, AC-3/E-AC-3, DTS, WavPack, APE, MPEG I/II and relevant legacy formats | 3 |
| AIFF / AIFC | Partial; [1–32-bit PCM, byte-order/fixed-container variants, float32/64 and ordered CHAN layouts](aiff.md); direct seeking and declared-frame trimming | Compressed AIFC codecs, native surround output, newer/spatial layouts and exact fractional-rate output | 3 |
| Containers and media structure | Partial; RIFF/RF64/BW64 and FORM AIFF/AIFC audio framing, plus single-stream Ogg within documented limits | MP4/MOV, Matroska/WebM, TS/PS, AVI/ASF, WAVE64/RIFX; ADM rendering, timestamps, attachments, chapters, editions and tags | 3 |
| Audio output | Windows WASAPI; Mac Core Audio float stereo queues | Output-device selection/recovery, native multichannel, explicit resampling policy, exclusive mode and useful passthrough | 2–3 |
| Seeking and playback state | WAV and AIFF/AIFC direct; native FLAC tables/frame search; MP3 frame/reservoir index; Vorbis packet/overlap index; Opus packet index with pre-roll; PCM/reference and paused seeking verified | Broader reopen/latency measurements, resume, A-B loops, repeat, gapless playlists and speed/pitch controls | 2, 6 |
| Video decoding and A/V sync | Planned | H.264, HEVC, VP9, AV1 and relevant legacy codecs; frame stepping and accurate synchronization | 4 |
| Hardware acceleration | Planned | Supported Windows GPU profiles, measured hardware decode, explicit software fallback | 4 |
| Video rendering and color | Planned | Scaling, crop/zoom/pan/rotation, deinterlacing, HDR/tone mapping, ICC, user shaders and display sync | 4, 6 |
| Subtitles | Planned | Embedded/external text and bitmap subtitles, ASS/SSA, fonts, styling, delays and secondary tracks | 5 |
| Network and live media | Planned | HTTP(S), ranges, redirects, buffering, HLS/DASH, proxies/auth and relevant live transports | 5 |
| Playlists and other inputs | Planned | File/URL playlists, stdin/pipes, image sequences, disc and specialist sources where relevant | 2, 5–6 |
| Web media extraction | Planned | An explicit optional integration strategy, including dependency and failure behavior | 5 |
| Controls and configuration | Partial | Configurable bindings, profiles, per-file options, track/chapter selection and accessible UI | 2, 6 |
| Commands, IPC and scripting | Planned | Documented commands/properties/events, automation and a use-case-based scripting/compatibility design | 6 |
| Filters, screenshots and diagnostics | Planned | Audio/video filters, equalization, screenshots, playback stats and useful export controls | 4, 6 |
| Desktop platform coverage | Windows x86-64; [macOS 12+ ARM64 source build](macos.md) with AppKit/Core Audio and translated shared decoders | Mac manual desktop/Retina tests, asynchronous seek, device recovery and signed/notarized distribution; other platforms remain separate roadmap work | 0a, 6 |

Existing codec support is documented in [technical details](technical.md); [Mac notes](macos.md) distinguish native ARM64 verification from the earlier Windows reports. Small committed fixtures exercise WAV, AIFF, FLAC, MP3, Vorbis and Opus decoding/export; broader results live in [reports](../reports/README.md). These checks establish the documented prototype coverage, not complete conformance or a performance advantage over mpv.

## Acceptance and updates

Before promoting a capability to supported, record its exact codec profiles/container variants or option behavior, supported platform, reference version, redistributable fixtures, comparison tolerances, regression/fuzz coverage and known limits. Audio needs PCM checks; video needs image/timestamp checks; subtitles need timing/layout checks; transports need failure, cancellation and seek tests.

Track CPU, memory, wakeups, startup/seek latency, dropped frames and underruns on named hardware with repeatable inputs. Preserve license/provenance information for source and data. Expand rows into individual features as work starts, and update this matrix, the README and website together when support changes. Keep relevant gaps explicit until implemented or scoped out with a documented reason.
