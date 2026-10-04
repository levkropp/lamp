# LAMP 0.3.0 technical details

A Windows x86-64 audio player with handwritten assembly WAV, FLAC, MP3, and Ogg/Vorbis decoders, plus a native assembly UI. The branded console executable is **102,400 bytes (100 KiB)**; the graphical executable is **110,080 bytes (107.5 KiB)**. Both include LAMP's icon and version resources. Exact packaged sizes and hashes are in the release `manifest.json`.

The dark canvas, compact playback controls and automatic hiding are inspired by mpv. The custom pixel buffer and Win32 presentation follow Rhun's documented assembly UI model. No Rhun source, fonts, icons, or other assets were copied.

**Opus playback is unfinished.** The tested assembly packet decoder connects all four packet framing codes to SILK, hybrid and CELT float PCM, preserving histories across bandwidth/frame changes, stereo conversion, redundant transition audio, crossfades, FEC, loss and DTX. SILK packet/API and CELT component suites validate its underlying integer/float stages. These development objects are not linked into either player. Channel mapping, gain/trimming, Ogg integration and full audio-vector validation remain. An `.opus` file is rejected. [Opus stage documentation](opus.md) records interfaces, bounds, results and remaining work.

All runtime application and decoder code is MASM x64 assembly. No C/C++/Rust codec, codec DLL, CRT, FFmpeg process, or media-player engine is linked or invoked. Reference C source is used only for algorithms, permitted coefficient/probability data, and test oracles.

## Run

Windows 10/11 x64 with a working default audio output are the intended targets. Double-click `bin\lamp.exe`, drop a supported file onto it, or run:

```powershell
.\bin\lamp.exe 'C:\Music\track.ogg'
.\bin\lamp-cli.exe 'C:\Music\track.flac'
.\bin\lamp-cli.exe --check 'C:\Music\track.ogg'
.\bin\lamp-cli.exe --decode 'C:\Music\track.ogg' '.\track.f32'
```

`--check` decodes silently without an audio device. `--decode` exports little-endian float32 PCM at the source rate, always with two interleaved channels; mono is duplicated at its original amplitude. The destination must be a new file. Float32 WAV NaN/infinity samples become silence. A failed export can leave partial output.

| UI control | Action |
| --- | --- |
| O or Ctrl+O | Open a file |
| Space or play/pause button | Pause/resume; replay after completion |
| Left/Right | Seek backward/forward five seconds |
| Home | Seek to the start |
| Timeline click | Seek to that position |
| Up/Down | Adjust volume by five percentage points |
| Volume bar click | Set volume |
| M | Mute/unmute to 100% |
| Q | Close |
| File drop | Open the first dropped file |

Controls hide after 2.5 seconds of inactivity during playback, and reappear on mouse movement or keyboard input. Idle, paused, finished and hidden-control states stop redraw timers. Visible playback controls update at four frames per second. The window adopts Windows' suggested rectangle on a DPI change; typography and control dimensions currently use fixed pixels.

Console controls are Space to pause/resume and Q/Ctrl+C to stop. QuickEdit is disabled during playback and restored on exit.

Seeking restarts the decoder on a worker and discards PCM from the beginning to the requested second. Long seeks can take time. The UI remains responsive, and seeking while paused keeps audio stopped until resume. There is no compressed-stream seek index yet.

## Format coverage

| Format | Implemented coverage |
| --- | --- |
| WAV | Little-endian RIFF; PCM unsigned 8-bit, signed 16/24/32-bit, IEEE float32; mono/stereo; 8–192 kHz |
| Extensible WAV | PCM/float32 GUID; valid bits equal the stored width |
| Native FLAC | Mono/stereo, 4–24-bit, 8–192 kHz; constant/verbatim, fixed predictors 0–4, LPC 1–32, Rice partitions/escapes, wasted bits, all stereo decorrelation modes |
| MP3 Layer III | MPEG-1/2/2.5, all nine rates 8–48 kHz, mono/stereo, known bitrate CBR/ABR/VBR; reservoir, Huffman/linbits/count1, scalefactors, long/short/mixed blocks, MS/intensity stereo, hybrid/polyphase synthesis |
| MP3 metadata | Leading ID3v2.2/2.3/2.4 and trailing ID3v1 skipped; Xing/Info frame counts and encoder delay/padding used for single-file trimming |
| Ogg/Vorbis | Single Ogg v0 stream, CRC/sequence/continuation checks; mono/stereo 8–192 kHz, 64–8192 sample blocks; ordered/unordered/sparse codebooks, lookup 0/1/2, floor 1, residue 0/1/2, mapping 0, coupling/submaps, short/long overlap and final granule trimming |
| Ogg/Opus | Development components only; audio playback unavailable |

