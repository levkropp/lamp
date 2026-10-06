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

Queue progress: `lamp-cli` plays, checks and exports several files as one gapless stream through a new queue layer that both engines read: each file decodes as it would alone, later files at another rate pass through the windowed-sinc resampler to the first file's rate, and files that cannot play are skipped with a message. M3U/M3U8 and PLS playlists expand to their entries (relative paths, `file://` URIs, nesting, Latin-1 lines). 15 checks show exact concatenation across eight formats, resampled files equal to the resampler oracle, chained Ogg handling and the failure rules; a four-file queue (with a resampled file and one shorter than the prebuffer) plays through the null sink bit-exact with no gap. Repeat, track navigation, URL playlists and a Windows queue remain open. See [queue notes](docs/queue.md).

Metadata progress: a new tag reader keeps ten normalized keys (title, artist, album, album artist, date, track, disc, genre, comment, composer) from ID3v2.2–2.4 (every text encoding, unsynchronisation, extended headers, numeric genres, merged ID3v2.3 dates), ID3v1/1.1, APEv2, Vorbis comments (FLAC, Ogg Vorbis/Opus/FLAC), MP4 `ilst` and QuickTime text atoms, Matroska, RIFF INFO (WAVE, AVI), AIFF and CAF. `lamp-cli --tags` prints them, playback lists them and the Windows player titles the track. 50 checks over 240 files compare with ffprobe (20 FFmpeg-written containers, every ID3v2 variant, all 192 numeric genres) or with documented expected values where FFmpeg 6.1 reads less; 1,200 mutated tags neither crash nor hang. See [tag notes](docs/tags.md).

Chapter progress: the tag reader also keeps chapter lists, read as FFmpeg reads them: Vorbis `CHAPTERnnn` comments (FLAC, Ogg), FLAC `CUESHEET` tracks, ID3v2.3/2.4 `CHAP` frames (MP3, MP1/MP2, ADTS, WAVE and AIFF chunks), Matroska editions and MP4 `chpl` boxes and QuickTime chapter text tracks, with FFmpeg's numbering, merging and skipping rules. `lamp-cli --chapters` prints them. 40 checks compare with ffprobe (10 FFmpeg-written containers and 30 files written to exercise each rule) or with documented expected values where FFmpeg 6.1 reads differently; 1,100 mutated files neither crash nor hang. Chapter navigation during playback remains open. See [chapter notes](docs/chapters.md).

Cover art progress: the tag reader also keeps one embedded picture, the first front cover or else the first picture among those FFmpeg exposes: ID3v2 `APIC`/`PIC` frames (MPEG audio, ADTS, WAVE and AIFF chunks; unsynchronised frames included), FLAC `PICTURE` blocks and base64 `METADATA_BLOCK_PICTURE` comments (FLAC, Ogg), MP4 `covr` items, Matroska image attachments and WavPack APEv2 binary items, with FFmpeg's MIME, signature and placement rules. `lamp-cli --cover` writes it, and the Windows player decodes it through WIC and shows it above the title. 50 checks compare the bytes and type with FFmpeg's attached picture; 1,000 mutated files neither crash nor hang. See [cover notes](docs/cover.md).

Current seeking progress: sample-exact WAV direct seeks and native FLAC fixed/variable seek-table or bounded frame-search seeks pass 1,470 checks across 98 PCM fixtures, with 18 malformed-index/frame rejections and a cancellation check. FLAC without usable tables resumes within one frame in ordinary fixtures, including unknown duration and sharply varying compression; a dense false-frame fixture verifies the bounded sequential fallback. MP3 sparse frame/reservoir indexes add 1,650 byte-exact seek checks across 110 independently compared files, adaptive compaction of a 65,537-frame stream, contradictory Xing-count rejections and cancelled seek/open checks. Vorbis adds 1,305 byte-exact seeks across 87 independently compared files, continued audio/comments, positive/cropped granule origins, initial long-to-short prefixes, two index compactions in a 65,537-packet stream, three contradictory-timestamp rejections and cancelled seek/open checks. Its 64 KiB index rebuilds overlap from one preceding packet. Opus adds 6,768 sample-position and reset-reference PCM checks across 141 files, all 32 TOC configurations/four framing codes, mode/channel/DTX changes, gain/pre-skip, continued/cropped streams and a nonzero 65,537-packet compaction case. Its 64 KiB index skims packet headers to at least 80 ms before the target. Playback and paused-seek lifecycle checks cover all five formats.

Reopen/seek measurements now cover five runs with six distant silence/noise targets in ten-minute fixtures for each format. An eight-byte Ogg CRC update lowers median Vorbis reopening from 32.7 to 12.5 ms and Opus from 13.8 to 5.3 ms on the recorded machine, while preserving full CRC checks. Independent bitwise tests accept 4,096 guarded streams and reject 8,191 checksum/payload mutations. Decoder timings exclude process startup, WASAPI, UI and audible endpoint latency.

