<p align="center"><img src="assets/lamp.png" width="128" height="128" alt="LAMP's two-tone lamp icon"></p>

# LAMP — Lev's Assembly Media Player

A small media player for Windows and Linux x86-64 and Apple Silicon macOS with handwritten assembly decoders and a native assembly UI. Audio comes first. The long-term goal is to support the relevant formats and playback features people use in **mpv**, with a small runtime and low CPU use.

**Current source: 0.4.0-dev, an early audio prototype.** WAV, AIFF/AIFC, native FLAC, MP3, MP2/MP1, Ogg/Vorbis, Ogg/Opus and FLAC in Ogg play in source builds, including chained and multiplexed Ogg files, Matroska/WebM files with Opus, Vorbis, FLAC, ALAC, AAC, MPEG audio or PCM tracks, MP4/M4A/MOV files with AAC-LC or HE-AAC, ALAC, MPEG audio, Opus, FLAC or PCM tracks (including the audio of video files and fragmented MP4), and raw ADTS AAC. Opus supports family 0 mono/stereo and family 1 layouts with 1–8 speaker channels, downmixed to stereo. Its elementary decoders include RFC 8251 updates and pass all 120 official vector checks across five output rates and mono/stereo. Video, subtitles and network streaming are future work. The published v0.3.0 prerelease contains WAV, native FLAC, MP3 and Ogg/Vorbis.