WAV ADPCM/RF64/RIFX, FLAC in Ogg, 32-bit FLAC, more than two channels, playlists, tag display, and device reconnection are unsupported. FLAC CRC8/CRC16 are checked; STREAMINFO MD5 and coded frame-number continuity are not checked. Tested FLAC depths are 16/24 bits, with less fixture coverage for the broader implementation range.

MP3 CRC headers/side information are checked. Free-format, Layers I/II, VBRI trimming, APE tags, arbitrary inter-frame junk and corruption recovery are unsupported. Missing reservoir dependencies reject input; rate/channel/version changes are unsupported. Untagged files keep encoder delay/padding. Metadata validation is incomplete; the declared trimmed duration can stop decoding before additional trailing frames.

Vorbis floor 0, chained/multiplexed Ogg, multichannel mappings, nonzero initial granule offsets, and corruption recovery are unsupported. The container is validated at open, so large files can take time to open. Packet reconstruction is bounded to 4 MiB. Setup reserves a bounded 64 MiB arena and commits 64 KiB increments as needed. Oversized headers/codebooks are rejected. Nonfinite reconstructed PCM is rejected. This is a prototype with substantial tests, not full format conformance certification.

## Playback and CPU design

A producer maps, parses and decodes files into a 2 MiB SPSC queue of 262,144 stereo float frames, about 5.46 seconds at 48 kHz. Playback starts with roughly 750 ms ready, or earlier at EOF. A render worker uses event-driven WASAPI shared mode, requests 200 ms endpoint buffering and registers with MMCSS as an Audio task. It makes no file reads, decoder calls, heap allocations, or application lock acquisitions during refill. Windows converts to the endpoint format when needed.

The UI message pump runs independently of both audio workers. Cancellation wakes paused waits. There is no audio polling, realtime process priority, or `timeBeginPeriod`. Queue publication relies on the x86 memory model. SSE2 is the x86-64 baseline; AVX is not required. Volume scaling is skipped at unity and vectorized otherwise.

MP3 synthesis uses factored SSE2 DCT butterflies. Vorbis inverse MDCT uses a positive-sign N-point complex FFT with paired SSE2 double-precision butterflies and precomputed windows/twiddles. A smaller transform formulation remains an optimization opportunity. Decoding reuses static buffers without per-frame heap allocation.

Input is mapped rather than copied into a heap. Static workspaces, the queue, committed setup pages, resident input pages, DIB pixels and Windows DLLs all contribute to RAM use; executable size is not a bound on working set.

The recorded Vorbis benchmark used **140,625 microseconds median process CPU** across five offline decodes of 30 seconds of seeded 48 kHz stereo noise at quality 8: about **0.47% of one core per second of audio** on this machine. This includes process setup and excludes audio rendering/UI; Windows accounting is coarse. The earlier MP3 result was about 0.21%. No VLC/mpv comparison has been performed.

Eight seconds of Vorbis silence under four bounded CPU workers completed with zero queue underruns and zero empty endpoint refills. Buffering/scheduling reduce stutters but cannot guarantee uninterrupted audio through arbitrary system, driver or storage stalls.

## Build

Install Visual Studio 2022 Build Tools with x64 tools and a Windows SDK:

```powershell
.\build.ps1
```

Runtime builds use `ml64.exe`, `link.exe`, Windows import libraries, custom entry points, and `/NODEFAULTLIB`. The console imports KERNEL32, ole32, SHELL32 and AVRT; the UI adds USER32, GDI32 and COMDLG32. Opus development objects are assembled but not linked into the players. Decoders are single-instance and called only by the producer during playback.

Generated tables and the application ICO are included. A normal build requires no reference C compiler. The Windows SDK resource compiler embeds the icon and version information. Preserve `THIRD_PARTY_NOTICES` with distributions.