A separate [headless playback benchmark](docs/playback-benchmark.md) compares the assembly WASAPI engine with mpv 0.41.0 and VLC 3.0.24 on the same machine. Thirty player/format/load scenarios record three startup/seek runs and eight-second CPU/RAM windows during noise playback, pause and idle. Repeated pause/paused-seek/resume checks pass; LAMP reports no queue underruns or empty-endpoint refills in the measured scenarios. Background user processes remain running, and the loaded condition adds four CPU workers. Controller/IPC and clock differences limit timing comparisons. Wakeups, shipping-GUI responsiveness, device changes and other milestone features remain unfinished; the seeking/reopen and full comparison checkboxes stay open.

Multichannel progress: Opus mapping family 1 now supports 1–8 speaker channels and all valid stream/coupling/map counts, including duplicated, silent and unmapped channels. Separate mono/stereo histories feed the RFC 7845 stereo downmix; double accumulation preserves accuracy when channel values cancel. Tests pass 86 generated reference streams, 1,032 reset-reference seeks, 112 modern-libopus files and 5.1/7.1 WASAPI lifecycle checks. Native FLAC adds 1–8 channels at every 4–32-bit depth, 33-bit stereo side channels, and default/tagged speaker layouts. Its suite checks 404 generated/modern-encoder files and 6,060 exact seeks, guarded reads, cancellation and allocation release; 32-bit 5.1/7.1 WASAPI lifecycle checks pass. WAV adds 1–8 channels with shared speaker mixing, left-aligned valid PCM precision, float64 and explicit direct-out/partial-mask policy. Its suite checks 965 files and 14,475 exact seeks, including 144 modern-encoder files, all container/valid-bit combinations, nonfinite/extreme floats, Unicode paths, guarded reads and cancellation; 24-bit/float64 5.1/7.1 WASAPI lifecycle checks pass.

Vorbis now adds 1–255 native channels within the documented floor 1/mapping 0 profile. Standard layouts use shared stereo speaker weights; application-defined counts above eight output ports 0/1 while all channels are decoded and validated. The suite passes 797 files, 23,910 exact native/stereo seeks and 14 malformed/resource rejections, with independent Xiph/specification PCM, guarded/mixed reads, cancellation and allocation release. A 65,537-packet multichannel stream exercises two index compactions; 5.1/7.1 WASAPI lifecycle checks pass. [Vorbis notes](docs/vorbis.md) explain comparator limits and the bounded shared setup/channel arena. Current output remains stereo. Native surround routing remains unfinished, so the combined checkbox stays open.

Ogg chaining: files are read as sequences of links, each playing its first Vorbis, Opus or FLAC stream; multiplexed video, Speex or second audio streams are skipped. Links decode independently with their own trimming and layouts. Later links at another rate pass through a new assembly windowed-sinc resampler to the first link's rate. Seven chained/multiplexed files (up to 48 links) match their links' own decodes exactly, continuously and after 370 seeks; Opus-link seeks equal standalone seeks; 16 malformed chains and FLAC-in-Ogg mappings reject. The resampler matches a direct long-double filter evaluation within 2.2e-7, keeps passband tones at least 93.4 dB below the ideal sine and attenuates aliases by at least 92.8 dB. A chained file with a resampled link plays bit-exact through the Linux null sink. See [Ogg notes](docs/ogg.md).

## 3 — Broad audio and container coverage

Current container progress: RIFF/RF64/BW64 audio framing now uses checked 64-bit lengths, occurrence-aware `ds64` tables and validation of chunks after audio. The suite passes 538 files, 16 sparse inputs up to 17,179,877,476 logical bytes, 8,950 exact seeks and 312 malformed-input rejections. It covers large data/metadata, more than `2^32` frames, bounded table state, cancellation and guarded output. RF64/BW64 WASAPI lifecycle checks pass. ADM rendering, segmented WAV data and the broader containers/codecs below remain unfinished.

