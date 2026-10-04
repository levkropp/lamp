# mpv-relevant compatibility matrix

LAMP's long-term goal is to support everything relevant that mpv supports. This inventory makes gaps visible; it is not a claim of current mpv parity.

**Baseline:** LAMP 0.3.0, Windows x86-64. The feature inventory uses the [stable mpv manual](https://mpv.io/manual/stable/), reviewed on 2026-10-03. A specific mpv executable version, build configuration and same-machine comparisons have not yet been recorded. The manual URL can change; future comparisons must record the exact reference version and available decoders, demuxers and outputs.

**Partial** means implemented within the linked limits. **In development** means components exist without end-to-end support. **Planned** means unavailable today. Milestone numbers refer to the [roadmap](../ROADMAP.md).

| Capability | LAMP 0.3.0 status | Remaining coverage | Milestone |
| --- | --- | --- | --- |
| WAV / native FLAC / MP3 / Ogg Vorbis | Partial | Broader profiles, channel layouts, Ogg chaining and indexed seeking | 2–3 |
| Opus | In development; [tested CELT controls, spectral reconstruction and synthesis kernels](opus.md) | Stateful CELT frame integration, SILK and hybrid playback, mapping, gain and trimming | 1 |
| Other audio codecs | Planned | AAC/HE-AAC, ALAC, AC-3/E-AC-3, DTS, WavPack, APE, MPEG I/II and relevant legacy formats | 3 |
| Containers and media structure | Partial | MP4/MOV, Matroska/WebM, TS/PS, AVI/ASF; timestamps, attachments, chapters, editions and tags | 3 |
| Audio output | Partial | WASAPI device selection/recovery, multichannel, resampling, exclusive mode and useful passthrough | 2–3 |
| Seeking and playback state | Partial | Indexed/exact seek, resume, A-B loops, repeat, gapless playlists and speed/pitch controls | 2, 6 |
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
| Desktop platform coverage | Windows x86-64 only | Evaluate additional platforms after the Windows backend stabilizes; record platform exceptions | 6 |

Existing support is documented in [technical details](technical.md). Small committed fixtures exercise WAV, FLAC, MP3 and Vorbis decoding, export and unsupported Opus rejection; broader historical results live in [reports](../reports/README.md). These checks establish the documented prototype baseline, not complete conformance or a performance advantage over mpv.

## Acceptance and updates

Before promoting a capability to supported, record its exact codec profiles/container variants or option behavior, supported platform, reference version, redistributable fixtures, comparison tolerances, regression/fuzz coverage and known limits. Audio needs PCM checks; video needs image/timestamp checks; subtitles need timing/layout checks; transports need failure, cancellation and seek tests.

Track CPU, memory, wakeups, startup/seek latency, dropped frames and underruns on named hardware with repeatable inputs. Preserve license/provenance information for source and data. Expand rows into individual features as work starts, and update this matrix, the README and website together when support changes. Keep relevant gaps explicit until implemented or scoped out with a documented reason.
