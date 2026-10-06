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

On Windows, the milestone comparison gate remains open pending wakeup measurements and shipping-GUI verification; the [Linux comparison](#linux) measures wakeups. Accurate audible latency needs additional endpoint/loopback instrumentation.

## Linux

The [Linux comparison](../reports/linux-playback-benchmark.json) was recorded on 2026-10-06 in a cloud container: an Intel Xeon at 2.10 GHz with 4 logical processors and Linux 6.18. It measures the static `lamp-cli` 0.4.0-dev, mpv 0.37.0 and VLC 3.0.20 playing the same two-minute files through one private PulseAudio 16.1 server into a float32 48 kHz null sink. The files are seeded noise at 48 kHz: PCM16 WAV, FLAC, MP3 320 kb/s, Vorbis q8, Opus 128 kb/s and AAC 256 kb/s.

- **Measuring at the sink:** the controller records the sink's monitor, so times are observed where the audio arrives, not taken from each player's clock. PulseAudio rewinds the null sink for new audio, so the monitor shows audio as soon as a client writes it. The times below are therefore times until the server has the player's audio, without any device latency. `paplay`, PulseAudio's own minimal client, needs 4.2 ms (11.8 ms under load), the floor of this method.
- **The players:** all three run as the unprivileged user `nobody` (VLC refuses root), each separately.
  - LAMP is driven by keys on a pseudo-terminal.
  - mpv runs without configuration or video and is driven over JSON IPC.
  - VLC runs its rc interface, driven on stdin.
- **Startup:** the time from starting the process to the first sound at the sink, the median of five runs.
- **Seek:** a file of 30 s of silence and then noise plays from its start. 3 s in, the player seeks 60 s on (LAMP's Up, mpv's relative seek, VLC's absolute seek), and the time is to the first sound, the median of five seeks in one process. LAMP restarts its stream for a seek; mpv and VLC flush theirs.
- **Resources:** CPU time from `/proc`, over ten seconds playing and then ten seconds paused, as a percentage of one core. Wakeups are the voluntary context switches of all the process's threads, per second. Memory is resident and anonymous (private) memory at the end of the playing window.
- **Load:** "four workers" adds four busy processes, which saturate all four logical processors.

Medians, in ms, of startup and seek:

| Codec | Condition | Startup: LAMP | mpv | VLC | Seek: LAMP | mpv | VLC |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| WAV | Baseline | 5.0 | 97.8 | 79.3 | 0.7 | 0.8 | 1.2 |
| FLAC | Baseline | 9.6 | 92.9 | 90.4 | 5.7 | 0.8 | 3.7 |
| MP3 | Baseline | 15.0 | 100.1 | 83.7 | 5.8 | 9.5 | 29.9 |
| Vorbis | Baseline | 25.0 | 107.7 | 79.5 | 10.5 | 0.8 | 3.1 |
| Opus | Baseline | 20.1 | 93.0 | 79.6 | 6.9 | 0.8 | 12.1 |
| AAC | Baseline | 22.3 | 99.8 | 81.2 | 0.7 | 0.8 | 12.4 |
| WAV | Four workers | 31.0 | 198.8 | 155.9 | 0.5 | 4.3 | 4.4 |
| FLAC | Four workers | 38.1 | 184.1 | 158.9 | 7.1 | 4.1 | 11.7 |
| MP3 | Four workers | 42.5 | 178.0 | 168.2 | 10.3 | 12.8 | 30.4 |
| Vorbis | Four workers | 50.0 | 177.1 | 167.2 | 14.7 | 8.2 | 1.2 |
| Opus | Four workers | 50.0 | 170.9 | 151.5 | 12.8 | 3.0 | 16.3 |
| AAC | Four workers | 51.3 | 177.9 | 160.4 | 0.7 | 1.9 | 20.2 |

Playing, per process: CPU (% of one core), wakeups per second and memory (MiB) at baseline:

| Codec | CPU: LAMP | mpv | VLC | Wakeups: LAMP | mpv | VLC | Resident: LAMP | mpv | VLC | Private: LAMP | mpv | VLC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| WAV | 0.2 | 2.6 | 0.8 | 20.7 | 410.4 | 86.4 | 5.5 | 60.5 | 52.1 | 2.0 | 17.6 | 13.6 |
| FLAC | 0.3 | 1.5 | 1.2 | 20.7 | 241.1 | 57.7 | 3.9 | 60.4 | 51.3 | 2.1 | 17.6 | 12.3 |
| MP3 | 0.3 | 2.4 | 2.2 | 20.7 | 375.9 | 146.2 | 7.0 | 61.2 | 50.9 | 2.2 | 18.1 | 11.6 |
| Vorbis | 0.8 | 2.4 | 1.4 | 20.5 | 389.8 | 80.0 | 5.6 | 61.8 | 50.6 | 2.6 | 18.3 | 11.6 |
| Opus | 0.6 | 2.6 | 1.7 | 20.7 | 395.2 | 81.3 | 3.8 | 61.3 | 50.5 | 2.2 | 18.3 | 11.3 |
| AAC | 0.4 | 2.8 | 1.5 | 20.7 | 394.2 | 82.1 | 3.3 | 61.9 | 51.0 | 2.4 | 18.8 | 11.7 |

Under load, CPU per player stays within 0.2–0.6% for LAMP, 0.9–1.9% for mpv and 0.3–1.5% for VLC. Wakeups rise to 263–459 per second for mpv and 65–168 for VLC; LAMP stays at 20.7. Paused, LAMP does not wake at all, against 0.8–1.9 wakeups per second for mpv and VLC. All three use 0.1% CPU or less while paused.

The server's own CPU (0.9–3.2%) and wakeups (587–781 per second) barely differ between players. They are dominated by the null sink and the controller's 5 ms monitor capture. LAMP's resident memory includes the mapped input file.

- **How LAMP's wakeups are low:** it asks the server for audio in quarters of its 200 ms buffer, and its decoder refills its 5.46 s ring only once a quarter has played. Before these settings, it woke 100 times a second while playing.
- **What these results do not say:** they are single runs on one shared machine, CPU accounting is in 10 ms ticks, and startup and seek include no device latency. They do not establish audible latency, listening quality or a general ranking.

Reproduce with `python3 tests/benchmark-linux.py`. It needs PulseAudio, `setpriv`, mpv and VLC (Ubuntu's `vlc-bin` and `vlc-plugin-base`). `--runs`, `--seconds`, `--formats`, `--players` and `--workers` bound a run, and results go to `build/linux-playback-benchmark.json`.

## Measurement references

- [mpv stable manual: JSON IPC, playback events, audio properties and WASAPI](https://mpv.io/manual/stable/).
- [VLC 3.0.24 HTTP command/state implementation](https://github.com/videolan/vlc/blob/3.0.24/share/lua/intf/modules/httprequests.lua), [MMDevice backend](https://github.com/videolan/vlc/blob/3.0.24/modules/audio_output/mmdevice.c), [WASAPI stream](https://github.com/videolan/vlc/blob/3.0.24/modules/audio_output/wasapi.c).
- [VideoLAN portable Windows binaries and checksum files](https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/).
- Microsoft [GetProcessTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [GetProcessMemoryInfo](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo) and [GetSystemTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes).