## Verification

Recorded snapshots are in `reports/` in a source checkout. The paths below describe where the test scripts write fresh reports. Earlier CPU reports retain the executable sizes from before LAMP icon resources were added.

| Report | Coverage |
| --- | --- |
| `verification.json` | 43 WAV/FLAC checks, including exact reference PCM, malformed inputs and WASAPI silence |
| `mp3-verification.json` | 103 MP3 checks: 88 PCM comparisons, 14 rejection cases, WASAPI silence; recorded SNR above 112 dB |
| `bin/vorbis-verification.json` | 83 checks: 32 rate/channel/quality cases, noise/transients/silence, continued long comment, 36 synthetic residue/codebook cases, 10 rejections and WASAPI silence |
| `bin/engine-verification.json` | Playback, pause, resume, stop, reopen, seek and paused seek for all four working codecs |
| `vorbis-fuzz-verification.json` | 512 repaired-CRC setup/audio mutations without a crash/timeout; accepted audio correctness is not asserted |
| `vorbis-benchmark.json` | Five 30-second offline CPU measurements |
| `vorbis-stress-verification.json` | Eight-second WASAPI silence under four bounded CPU workers |
| `bin/opus-*-verification.json` | Exact primitive comparisons against the normative RFC source; not complete Opus audio validation |

Real Vorbis comparisons exceed 138 dB SNR, with peak error below 0.00000012. Synthetic lookup-2 fixtures use FFmpeg's libvorbis wrapper, which exposes signed 16-bit PCM; the threshold is 65 dB and two integer PCM LSBs. Recorded synthetic SNR exceeds 70 dB. Final counts follow the Ogg granule; the test handles FFmpeg's initial-delay/end-trim behavior explicitly.

Opus component tests cover 1,216,672 packet framing cases, 524,288 range operations, 90,678 CELT signed-pulse comparisons, 131,072 Laplace symbols, 12,288 energy-stage comparisons, 69,632 SILK shell trees and 24,576 excitation comparisons. Entropy states and normative float energy operations match exactly. These results do not imply Opus audio support.

The CELT suites add 271,160 exact allocation/entropy comparisons and 52,479 pulse-cache comparisons, 13,416 normalized pulse-vector/entropy comparisons, 15,864 spreading comparisons (including sixteen-block TF layouts), 8,192 renormalization comparisons, 3,280 Haar comparisons and 5,888 layout/inverse comparisons. Observed float error was zero in these tests; PVQ/spreading comparisons permit a 0.000003 absolute tolerance for platform libm differences. Guard tests check rejection before output/entropy writes.

The connected CELT band suite checks 75,104 recursive bands and 24,589 full spectral frames, including 8,205 frame prefixes and 13 real CELT frames. It compares 31,254,098 coefficients and exact entropy, budget, seed and allocation-balance state, plus 80 invalid requests. Observed coefficient error is zero; tolerances are 0.00001 for vectors and 0.00004 for scaled folding output. These are normalized spectral outputs, not decoded Opus PCM. Synthesis and complete Opus mode integration remain unfinished; [stage interfaces and limits](opus.md) document the current development code.

Synthesis-kernel suites add 21,632 anti-collapse and 21,632 denormalization frames, 12,288 inverse FFTs, 12,288 MDCT/TDAC transforms, 16,384 overlap frames, 29,792 comb filters and 24,576 stateful deemphasis/downsample frames. Tested outputs match the normative reference exactly; the independent 1,310,721-value exponent sweep permits and observes at most one float ULP. The suites check capacities, canaries, rejected-request non-mutation, frame-size/long/transient changes and persistent filter memory.

The stateful CELT suite connects these stages into frame-to-float-PCM decoding and loss/recovery: 30,736 successful frames (4,090 concealed) and 115,916,510 PCM/history values with zero observed error (scale-adjusted tolerance 0.00004), 311 strict entropy rejections with sticky failure/reset, and 59 public guards. It includes real frames and generated/modified/truncated payloads, initial loss, pitch/noise concealment bursts and recovery, channel conversion, all frame sizes/output rates/bandwidths, high-band starts and primed entropy. Separate prediction/pitch suites add 3,072 autocorrelations/LPC solves, 49,152 stateful filter frames and 3,920 pitch searches with zero observed error.