[Website](https://levkropp.github.io/lamp/) · [Download v0.3.0](https://github.com/levkropp/lamp/releases/tag/v0.3.0) · [Roadmap](ROADMAP.md) · [Compatibility matrix](docs/compatibility.md) · [Technical details and limits](docs/technical.md) · [Apple Silicon build](docs/macos.md)

![LAMP's assembly playback controls](site/assets/player.png)

## Why LAMP?

- Handwritten x86-64 assembly runtime and decoders, SSE2 baseline. One GNU-syntax source tree builds a static, libc-free Linux executable with `as`/`ld` and Windows executables with LLVM, following [Rhun](https://rhun.app/)'s approach.
- Event-driven playback, a decode worker, and buffered PCM to absorb short scheduling stalls: WASAPI on Windows, the PulseAudio native protocol on Linux (PulseAudio or PipeWire), without libpulse. macOS uses native ARM64 Core Audio and AppKit adapters with translated shared decoders.
- A compact mpv-inspired UI, with Rhun's assembly UI approach and minimalist visual style as references.
- No codec DLL, C runtime, FFmpeg subprocess, or mpv engine in the player. Normal Windows system DLLs provide platform services; on Linux the player makes raw system calls. macOS uses libSystem, AppKit and AudioToolbox.
- MIT project license, with preserved MIT/MIT-0/CC0/BSD notices for reference-derived algorithms and data.

LAMP aims to reduce stutters. It cannot guarantee uninterrupted playback during arbitrary system or driver stalls. [Same-machine headless playback measurements](docs/playback-benchmark.md) compare its assembly engine with mpv and VLC; shipping-GUI, wakeup and audible-latency measurements remain pending.

## Run

Windows 10/11 x64 with a working default audio output is the primary desktop target. Build from source for Opus and AIFF/AIFC support, or download the earlier [v0.3.0 Windows prerelease](https://github.com/levkropp/lamp/releases/tag/v0.3.0). Open `bin\lamp.exe` and drop a supported audio file onto the window.

```powershell
.\bin\lamp.exe 'C:\Music\track.ogg'
.\bin\lamp-cli.exe 'C:\Music\track.flac'
.\bin\lamp-cli.exe --check 'C:\Music\track.mp3'
.\bin\lamp-cli.exe --decode 'C:\Music\track.ogg' '.\track.f32'
```

Apple Silicon Macs need macOS 12 or later. Build with Python 3 and Xcode command line tools, then open the native app bundle:

```sh
./build.sh
open build/macos/LAMP.app
build/macos/lamp-cli 'Music/track.flac'
build/macos/lamp-cli --check 'Music/track.opus'
build/macos/lamp-cli --decode 'Music/track.ogg' 'track.f32'
```

The Mac app has Open, Finder file-open/drop handlers, pause/replay, stop, timeline seeking and volume controls. Cmd+O opens; Cmd+Q quits. The local bundle is ad-hoc signed. See [Mac build strategy, controls, verification and limits](docs/macos.md). The published v0.3.0 download remains Windows-only.

On Linux x86-64, `./build.sh` produces a static `build/lamp-cli` with the same decoders, playback, checks and export. It plays through PulseAudio or PipeWire's pulse server by speaking their native protocol directly:

```sh
./build/lamp-cli ~/Music/track.flac
./build/lamp-cli --check ~/Music/track.mp3
./build/lamp-cli --decode ~/Music/track.ogg track.f32
```

The Linux desktop window is not available yet; see the [roadmap](ROADMAP.md).

`--check` decodes without an audio device. `--decode` writes little-endian float32 PCM with two interleaved channels; mono is duplicated. Opus output is 48 kHz; AIFF/AIFC rates round to integer hertz; chained Ogg files use their first link's rate; other formats use their source rate. The destination must be new. Failed exports can leave partial output.

| Format | Current support |
| --- | --- |
| AIFF / AIFC | Signed PCM 1–32-bit, AIFC byte-order/fixed-container variants and float32/64; 1–8 channels, ordered Core Audio layouts, rounded 8–192 kHz output |
| WAV | Little-endian RIFF/RF64/BW64 audio framing, PCM 8/16/24/32-bit or float32/64; 1–8 channels, extensible valid bits/layouts, 8–192 kHz |
| Native FLAC | 1–8 channels, 4–32-bit, 8–192 kHz; CRC checks; speaker-mask-aware stereo downmix |
| MP3 | MPEG-1/2/2.5 Layer III, mono/stereo, CBR/VBR, encoder trimming when tagged |
| MP2 / MP1 | MPEG-1 and MPEG-2 (16–24 kHz) Layers II and I: all allocation tables, stereo/joint/dual/mono, CRC checks; exact seeks |
| Ogg/Vorbis | 1–255 channels, floor 1, mapping 0; stereo output, CRC and granule checks |
| Ogg/Opus | Development source: family 0 mono/stereo or family 1 with 1–8 speaker channels downmixed to stereo; 48 kHz output, header gain/pre-skip/end trimming |
| FLAC in Ogg | FLAC-in-Ogg 1.0 mapping with the native FLAC limits; exact seeks |
| Matroska / WebM | Audio track with Opus, Vorbis, FLAC, ALAC, AAC (LC, HE-AAC), MPEG Layers I–III or PCM; lacing, unknown sizes, DiscardPadding; video and other tracks skipped; [details](docs/matroska.md) |
| MP4 / M4A / MOV | Audio track with AAC (LC, HE-AAC), Apple Lossless (16–32-bit, 1–8 channels), MPEG Layers I–III, Opus, FLAC or QuickTime/ISO PCM; progressive or fragmented; edit lists and sample durations trim the start and end; [details](docs/mp4.md) |
| AAC | AAC-LC (object type 2), 8–96 kHz, mono to 7.1, M/S, intensity, PNS, TNS and pulses; HE-AAC spectral band replication (explicit, backward-compatible or implicit signalling, 16–96 kHz output); in MP4, Matroska or ADTS `.aac`; parametric stereo (HE-AAC v2) not yet; [details](docs/aac.md) |
| Ogg files | Chained links and multiplexed streams: each link plays its first Vorbis, Opus or FLAC stream (video and other streams are skipped); links at another rate are resampled to the first link's rate |

See [precise coverage, limitations, and verification](docs/technical.md) before relying on a particular stream variant. Native surround output remains unfinished. [Ogg links, multiplexed streams, FLAC-in-Ogg and the resampler](docs/ogg.md) have their own notes. [WAV](docs/wav.md), [FLAC](docs/flac.md) and [Vorbis](docs/vorbis.md) speaker layouts downmix to stereo; WAV also accepts left-aligned valid bits and float64 samples. WAV and AIFF/AIFC seek directly; native FLAC uses seek tables or searches validated frames; MP3, Vorbis and Opus use sparse indexes.

RF64/BW64 audio framing adds checked 64-bit lengths and direct seeks beyond 4 GiB. Its suite checks 538 files, 16 sparse large-file fixtures, 8,950 exact seeks and 312 malformed-input rejections. BW64 uses the existing WAVE speaker policy; ADM scene/object rendering remains unfinished. See [container rules and comparator limits](docs/wav.md#rf64bw64-framing-and-large-files).

AIFF/AIFC adds signed PCM, float32/64, ordered Core Audio layouts and sample-exact direct seeks. Its suite checks 1,977 files, 19 sparse large-file cases, 30,443 seeks and 303 malformed-input rejections. Output remains stereo; rates round to integer hertz. See [AIFF/AIFC coverage and reference limits](docs/aiff.md).

Vorbis now decodes 1–255 native channels. Standard 1–8-channel layouts use the documented stereo speaker policy; larger application-defined layouts output ports 0/1 while every channel is decoded and validated. Its suite checks 797 files, 23,910 native/stereo seeks, protected output, cancellation, allocation release and 14 malformed/resource-limit rejections. Independent Xiph and specification references check native PCM before mixing. See [Vorbis coverage and comparator limits](docs/vorbis.md).

## Controls

| Control | Action |
| --- | --- |
| O / Ctrl+O; file drop | Open audio |
| Space; playback button | Pause/resume or replay |
| Left / Right | Seek ±5 seconds |
| Home; timeline click | Start; seek to position |
| Up / Down; volume bar | Adjust volume |
| M | Mute/unmute to 100% |
| Q | Close |

On Windows, the controls hide after 2.5 seconds of inactivity during playback and seeking runs on a worker. The Mac interface uses persistent native controls; seeking currently reopens/repositions synchronously. Mac keyboard bindings also include F for fullscreen and Escape to leave fullscreen. WAV and AIFF/AIFC jump directly to the sample; native FLAC uses a validated seek table or a bounded frame search, including files with unknown duration. Exhausting the search budget falls back to sequential decoding. MP3 restores an indexed reservoir and decodes two frames of pre-roll before the target. Vorbis restores an Ogg packet boundary and decodes one packet to rebuild overlap. Opus restores a packet boundary at least 80 ms before the target to rebuild decoder state; near the beginning it applies normal pre-skip. These indexes are built from headers when opening a file. Paused seeking keeps audio stopped until resume. The console accepts Space to pause and Q/Ctrl+C to stop.

## Build and verify

LAMP follows [Rhun](https://rhun.app/)'s build approach: GNU assembler syntax (`.intel_syntax noprefix`) shared by every platform, no external codec library. The code uses the Microsoft x64 calling convention on Windows and Linux; the Mac translation uses native ABI bridges. `src/` holds the shared decoders, `src/win/` the WASAPI engine, GDI UI and Win32 services, and `src/linux/` raw-syscall services and the Linux command line.

**Linux** needs GNU binutils (`as`, `ld`):

```sh
./build.sh                       # build/lamp-cli, static and libc-free
python3 tests/run.py --quick     # smoke, table provenance, 35 Opus oracle suites, Ogg CRC
python3 tests/run.py             # adds every FFmpeg-based PCM, seek, layout and container suite,
                                 # and bit-exact playback through a private PulseAudio null sink
```

**Windows** needs [LLVM](https://llvm.org/) (`llvm-mc`, `lld-link`, `llvm-dlltool`, `llvm-rc`; for example `winget install LLVM.LLVM`) and Python. The same script also cross-builds the Windows binaries from Linux or macOS:

```powershell
.\build.ps1                      # or: python tools/build-windows.py
node .\tests\verify-runtime.js
node .\tests\smoke.js
python .\tests\run.py --quick
.\tests\verify-engine.ps1         # WASAPI lifecycle (Windows only)
.\tests\render-ui.ps1
.\package.ps1
```

For Apple Silicon, `./build.sh --release` builds the ARM64 app and CLI. Python is used only during the build. `tools/arm64.py` is the pinned MIT Rhun translator; `tools/arm64_lamp.py` adds the instructions used by LAMP. No translated code is interpreted at runtime.

```sh
python3 tests/verify-macos.py --layouts --opus --audio --ui
python3 tools/package-mac.py
```

Mac verification additionally needs Python 3.12+, Node.js and FFmpeg with libmp3lame/libopus. It builds the bundled, hash-verified Xiph/Opus references into test artifacts only. Audio/UI checks need a desktop session and working output device. Generated reports, translation artifacts and binaries live under `build/macos`. The package contains the app, CLI, notices and a SHA-256 manifest. [Mac verification scope](docs/macos.md#verification) is separate from the Windows results below.

The prebuilt ICO and decoder tables are included. A normal build needs no codec library or reference C compiler; import libraries come from `src/win/*.def`. Both Windows players use custom assembly entry points and no default libraries. The development build measures **206,848 bytes for `lamp.exe`** and **198,656 bytes for `lamp-cli.exe`**, including icon resources; release manifests record exact sizes and hashes.

To build while the player is open, use `./build.ps1 -OutputDirectory ./bin/verify-build`. Pass that directory to `node ./tests/verify-runtime.js ./bin/verify-build` and `node ./tests/smoke.js ./bin/verify-build` to check the new binaries, or `./package.ps1 -BinaryDirectory ./bin/verify-build` to package them. Packaging rejects a binary version that differs from `VERSION`. Test runners honour `LAMP_OUT` for a different output directory.

Test oracles compile reference C (the RFC 6716/8251 Opus decoder, stb_vorbis, libvorbis) only into test executables, with GCC or Clang on Linux and Visual C++ on Windows. On Linux, prototypes for assembly functions carry `__attribute__((ms_abi))` through `tests/lamp-test.h`.

The codec suites record 43 WAV/FLAC, 103 MP3, and 83 Vorbis checks, plus 4,425 exact WAV/FLAC/MP3/Vorbis seek checks and 6,768 Opus seeks against an independently positioned RFC 8251 reference decoder. Separate depth/layout suites check 965 WAV files with 14,475 exact seeks and 404 FLAC files with 6,060 exact seeks, guarded reads, cancellation and allocation release. Ogg seeking includes continued packets, cropped starts, granule origins and bounded index compaction. Engine lifecycle, malformed-input, stress and codec reference tests add separate coverage. These checks do not establish complete format conformance. [Test instructions](docs/technical.md#verification) and [recorded reports](reports/README.md) describe what was checked. Full fixture suites need FFmpeg, Node.js and Python; seek and Opus oracle tests additionally use a C compiler for test executables only.

The Ogg CRC pass uses eight-byte table updates while retaining complete validation. On this machine, median reopen time for the recorded ten-minute fixtures fell from 32.7 to 12.5 ms for Vorbis and from 13.8 to 5.3 ms for Opus. These are warm-filesystem decoder timings, excluding WASAPI, the UI and audible latency. [Decoder measurements and scope](docs/technical.md#playback-and-cpu-design) include silence and noise targets. A separate [headless playback comparison](docs/playback-benchmark.md) records mpv 0.41.0 and VLC 3.0.24, startup/seek observations and CPU/RAM during playback, pause and idle across all five formats, with and without four CPU load workers. Its timing clocks differ between players; it does not establish audible latency or a universal performance advantage.

The UI image comes from the actual assembly renderer with synthetic state. Open-dialog, drag/drop, and monitor-DPI interaction still require desktop verification.

## Roadmap and contribution

Latest Opus work adds family 1 multistream decoding and the RFC stereo downmix. The new integration suite checks 86 generated streams, 1,032 reset-reference seeks, repeated/silent/unmapped channels, gain/trim bounds, malformed packets and cancellation. Another 112 modern-libopus family 1 files pass independent float PCM comparisons, with peak error below 0.000002. The original family 0 suite retains 393 reference streams and 51 modern-libopus fixtures. All 120 official elementary-decoder vector checks pass, including reference PCM/history and final-range validation for 200,750 packets. Playback, pause/resume, stop/reopen and indexed/paused seeking pass for Opus and the existing formats. Native surround routing remains unfinished. See [the decoder-stage notes](docs/opus.md); `python3 tests/verify-opus-components.py` runs 35 suites without FFmpeg or an audio device, and `python3 tests/verify-opus-conformance.py` runs official vectors.

[ROADMAP.md](ROADMAP.md) covers Opus, reliable audio playback, broader codecs and containers, video, subtitles, streaming, and eventual support for everything relevant that mpv supports. The [compatibility matrix](docs/compatibility.md) tracks the current gaps. Goals have acceptance gates, not promised release dates. Hardware decode should be used when it lowers system cost; handwritten assembly alone does not guarantee a faster codec.

Keep runtime and codec code in assembly. Use original implementations or carefully attributed permissive references (MIT, MIT-0, BSD-2-Clause, BSD-3-Clause, or CC0). Preserve applicable notices. Test tools may use other languages. Please include the failing media characteristics, a redistributable fixture when possible, and a reference comparison when reporting decoder issues.

## License and references

Original LAMP code and brand assets are [MIT licensed](LICENSE). See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for reference-derived code/data and test reference sources. The Mac translator and native helper macros/routines derive from the MIT-licensed Rhun revision recorded in those notices; Rhun branding and assets are not included.

- [Rhun](https://rhun.app/) / [assembly UI reference](https://github.com/vshvedov/rhun)
- [mpv](https://mpv.io/) / [feature reference](https://mpv.io/manual/stable/)
- [Vorbis specification](https://xiph.org/vorbis/doc/Vorbis_I_spec.html)
- [Opus RFC 6716](https://www.rfc-editor.org/rfc/rfc6716.html) / [Ogg Opus RFC 7845](https://www.rfc-editor.org/rfc/rfc7845.html)