Compressed WAVE data now plays: G.711 A-law/µ-law (also in AIFF-C), IMA ADPCM (1–8 channels) and Microsoft ADPCM (mono/stereo) through a new assembly decoder and the track layer, and MPEG audio and AC-3 data chunks through the raw-stream decoders. 24 FFmpeg-encoded files match FFmpeg exactly (ADPCM up to the `fact` count, which LAMP honors), 30 random ADPCM streams covering every predictor and step index match the model and FFmpeg, MPEG/AC-3 copies equal the raw-stream decodes, 105 seeks are exact and 12 unsupported or invalid files reject. See [WAV notes](docs/wav.md#compressed-audio).

Apple Core Audio Format files now play: linear PCM in every integer size and float32/64 in either byte order and G.711 read directly with Core Audio channel layouts, and IMA4, ALAC, AAC, MPEG audio, AC-3 and Opus packets through the track layer with packet-table trimming. Sony Wave64 and big-endian RIFX share the WAVE reader, and AIFF-C gains IMA4. 39 FFmpeg-written CAF files and 11 Wave64 files match FFmpeg or equivalent files exactly, AAC CAF with priming and remainder matches its trimmed ADTS stream, eight RIFX conversions decode as their WAVE originals, seeks are exact (IMA4 within its predictor's low bits) and 17 malformed or unsupported files reject. See [CAF notes](docs/caf.md) and [Wave64/RIFX notes](docs/wav.md#wave64-and-rifx).

Sun/NeXT AU files now play directly through the PCM reader: signed 8–32-bit and float32/64 big-endian PCM and G.711, with unknown data sizes and annotation tags. 16 FFmpeg-written files match FFmpeg exactly, 5.1 matches WAVE, rewritten and truncated headers decode as the originals, seeks are exact and nine malformed headers reject. See [AU notes](docs/au.md).

Flash Video files now play their audio: PCM, G.711 and MP3 tags gathered for the WAVE reader as AVI's are, AAC frames and a new Flash ADPCM decoder (2–5-bit codes) through the track layer. 24 FFmpeg-written PCM, G.711 and Flash ADPCM files and eight random Flash ADPCM streams at every code size match FFmpeg exactly, MP3 and AAC equal their raw copies, skipped, truncated and 8 kHz MP3 files decode as expected, seeks are exact and nine malformed or unsupported files reject. See [FLV notes](docs/flv.md).

AVI files now play their first supported audio stream: the chunks, in RIFF AVI and OpenDML RIFF AVIX lists, are gathered behind a Wave64 header and decoded by the WAVE reader (PCM, float, G.711, ADPCM, MPEG audio, AC-3), and AAC frames go through the track layer. 33 FFmpeg-written files with and without video match FFmpeg exactly, MPEG/AC-3/AAC streams equal their raw copies, rewritten OpenDML, `rec`, re-cut, ADTS and truncated files decode as the originals, seeks are exact and nine malformed or unsupported files reject. See [AVI notes](docs/avi.md).

Matroska/WebM audio tracks now play through a new container-neutral packet track layer: Opus, Vorbis, FLAC, MPEG Layers I–III and PCM, with Xiph/EBML/fixed lacing, unknown-size elements, default-track selection and final DiscardPadding. 24 FFmpeg-muxed files match FFmpeg (exact for FLAC/PCM) and LAMP's Ogg/native decodes; 42 re-muxed lacing/size/track variants decode identically; 90 seeks are exact and Opus seeks equal Ogg Opus seeks; nine malformed files reject. See [Matroska notes](docs/matroska.md).

MP4/M4A/MOV audio tracks use the same track layer: Apple Lossless (a new assembly decoder), MPEG audio, Opus, FLAC and QuickTime/ISO PCM, from progressive sample tables or `moof`/`trun` fragments, with edit lists and sample durations bounding the presentation. 38 FFmpeg-muxed files, 18 of them fragmented, match FFmpeg (exact for ALAC/FLAC/PCM); fragmented files equal their progressive versions and ALAC, FLAC and Opus equal their Matroska, native FLAC and Ogg remuxes; 120 seeks are exact and Opus seeks equal Ogg Opus seeks; ten malformed files reject. See [MP4 notes](docs/mp4.md).

AAC-LC now decodes in MP4, Matroska and ADTS with a new assembly decoder: all twelve rates, mono to 7.1, every spectral codebook with escapes, pulses, TNS, M/S, intensity and noise substitution, all window sequences and shapes. 26 FFmpeg-encoded files match FFmpeg's float decoder at 138 dB or better (multichannel through LAMP's speaker weights); ADTS, Matroska and fragmented MP4 copies are exact; 48 random valid streams with every coding tool match FFmpeg; 60 seeks without noise substitution are exact; 16 malformed or unsupported streams reject. See [AAC notes](docs/aac.md).

HE-AAC spectral band replication now runs on that core (signalled explicitly, by the backward-compatible extension or only in the stream), doubling the rate in MP4, Matroska and ADTS. With no HE-AAC encoder available, a Python SBR model writes its data into FFmpeg-encoded cores: 13 streams from mono to 7.1 at core rates 11.025–48 kHz match FFmpeg at 125 dB or better with every SBR tool covered, MP4/Matroska/fragmented copies with all three signalling forms are exact, corrupted SBR data falls back as in FFmpeg, and seeks match continuous decoding up to the SBR noise phase.

HE-AAC v2 parametric stereo now turns mono SBR streams into stereo (object type 29, the backward-compatible PS flag or implicit), with 10/20/34-band IID and ICC in every mode, IPD/OPD, hybrid filter banks, decorrelation and both mixing procedures. A Python PS model writes its data into the same generated streams: 12 streams at core rates 11.025–24 kHz match FFmpeg's stereo decode at 128 dB or better with every PS tool covered, MP4 copies with all three signalling forms are exact, corrupted PS data falls back as in FFmpeg, and seeks match continuous decoding up to the SBR noise phase.

AC-3 (Dolby Digital) now decodes in raw `.ac3`, Matroska and MP4 with a new assembly decoder following FFmpeg's structure: bsid 0–10 including half and quarter rates, every channel mode with LFE, block switching, coupling, rematrixing, all exponent strategies, delta bit allocation, dynamic range and FFmpeg's dither sequence, with CRC checks and FFmpeg-style concealment. 20 FFmpeg-encoded files and 24 streams written through a Python model (covering every tool and bit allocation pointer FFmpeg's encoder never uses) match FFmpeg at 138 dB or better; container copies are exact; corrupted frames match FFmpeg's concealment; seeks in dither-free streams are exact. E-AC-3 is the next step. See [AC-3 notes](docs/ac3.md).

MPEG transport streams (188/192/204-byte packets) and program streams (`.mpg`, `.vob`) now play their first supported audio stream: PES payloads of MPEG audio, ADTS AAC or AC-3 (stream types, DVB descriptors or content identification; VOB AC-3 substreams) open as the raw stream, so decoding and seeking are those of raw files. 31 FFmpeg-muxed variants with video and second audio streams equal the raw decodes exactly, seeks are exact, and E-AC-3, LATM and LPCM reject as unsupported. See [MPEG-TS/PS notes](docs/mpegts.md).

WavPack 4/5 now decodes in native `.wv` files and Matroska with a new assembly decoder following FFmpeg's: lossless and hybrid (lossy, including the bit-rate mode) 8–32-bit integer and float audio, every decorrelation term, joint and false stereo, extra bits, INT32INFO shifts and float details, and frames of mono/stereo blocks for up to eight channels, with block and extra-bit CRC checks. 30 FFmpeg-encoded files decode exactly as FFmpeg (multichannel through LAMP's speaker weights) and their Matroska copies exactly as the `.wv` files; 37 streams written through a Python model cover everything FFmpeg's encoder never writes, including every wp_exp2 input, and the model, FFmpeg and LAMP agree exactly; 75 seeks are exact; DSD, other versions and unsupported layouts reject. See [WavPack notes](docs/wavpack.md).

MPEG audio Layers I and II now share the Layer III framing, index and synthesis: MPEG-1 and MPEG-2 lower rates, every allocation table and quantizer, all stereo modes and CRC checks. 96 random valid streams and 34 FFmpeg/libtwolame encoder files match FFmpeg's float decoders at 108.7 dB SNR or better, three files pass exact seek checks and seven malformed streams reject. See [Layer I/II notes](docs/mp2.md).

FLAC in Ogg (mapping 1.0) now uses the native FLAC decoder with frame-position checks at open and exact indexed seeks; eight files from 8 to 192 kHz, 16/24-bit and 1–8 channels match FFmpeg or native FLAC exactly. Chained and multiplexed Ogg files are supported as described above.

AIFF/AIFC now adds signed 1–32-bit PCM, AIFC byte-order/fixed-container variants, float32/64 and ordered Core Audio channel layouts with stereo output. Its suite passes 1,977 files, 19 sparse inputs up to 4,294,901,832 logical bytes, 30,443 exact seeks and 303 malformed-input rejections. Sparse fixtures allocate at most 393,216 bytes. Six WASAPI lifecycle scenarios pass. Declared frames, sound offsets, block padding, empty streams and cancellation are checked; [coverage and comparator limits](docs/aiff.md) distinguish original-container and raw-PCM references. Compressed AIFC codecs, native surround, newer/spatial layouts and exact fractional-rate output remain unfinished.

| Area | Planned coverage, in approximate priority order |
| --- | --- |
| Mainstream lossy audio | AAC-LC, HE-AAC v1/v2, AC-3 and MPEG Layers I/II (implemented); E-AC-3; then DTS families, WMA variants and other relevant legacy formats |
| Lossless and PCM | ALAC (implemented in MP4/Matroska), WavPack (implemented; DSD and correction files remain), APE, AIFF/AIFC, RF64, FLAC-in-Ogg, broader PCM/float and FLAC depths/layouts |
| Other audio | G.711, IMA/Microsoft ADPCM in WAVE and Flash ADPCM (implemented); Musepack, Speex, AMR and other telephony ADPCM; further formats from the compatibility inventory as demand and feasibility justify |
| Common containers | MP4/M4A/MOV, Matroska/WebM, MPEG TS/PS, CAF, AVI and FLV (audio implemented), ASF; broader Ogg stream mappings |
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