SILK suites add 98,304 side-information/state frames connected to excitation, 583,808 gain/state frames, 264,932 pitch/LTP frames, 45,056 decoded NLSF vectors and 12,288 stabilization vectors. All integer outputs, weights, residuals and entropy states match the normative reference exactly. NLSF tests retain 166 extreme vectors whose reference result violates range/spacing and verify rejection before LPC conversion.

Fixed-point SILK LPC tests cover 749,568 reciprocals, 16,640 bandwidth expansions, 104,391 inverse prediction gains and 71,623 NLSF-to-LPC vectors. The complete parameter stage checks 129,360 stateful frames (32,768 connected side-information requests), including 72,041 interpolated, 22,006 reset and 32,335 loss-recovery frames. All controls and history match exactly; 1,712 invalid NLSF results fail atomically.

SILK prediction helpers add 520,924 exact divisions and 24,576 analysis/rewhitening filters. The inverse-NSQ core compares 20,480 source-rate mono PCM/history frames, including 8,192 connected index/pulse/parameter frames, 38,304 gain changes and 1,722 voiced-loss-to-unvoiced blends. All 3,686,080 int16 PCM samples and 16,793,600 history values match the reference exactly; extreme pulses/history exercise clipping and wrap arithmetic. These core sequences exclude full PLC/CNG and stereo framing.

Decoder resampling adds 32,640 exact PCM/history frames across all fifteen internal/API-rate pairs, including 3,840 connected core frames. Raw up2/AR2, delay compensation, 1–60 ms blocks, full-range integer input/history and 53 guards are covered. The reference fractional upsampler copies an unused uninitialized FIR-state tail; the oracle excludes only that reference tail, and verifies deterministic preservation of LAMP's unused state with different scratch fills.

Comfort noise adds 58,368 exact PCM/history frames, including 8,706 parameter updates, 39,936 lost frames, 14,592 rate resets and 9,216 connected core/CNG/48 kHz resampling frames. It checks the entire CNG state, 5,150,475 int16 PCM samples, unused history preservation, immutable core/parameter/control inputs and 27 guards. Lost-frame tests in that suite isolate CNG.

The PLC suite adds 16,384 energy vectors, 43,008 exact PLC/core/control frames (25,984 concealed), 75,776 recovery-glue frames (7,463 faded) and 63 guards. Sequences cover 9,728 rate resets, voiced/unvoiced repeated loss, gain/tap extremes, padding preservation and 18,432 connected core/PLC/glue/CNG/48 kHz resampling frames. All 17,637,024 int16 PCM comparisons and 36,685,824 history values match exactly.

Stereo adds 153,572 predictor/mid-only entropy comparisons, all 11,250 predictor-codebook/flag combinations, 90,112 exact PCM/history frames (65,536 connected decoded predictors), 32,440,240 int16 samples and 34 guards. It covers every internal rate, 10/20 ms frames, interpolation, changing predictors, full-range histories and clipping.

The complete source-rate channel frame suite calls unchanged `silk_decode_frame`: 67,589 exact entropy-to-PCM/history frames include 28,160 lost, 10,752 FEC, 10,240 recovered and 18,432 continued-entropy frames. It checks 5,575 initializations, 10,752 configurations, 7,936 rate changes, 12,166,840 int16 PCM samples and every byte of channel history. Five injected late component failures verify sticky rejection and explicit reset; 63 public guards reject before writes.

Packet-header tests extract the unchanged VAD/LBRR/skip block from `dec_API.c` in the hash-verified archive. They compare 24,577 complete metadata/entropy/history headers, 11,517 skipped FEC frames (3,332 conditional, 3,784 stereo predictors, 1,443 mid-only flags), 21,504 connected mono header/frame PCM cases, one late/sticky/reset case and 38 guards. Inactive flags/history remain unchanged.

The complete SILK API suite calls `silk_Decode` across all internal/output-rate pairs, channel layouts and packet durations. It compares entropy, every PCM sample, channel/stereo/packet state and all defined resampler history; it also runs assembly twice with different scratch fills and compares the entire resulting assembly state. Output-rate changes during stereo collapse explicitly reset the inactive right resampler in both implementations to avoid the RFC copying a new-rate sample count from old-rate output. All other cases use the unchanged reference API. Only unused uninitialized reference up-FIR history is excluded, as in the resampler suite.

