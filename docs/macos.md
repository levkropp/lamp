# Apple Silicon macOS

LAMP builds a native ARM64 command-line player and AppKit app bundle for Apple Silicon. The deployment target is macOS 12.0; verification was performed on macOS 26.4.1. Intel Macs and other operating systems are not targets of this build. The current shared decoder tree builds on all three platforms; the Mac CLI and app still need the additional controls listed below.

## Build and run

Install Xcode command line tools (`xcode-select --install`) and Python 3. Run from the repository root:

```sh
./build.sh
open build/macos/LAMP.app
build/macos/lamp-cli ~/Music/track.flac
build/macos/lamp-cli --check ~/Music/track.opus
build/macos/lamp-cli --decode ~/Music/track.ogg ./track.f32
build/macos/lamp-cli --version
```

`--check` runs without an audio device. Export writes interleaved little-endian float32 stereo to a new destination; it never overwrites an existing file. Mono is duplicated, multichannel streams follow the existing documented stereo routing, and Opus output is 48 kHz. Malformed/inaccessible input returns status 2; export/output failures return 1. A failed export can leave a partial file.

`./build.sh --release` strips local symbols. `--output PATH` builds into a separate directory. The build produces `lamp-cli`, `lamp`, and `LAMP.app`, including the LAMP icon at standard/Retina sizes, audio document associations, project licenses and an ad-hoc signature. The scripts use Python and Apple command line tools; building the player needs no Homebrew codec package, FFmpeg, Node.js, Rosetta or Wine. Python is not a runtime dependency.

The native app implements Open and Finder file-open/drop handlers; opening several files selects the first one. Standard AppKit buttons and sliders expose native accessibility and focus behavior. Keyboard shortcuts on the player view are:

| Control | Action |
| --- | --- |
| Cmd+O / O; Open button | Open audio |
| Space; Play/Pause button | Pause, resume or replay |
| Stop button | Stop and reset position |
| Left / Right | Seek five seconds backward/forward |
| Home; timeline slider | Beginning; seek to position |
| Up / Down; volume slider | Adjust volume |
| M | Mute/unmute to 100% |
| F / Escape | Toggle fullscreen / leave fullscreen |
| Cmd+Q / Q | Quit |

Focused native controls retain their usual keyboard behavior. The CLI accepts Space to pause/resume and Q or Ctrl+C to stop; it restores terminal settings on normal exit and Ctrl+C.

## Rhun build strategy

This port follows [Rhun's macOS model](https://github.com/vshvedov/rhun/blob/main/docs/guide.md#macos): translate the shared x86-64 assembly during the build, then link native ARM64 platform adapters. It retains the decoder implementation in one authoritative source rather than maintaining another copy of every codec algorithm.

1. `tools/build-mac.py` reads the same GNU Intel sources and includes in `src/` that Windows and Linux use. It discovers exported functions and data after expanding includes and generates native ABI bridges and data aliases. The historical `tools/masm.py` normalizer is no longer part of the build.
2. The pinned MIT `tools/arm64.py` translator, extended by `tools/arm64_lamp.py`, emits AArch64 instructions. Extensions cover LAMP's scalar/packed floating point, address forms, shift/carry/borrow flags, loops, string operations, GNU data directives and initialization math. Data layout follows the source exactly; pointer tables explicitly specify their alignment. Unsupported constructs fail the build.
3. Apple clang's integrated assembler assembles the generated `.s` files. `src/mac/bridge.s` maps Apple's calling convention to the shared decoder convention, including shadow space and stack arguments. Translated code uses Rhun's private register mapping and a guarded 16 MiB stack. Apple's reserved x18 is untouched.
4. `src/mac/platform.s` implements the decoder's file/mapping/allocation services through libSystem. Zeroed, page-aligned arenas use `mmap`; reservations initially protect payload pages, and commits use `mprotect` at the existing address. Each file mapping carries its own size, so nested playlists and containers can hold several mappings. Tracked allocation bytes must return to zero after closing a decoder. `runtime.s` supplies the translated string/division helpers. Vorbis initialization uses libSystem sin/cos/ldexp, rather than a system codec.
5. Native ARM64 `audio.s`, `ui.s` and `cli.s` provide Core Audio, AppKit and console behavior. The AppKit shell invokes Objective-C runtime services directly from assembly; no C, Objective-C or Swift application source is compiled into the player.

The shipped code is ARM64 Mach-O and executes directly on Apple Silicon. Translation happens once at build time; it does not interpret/emulate x86 instructions at runtime. No system media decoder, external codec library, FFmpeg subprocess or mpv engine performs decoding.

Rhun is pinned at `4d11f81019617e6e3a3922c81f5dedc3025d7884`. Its translator and macros are retained unchanged; the string/division helpers are adapted with the full MIT notice in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES). LAMP's normalizer, extensions, ABI/platform bridges and player backends are original additions. Rhun branding, fonts and assets are not included.

