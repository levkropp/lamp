<p align="center"><img src="assets/lamp.png" width="128" height="128" alt="LAMP's two-tone lamp icon"></p>

# LAMP — Lev's Assembly Media Player

A small Windows x86-64 media player with handwritten assembly decoders and a native assembly UI. Audio comes first. The long-term goal is to support the relevant formats and playback features people use in **mpv**, with a small runtime and low CPU use.

**Current source: 0.4.0-dev, an early audio prototype.** WAV, AIFF/AIFC, native FLAC, MP3, Ogg/Vorbis and Ogg/Opus play in source builds. Opus supports family 0 mono/stereo and family 1 layouts with 1–8 speaker channels, downmixed to stereo. Its elementary decoders include RFC 8251 updates and pass all 120 official vector checks across five output rates and mono/stereo. Video, subtitles and network streaming are future work. The published v0.3.0 prerelease contains WAV, native FLAC, MP3 and Ogg/Vorbis.

[Website](https://levkropp.github.io/lamp/) · [Download v0.3.0](https://github.com/levkropp/lamp/releases/tag/v0.3.0) · [Roadmap](ROADMAP.md) · [Compatibility matrix](docs/compatibility.md) · [Technical details and limits](docs/technical.md)

![LAMP's assembly playback controls](site/assets/player.png)

## Why LAMP?

- MASM x86-64 runtime, including the working audio decoders; SSE2 baseline.
- Event-driven WASAPI playback, a decode worker, and buffered PCM to absorb short scheduling stalls.
- A compact mpv-inspired UI, with Rhun's assembly UI approach and minimalist visual style as references.
- No codec DLL, C runtime, FFmpeg subprocess, or mpv engine in the player. Normal Windows system DLLs provide platform services.
- MIT project license, with preserved MIT/MIT-0/CC0/BSD notices for reference-derived algorithms and data.

LAMP aims to reduce stutters. It cannot guarantee uninterrupted playback during arbitrary system or driver stalls. [Same-machine headless playback measurements](docs/playback-benchmark.md) compare its assembly engine with mpv and VLC; shipping-GUI, wakeup and audible-latency measurements remain pending.

## Run

Windows 10/11 x64 and a working default audio output are the intended targets. Build from source for Opus and AIFF/AIFC support, or download the earlier [v0.3.0 Windows prerelease](https://github.com/levkropp/lamp/releases/tag/v0.3.0). Open `bin\lamp.exe` and drop a supported audio file onto the window.

```powershell
.\bin\lamp.exe 'C:\Music\track.ogg'
.\bin\lamp-cli.exe 'C:\Music\track.flac'
.\bin\lamp-cli.exe --check 'C:\Music\track.mp3'
.\bin\lamp-cli.exe --decode 'C:\Music\track.ogg' '.\track.f32'
```

`--check` decodes without an audio device. `--decode` writes little-endian float32 PCM with two interleaved channels; mono is duplicated. Opus output is 48 kHz; AIFF/AIFC rates round to integer hertz; other formats use their source rate. The destination must be new. Failed exports can leave partial output.

| Format | Current support |
| --- | --- |
| AIFF / AIFC | Signed PCM 1–32-bit, AIFC byte-order/fixed-container variants and float32/64; 1–8 channels, ordered Core Audio layouts, rounded 8–192 kHz output |
| WAV | Little-endian RIFF/RF64/BW64 audio framing, PCM 8/16/24/32-bit or float32/64; 1–8 channels, extensible valid bits/layouts, 8–192 kHz |
| Native FLAC | 1–8 channels, 4–32-bit, 8–192 kHz; CRC checks; speaker-mask-aware stereo downmix |
| MP3 | MPEG-1/2/2.5 Layer III, mono/stereo, CBR/VBR, encoder trimming when tagged |
| Ogg/Vorbis | Single logical stream, mono/stereo, floor 1, mapping 0; CRC and granule checks |
| Ogg/Opus | Development source: one logical Ogg stream; family 0 mono/stereo or family 1 with 1–8 speaker channels downmixed to stereo; 48 kHz output, header gain/pre-skip/end trimming |

See [precise coverage, limitations, and verification](docs/technical.md) before relying on a particular stream variant. Native surround output, multichannel Vorbis, chained Ogg streams and FLAC-in-Ogg remain unfinished. [WAV](docs/wav.md) and [FLAC](docs/flac.md) speaker layouts downmix to stereo; WAV also accepts left-aligned valid bits and float64 samples. WAV and AIFF/AIFC seek directly; native FLAC uses seek tables or searches validated frames; MP3, Vorbis and Opus use sparse indexes.

RF64/BW64 audio framing adds checked 64-bit lengths and direct seeks beyond 4 GiB. Its suite checks 538 files, 16 sparse large-file fixtures, 8,950 exact seeks and 312 malformed-input rejections. BW64 uses the existing WAVE speaker policy; ADM scene/object rendering remains unfinished. See [container rules and comparator limits](docs/wav.md#rf64bw64-framing-and-large-files).

AIFF/AIFC adds signed PCM, float32/64, ordered Core Audio layouts and sample-exact direct seeks. Its suite checks 1,977 files, 19 sparse large-file cases, 30,443 seeks and 303 malformed-input rejections. Output remains stereo; rates round to integer hertz. See [AIFF/AIFC coverage and reference limits](docs/aiff.md).

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

The controls hide after 2.5 seconds of inactivity during playback. Seeking runs on a worker. WAV and AIFF/AIFC jump directly to the sample; native FLAC uses a validated seek table or a bounded frame search, including files with unknown duration. Exhausting the search budget falls back to sequential decoding. MP3 restores an indexed reservoir and decodes two frames of pre-roll before the target. Vorbis restores an Ogg packet boundary and decodes one packet to rebuild overlap. Opus restores a packet boundary at least 80 ms before the target to rebuild decoder state; near the beginning it applies normal pre-skip. These indexes are built from headers when opening a file. Paused seeking keeps audio stopped until resume. The console accepts Space to pause and Q/Ctrl+C to stop.

## Build and verify

Install **Visual Studio 2022 Build Tools**, its x64 C++ tools, and a **Windows SDK**. Build scripts locate `ml64`, `link`, and `rc` automatically:

```powershell
.\build.ps1
node .\tests\verify-runtime.js
node .\tests\smoke.js
.\tests\render-ui.ps1
.\package.ps1
```

The prebuilt ICO and decoder tables are included. A normal build needs no codec library or reference C compiler. Both players use custom assembly entry points and `/NODEFAULTLIB`. The development build measures **201,728 bytes for `lamp.exe`** and **194,048 bytes for `lamp-cli.exe`**, including icon resources; release manifests record exact sizes and hashes.

To build while the player is open, use `./build.ps1 -OutputDirectory ./bin/verify-build`. Pass that directory to `node ./tests/verify-runtime.js ./bin/verify-build` and `node ./tests/smoke.js ./bin/verify-build` to check the new binaries, or `./package.ps1 -BinaryDirectory ./bin/verify-build` to package them. Packaging rejects a binary version that differs from `VERSION`.

The codec suites record 43 WAV/FLAC, 103 MP3, and 83 Vorbis checks, plus 4,425 exact WAV/FLAC/MP3/Vorbis seek checks and 6,768 Opus seeks against an independently positioned RFC 8251 reference decoder. Separate depth/layout suites check 965 WAV files with 14,475 exact seeks and 404 FLAC files with 6,060 exact seeks, guarded reads, cancellation and allocation release. Ogg seeking includes continued packets, cropped starts, granule origins and bounded index compaction. Engine lifecycle, malformed-input, stress and codec reference tests add separate coverage. These checks do not establish complete format conformance. [Test instructions](docs/technical.md#verification) and [recorded reports](reports/README.md) describe what was checked. Full fixture suites need FFmpeg and Node.js; seek and Opus oracle tests additionally use the C compiler for test executables only.

The Ogg CRC pass uses eight-byte table updates while retaining complete validation. On this machine, median reopen time for the recorded ten-minute fixtures fell from 32.7 to 12.5 ms for Vorbis and from 13.8 to 5.3 ms for Opus. These are warm-filesystem decoder timings, excluding WASAPI, the UI and audible latency. [Decoder measurements and scope](docs/technical.md#playback-and-cpu-design) include silence and noise targets. A separate [headless playback comparison](docs/playback-benchmark.md) records mpv 0.41.0 and VLC 3.0.24, startup/seek observations and CPU/RAM during playback, pause and idle across all five formats, with and without four CPU load workers. Its timing clocks differ between players; it does not establish audible latency or a universal performance advantage.

The UI image comes from the actual assembly renderer with synthetic state. Open-dialog, drag/drop, and monitor-DPI interaction still require desktop verification.

## Roadmap and contribution

Latest Opus work adds family 1 multistream decoding and the RFC stereo downmix. The new integration suite checks 86 generated streams, 1,032 reset-reference seeks, repeated/silent/unmapped channels, gain/trim bounds, malformed packets and cancellation. Another 112 modern-libopus family 1 files pass independent float PCM comparisons, with peak error below 0.000002. The original family 0 suite retains 393 reference streams and 51 modern-libopus fixtures. All 120 official elementary-decoder vector checks pass, including reference PCM/history and final-range validation for 200,750 packets. Playback, pause/resume, stop/reopen and indexed/paused seeking pass for Opus and the existing formats. Ogg chaining and native surround routing remain unfinished. See [the decoder-stage notes](docs/opus.md); `./tests/verify-opus-components.ps1` runs 35 suites without FFmpeg or an audio device, and `./tests/verify-opus-conformance.ps1` runs official vectors.

[ROADMAP.md](ROADMAP.md) covers Opus, reliable audio playback, broader codecs and containers, video, subtitles, streaming, and eventual support for everything relevant that mpv supports. The [compatibility matrix](docs/compatibility.md) tracks the current gaps. Goals have acceptance gates, not promised release dates. Hardware decode should be used when it lowers system cost; handwritten assembly alone does not guarantee a faster codec.

Keep runtime and codec code in assembly. Use original implementations or carefully attributed permissive references (MIT, MIT-0, BSD-2-Clause, BSD-3-Clause, or CC0). Preserve applicable notices. Test tools may use other languages. Please include the failing media characteristics, a redistributable fixture when possible, and a reference comparison when reporting decoder issues.

## License and references

Original LAMP code and brand assets are [MIT licensed](LICENSE). See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for reference-derived code/data and test reference sources. No Rhun source or logo assets are included.

- [Rhun](https://rhun.app/) / [assembly UI reference](https://github.com/vshvedov/rhun)
- [mpv](https://mpv.io/) / [feature reference](https://mpv.io/manual/stable/)
- [Vorbis specification](https://xiph.org/vorbis/doc/Vorbis_I_spec.html)
- [Opus RFC 6716](https://www.rfc-editor.org/rfc/rfc6716.html) / [Ogg Opus RFC 7845](https://www.rfc-editor.org/rfc/rfc7845.html)