The full mode oracle includes unchanged `opus_decoder.c`/`celt.c` and generates packets with the normative Opus encoder. It compares 19,204 frames (5,825 SILK, 5,322 hybrid, 7,997 CELT), 77,582,264 float PCM/history values and exact defined SILK history. It covers all 32 TOC configurations, five API rates and every mono/stereo conversion, 1,160 mode transitions, 446 CELT-to-SILK and 489 SILK-to-CELT redundant frames, 3,660 lost frames and 1,973 FEC calls. All tested float errors are zero at scale-adjusted tolerance 0.00004. Distinct-scratch assembly calls produce identical complete states and PCM. A bandwidth transition exposed empty high-band PLC; the implementation now reproduces the reference's zero spectrum while preserving overlap and random history. Tests add 2,048 malformed packets, 49 public guards and 74 strict rejection/sticky/reset cases.

Complete normal packet dispatch adds 18,381 exact PCM/history calls across four framing codes, padding, up to 48 frames/120 ms, all 32 TOC configurations, five API rates and channel layouts, 2,560 losses, 5,196 FEC calls and 5,120 zero/one-byte DTX packets. It compares 25,775,010 float output samples, tests 2,048 malformed packets (1,588 rejections), 26 public guards and sticky failure/reset. A reference-call observer records intermediate CELT entropy errors that a later frame/reset can clear; LAMP rejects them immediately. Thirty-three suites pass; player/Ogg integration, mapping/gain/trimming and official conformance remain required.

The UI preview uses the actual assembly renderer with synthetic playback state. **Desktop window interaction, open-dialog/drop behavior and monitor-DPI changes remain unverified** because the permitted desktop automation runtime was unavailable. Audio controls are tested separately by a native assembly harness.

FFmpeg and Node.js are needed only for test fixture generation/comparison. Opus oracle tests also compile the bundled BSD reference into test executables; neither player calls them or links their objects.

```powershell
.\tests\verify.ps1
.\tests\verify-mp3.ps1
.\tests\verify-vorbis.ps1
.\tests\verify-engine.ps1
.\tests\stress.ps1 -Codec vorbis
.\tests\benchmark.ps1 -Codec vorbis
node .\tests\fuzz-vorbis.js
.\tests\verify-opus-range.ps1
.\tests\verify-opus-packet.ps1
.\tests\verify-opus-cwrs.ps1
.\tests\verify-opus-energy.ps1
.\tests\verify-opus-silk-pulses.ps1
.\tests\verify-opus-allocation.ps1
.\tests\verify-opus-vq.ps1
.\tests\verify-opus-band-transform.ps1
.\tests\verify-opus-controls.ps1
.\tests\verify-opus-theta.ps1
.\tests\verify-opus-components.ps1
.\tests\render-ui.ps1
```

The RFC reference archive is checked against its normative SHA-1 before extraction. `tests\generate-opus-tables.js` extracts probability data only. Fixtures stay in `tests\generated`; extracted reference source stays in `tests\reference\opus-rfc6716`. The stress test bounds worker count/duration and cleans up workers in `finally`.

## Remaining implementation

Connect Opus packets to Ogg/player integration, channel mapping, pre-skip/gain/end trimming and official audio-vector validation. Further work includes indexed seeking, multichannel/chained streams, device changes, and same-machine CPU/RAM comparisons against existing players.

## References

- [Rhun and its assembly UI documentation](https://github.com/vshvedov/rhun)
- [Vorbis I specification](https://xiph.org/vorbis/doc/Vorbis_I_spec.html)
- [Ogg framing, RFC 3533](https://www.rfc-editor.org/rfc/rfc3533.html)
- [Opus and normative reference, RFC 6716](https://www.rfc-editor.org/rfc/rfc6716.html)
- [Ogg Opus mapping, RFC 7845](https://www.rfc-editor.org/rfc/rfc7845.html)
- [FLAC, RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.html)
- [WASAPI](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize)
- [Windows MMCSS](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service)

Original project code is MIT licensed. Adapted algorithms/data retain required MIT-0, MIT, CC0 and BSD notices. The project's MIT license does not replace them.