## Playback ownership

The backend uses three AudioQueue buffers of 2,048 interleaved float stereo frames. Core Audio owns the callback thread. It advances consumed position and decodes the next buffer; AppKit timer updates do not decode playback audio. At 48 kHz the queued capacity is 128 ms. This is a capacity, not a measurement of audible latency or an underrun guarantee.

The shared decoder has one instance and a private stack. A mutex serializes callback decoding and repositioning. Stop/reset first suppresses callback refills: AudioQueue returns discarded buffers through its callback, and those buffers must neither advance position nor enqueue replacement PCM. Seeking reopens the decoder, restores its preceding index point, discards to the requested frame and primes the stopped queue. Seeking while paused leaves playback paused; seeking to EOF finishes without starting an empty queue. Natural EOF drains queued output. Zero-frame streams finish without starting an empty queue. Disposal waits for the callback before closing the decoder.

## Verification

Install Python 3.12+, Node.js and FFmpeg with libmp3lame/libopus for the test fixtures. Reference sources are already bundled and hash-verified; no downloaded library is linked into the player.

```sh
# PCM, indexed seeks, Unicode, exclusive export and deterministic mutations:
python3 tests/verify-macos.py

# Existing precision/layout/sparse-file suites and all 35 Opus oracles:
python3 tests/verify-macos.py --layouts --opus

# Add real device playback and an AppKit launch/playback/timer/exit check:
python3 tests/verify-macos.py --layouts --opus --audio --ui
```

`--skip-build` uses current objects/binaries; `--binary-directory PATH` selects another build directory. The complete run needs a desktop session and working default audio output. In a restricted execution sandbox, Core Audio, AppKit and Apple's icon compiler may require running outside that sandbox. Results are checkpointed in `build/macos/macos-verification.json`; individual layout reports live under `build/macos/layout-fixtures`. `--skip-build --resume` retains completed stages only when exact binary identities match, reruns the baseline checks and adds the requested optional checks.

The baseline checks 80 files across 8/44.1/48/96 kHz, mono/stereo, integer/float PCM and the six formats, plus 375 indexed seeks, Unicode paths, preservation of existing exports and 192 deterministic corrupt/truncated mutations. Xiph's pinned float Vorbis decoder checks complete PCM including the final granule; FFmpeg uses the independent libopus decoder explicitly for Opus. Reference errors/tolerances and the exact inputs are retained in the report.

The 35 Opus suites compile the hash-verified RFC 6716 reference with RFC 8251 updates. They exercise integer/entropy math, SILK/CELT transforms and history, packet-to-PCM dispatch, mode/rate/layout transitions, protected output, multistream stereo routing and 1,032 reset-reference seeks. Test adapters import shared globals, use Apple's page size and define the reference's otherwise undefined `isqrt32(0)` result as zero. Reference C is confined to test artifacts. The earlier official-vector report remains a Windows result; it is not presented as a new Mac official-vector run.

The optional layout checks reuse the existing numeric/fixture/reference oracles for WAV, FLAC, RF64/BW64, AIFF/AIFC and Vorbis. Native test adapters replace UTF-16 paths with UTF-8, use Apple ABI entry points and protected-page sizes, create sparse APFS files instead of issuing NTFS sparse ioctls, and measure live malloc bytes plus tracked decoder mappings for allocation-release checks instead of Windows process private commit. If FFmpeg lacks libvorbis, the pinned Xiph test encoder creates its Vorbis fixtures. The suite reports identify these adaptations.

