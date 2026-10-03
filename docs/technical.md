# LAMP 0.3.0 technical details

A Windows x86-64 audio player with handwritten assembly WAV, FLAC, MP3, and Ogg/Vorbis decoders, plus a native assembly UI. The branded console executable is **102,400 bytes (100 KiB)**; the graphical executable is **110,080 bytes (107.5 KiB)**. Both include LAMP's icon and version resources. Exact packaged sizes and hashes are in the release `manifest.json`.

The dark canvas, compact playback controls and automatic hiding are inspired by mpv. The custom pixel buffer and Win32 presentation follow Rhun's documented assembly UI model. No Rhun source, fonts, icons, or other assets were copied.

**Opus playback is unfinished.** Tested assembly components cover packet framing, range decoding, CELT signed-pulse enumeration and energy reconstruction, and SILK shell/excitation reconstruction. They are not a complete audio decoder and are not linked into either player. Full CELT shape/allocation/transform reconstruction, SILK prediction/synthesis/resampling, hybrid transitions, and PCM integration still need implementation and audio-vector validation. An `.opus` file is rejected.

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
.\tests\render-ui.ps1
```

The RFC reference archive is checked against its normative SHA-1 before extraction. `tests\generate-opus-tables.js` extracts probability data only. Fixtures stay in `tests\generated`; extracted reference source stays in `tests\reference\opus-rfc6716`. The stress test bounds worker count/duration and cleans up workers in `finally`.

## Remaining implementation

Complete Opus CELT shape/bit allocation/transform reconstruction and SILK parameter/prediction/synthesis/resampling, then hybrid switching, pre-skip/gain/end trimming and official audio-vector validation. Further work includes indexed seeking, multichannel/chained streams, device changes, and same-machine CPU/RAM comparisons against existing players.

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
