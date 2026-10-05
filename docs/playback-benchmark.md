# Playback benchmark

The [recorded playback comparison](../reports/playback-benchmark.json) passes all 30 player/format/load scenarios on an i7-12700KF (12 cores/20 logical processors), Windows 11 build 26200, on 2026-10-04. It measures LAMP 0.4.0-dev's assembly WASAPI engine, mpv 0.41.0 and VLC 3.0.24 using identical ten-minute audio fixtures. Startup, reopen and seek observations, process CPU, working set and private bytes are recorded, with no deliberately added load and with four bounded CPU workers. Pause, paused seeking and resume pass; LAMP reports no queue underruns or empty-endpoint events in these measured checks. The player binaries and assembly objects are unchanged by the benchmark work.

## Recorded resource snapshots

The following percentages are single eight-second noise-playback windows, expressed as one-core equivalents. `BR` means below Windows accounting resolution for that window. These are observations on a busy machine, with no confidence interval or general performance ranking. Whole-system busy time ranges from 18–40% in the baseline windows and 37–58% with the four workers.

| Codec | Condition | LAMP bridge CPU (%) | mpv CPU (%) | VLC CPU (%) |
| --- | --- | ---: | ---: | ---: |
| WAV | Baseline | BR | 0.59 | 1.17 |
| FLAC | Baseline | 0.78 | 1.76 | 1.56 |
| MP3 | Baseline | BR | 3.70 | 1.56 |
| Vorbis | Baseline | BR | 0.59 | 0.78 |
| Opus | Baseline | 2.15 | BR | BR |
| WAV | Four workers | BR | 1.56 | 1.56 |
| FLAC | Four workers | 0.39 | 0.39 | 0.39 |
| MP3 | Four workers | 0.39 | 0.59 | 2.53 |
| Vorbis | Four workers | BR | 3.71 | 0.59 |
| Opus | Four workers | 1.17 | BR | 3.31 |

Working set at the end of the baseline noise window, in MiB:

| Codec | LAMP bridge | mpv | VLC |
| --- | ---: | ---: | ---: |
| WAV | 15.88 | 47.98 | 58.13 |
| FLAC | 17.28 | 48.93 | 59.91 |
| MP3 | 36.64 | 48.49 | 56.70 |
| Vorbis | 27.08 | 48.73 | 67.20 |
| Opus | 19.24 | 48.06 | 62.70 |

The report includes loaded working sets, private bytes and every paused/idle window. Paused/idle CPU deltas are often below accounting resolution, with nonzero samples retained. LAMP's per-codec median seek queue-ready observations span 47–77 ms across both conditions. Its median time to observe a clock 100 ms past the seek target spans 151–171 ms, including that 100 ms of playback. Comparator timing fields remain separate because their clocks and readiness signals have different meanings, as described below. These figures exclude the shipping GUI and physical/audible output latency.

## What the test measures

LAMP runs its existing assembly engine in a test-only C command bridge. The bridge has a C runtime and no GUI. mpv runs without configuration, video or terminal output, controlled through JSON named-pipe IPC. VLC runs its dummy interface without configuration or video, controlled through authenticated HTTP on a unique loopback port. All three use Windows shared audio output. mpv is required to report `current-ao=wasapi`; VLC uses `mmdevice` with the `wasapi` backend. Each player runs separately. The controller starts and stops only its own subprocesses.

Players remain at volume zero while decoding the noise fixtures. Each selects its default Windows output; format conversion and mute/mixing paths can differ. These are headless engine results, not measurements of the shipping GUI, listening quality, exclusive output or audio-driver cost in other processes. LAMP bridge RAM includes the test C runtime and resident mapped input; it is not the working set of `lamp.exe`.

The baseline retains normal background user processes. It means no extra benchmark load, rather than an idle machine. The loaded condition adds four independent Node CPU workers; it does not simulate a disk stall or prove resistance to arbitrary scheduling/driver delays. Each resource window records whole-system busy time so the actual background load remains visible.

CPU windows last eight seconds for noise playback, pause and idle after stop. The controller takes process/system snapshots before and after, without polling the player during the window. CPU percentages represent one logical core: 100% means one core continuously executing, not the whole 20-thread machine. Windows process CPU accounting is coarse. A reported zero delta means below the accounting resolution for that interval, not zero CPU work. Working set and private bytes are snapshots, not peaks or total system memory cost. Wakeups are explicitly unmeasured; CPU time or context switches cannot substitute for wakeup counts.