The [current shared-tree release report](../reports/macos-shared-tree-verification.json) records the baseline, all 35 Opus suites, 4,681 layout files, 83,838 layout seeks, 677 rejected layouts, Core Audio lifecycle checks and the AppKit smoke test. The earlier `macos-verification.json` and `macos-release-verification.json` reports describe the original six-format foundation.

The [cross-architecture report](../reports/macos-shared-verification.json) checks 594 retained fixtures from the AAC PCE, GSM, MP4/QuickTime, LATM, HE-AAC, AC-3, CAF/WAVE64, compressed WAVE and MPEG-TS/PS suites against a fresh Linux x86 build of identical shared sources: 497 successful decodes are byte-exact and 97 reject consistently. It also records 735 continuous-PCM seek comparisons and eight protected-page PCE/LATM oracles (12,839 prefixes and 4,800 mutations). Exact seek checks use the original suites' policies, including the IMA4 tolerance; HE-AAC approximate reconstruction seeks are outside their scope. This is a translation regression check; the independent reference reports retain their original platform and coverage.

To reproduce that comparison, generate the original suites' fixtures on Linux, then record and copy the corpus directory to the Mac:

```sh
# Linux, after generating the format-suite fixtures:
python3 tests/verify-macos-shared.py --record --binary build/lamp-cli --corpus build/mac-corpus
# Mac, using the copied corpus and a native build:
python3 tests/verify-macos-shared.py --corpus build/mac-corpus --binary-directory build/macos --seeks
python3 tests/verify-macos-translation.py --binary-directory build/macos
LAMP_OUT=build/macos-wavpack python3 tests/verify-wavpack.py --skip-playback
```

The [translation instruction oracle](../reports/macos-translation-verification.json) covers 40,000 deterministic cases of packed multiply/add, borrow/loop flags, floating-point rounding/overflow and packed data layout. The [native WavPack report](../reports/macos-wavpack-verification.json) records 104 checks against FFmpeg, the written-stream model and continuous decoding. Neither requires an external codec at runtime.

Real-device tests exercise three open/pause/paused-seek/resume/EOF/stop cycles, natural EOF and failed-open recovery for each of the six formats. Pseudo-terminal checks keep playback paused past its original duration, then verify Q/Ctrl+C exit and restoration of terminal settings. The comparison excludes only Darwin’s transient PENDIN input-state bit; configuration flags, speeds and control characters are checked. The UI smoke check verifies native launch, playback, timer updates and exit. Open-panel, Finder/drop, focused-control shortcuts, fullscreen, accessibility, Retina and multiple-display interactions still need comprehensive manual desktop testing. These checks do not establish complete conformance, universal performance, audible latency, device-reconnection behavior or immunity to system stalls.

## Packaging and remaining platform work

```sh
python3 tools/package-mac.py
# Package a previously built release:
python3 tools/package-mac.py --skip-build --binary-directory build/macos
```

The ZIP contains the app, CLI, notices, this guide and a manifest of file sizes/SHA-256 hashes. Packaging verifies the binary version against `VERSION` and the bundle signature. The archive receives a separate SHA-256 file.

The default signature is local/ad-hoc. Developer ID signing, hardened-runtime/notarization, release CI and a published macOS download remain future distribution work. This port does not modify the published Windows prerelease.

Current Mac differences are explicit: native controls stay visible; seeks/open/index construction can block the UI; the default audio device and Core Audio's sample-rate conversion are used; output remains stereo. Asynchronous seek/open, output-device selection/reconnection, exclusive output, sleep/wake recovery and measured Mac CPU/wakeup/latency comparisons remain roadmap work. Codec/container limits remain those documented in the repository. The rebased branch now shares the current decoder tree across all three platforms. Mac CLI/player parity is part of the pre-video goal: queues/playlists and editing, navigation/repeat/resume, tags/chapters/cover presentation, track/rate/device selection, and asynchronous transport still need native front-end integration and checks. New shared features must include Mac validation; a successful translation build alone does not establish feature parity.