## Timing observations

Three runs open/reopen each file and seek to 84, 300 and 564 seconds. Each seek is absolute; mpv requests exact seeking. VLC uses an absolute percentage calculated from its known duration (14/50/94% in these files). Its [HTTP seconds path](https://github.com/videolan/vlc/blob/3.0.24/share/lua/modules/common.lua) can use a bitrate estimate in the [Ogg demuxer](https://github.com/videolan/vlc/blob/3.0.24/modules/demux/oggseek.c); the percentage path uses indexed/bisect positioning for local Ogg. A [diagnostic seconds request](../reports/vlc-http-seconds-diagnostic.json) for 84 seconds reported 133.3 seconds when the 15-second target-observation timeout expired, so that path is excluded from timing comparisons. LAMP implements a seek by stopping/joining its old worker and reopening, as the GUI currently does. Inputs use warm filesystem data, with no deliberate cache eviction. Fixtures and executable/object hashes are recorded.

The controller records command acknowledgement, first observed readiness and first reported playback position at least 100 ms past the requested target. It polls with a five-millisecond delay between requests; IPC/HTTP processing and scheduling add overhead. Readiness has different meanings:

- LAMP's `engine_ready` means its roughly 750 ms PCM prebuffer is ready, before the first WASAPI refill and `Start`.
- mpv's `playback-restart` event indicates playback restarting after load or seek.
- VLC's HTTP playlist state says playing or paused; it does not establish render readiness.

Progress clocks also differ. LAMP subtracts WASAPI padding from submitted frames. mpv's `audio-pts` includes audio-driver delay. VLC exposes fractional input position, multiplied here by its integer duration because its HTTP `time` field is floored to whole seconds. Paused target checks allow 10 ms for LAMP/mpv and 100 ms for VLC's compressed-frame boundary, recording the actual signed offset. This benchmark does not establish sample-accurate seeking; independent decoder suites cover LAMP's PCM positioning. The test verifies stable reported clocks during pause and paused seeking, then progress after resume. It does not measure physical output or prove these clocks correspond to identical audible latency. Do not rank these timing fields as equivalent end-to-end latency results.

## Reproduce

Install LLVM and Python (to build the players), Visual C++ (for the test-only benchmark bridges), Node.js and FFmpeg. Supply existing mpv and VLC Windows executables; the player does not need either program. The recorded VLC comparator is the portable VideoLAN build, kept outside the package in ignored `bin/reference-tools` and verified against VideoLAN's SHA-256 file.

```powershell
.\build.ps1 -OutputDirectory .\bin\verify-build
.\tests\benchmark-seek.ps1 -OutputDirectory .\bin\verify-build -ReuseFixtures
.\tests\benchmark-playback.ps1 -OutputDirectory .\bin\verify-build `
  -MpvPath 'C:\Tools\mpv\mpv.exe' -VlcPath 'C:\Tools\VLC\vlc.exe'
```

The decoder benchmark prepares the 600-second fixtures: 48 kHz stereo independent seeded noise, repeating 20 seconds of silence and 40 seconds of noise. Encodings are PCM16, native FLAC, MP3 320 kbps, Vorbis quality 8 and Opus 128 kbps. Playback benchmarking does no simultaneous encoding. Results go to `bin/verify-build/playback-benchmark.json`, updated after each completed check; failures retain an incomplete report and separate per-player logs. `-Runs`, `-SampleSeconds`, `-LoadWorkers`, `-Codecs` and `-Players` allow bounded diagnostic runs. `-VlcSeekMode seconds` reproduces the alternate HTTP seek path. Such runs must retain their actual parameters when published.

The milestone comparison gate remains open pending wakeup measurements and shipping-GUI verification. Accurate audible latency needs additional endpoint/loopback instrumentation.

## Measurement references

- [mpv stable manual: JSON IPC, playback events, audio properties and WASAPI](https://mpv.io/manual/stable/).
- [VLC 3.0.24 HTTP command/state implementation](https://github.com/videolan/vlc/blob/3.0.24/share/lua/intf/modules/httprequests.lua), [MMDevice backend](https://github.com/videolan/vlc/blob/3.0.24/modules/audio_output/mmdevice.c), [WASAPI stream](https://github.com/videolan/vlc/blob/3.0.24/modules/audio_output/wasapi.c).
- [VideoLAN portable Windows binaries and checksum files](https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/).
- Microsoft [GetProcessTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [GetProcessMemoryInfo](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo) and [GetSystemTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes).
