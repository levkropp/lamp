# Output devices

Device enumeration/selection and `--rate device` below currently apply to Windows and Linux. The Mac CLI supports `--rate HZ` through the shared resampler and uses the default Core Audio output; its device controls remain pending. See [Mac coverage](macos.md).

`lamp-cli` plays on the system's default output unless `--device` names another one:

```sh
$ ./build/lamp-cli --list-devices
0	alsa_output.pci-0000_00_1f.3.analog-stereo	Built-in Audio Analog Stereo
1	bluez_sink.00_11_22_33_44_55.a2dp_sink	Headphones
$ ./build/lamp-cli --device Headphones album/*.flac
```

`--list-devices` prints one line per output: its number, its name and its description, separated by tabs.

| Platform | Number | Name | Description |
| --- | --- | --- | --- |
| Linux | PulseAudio sink index | Sink name | Sink description |
| Windows | Position among the active render endpoints | Endpoint ID | Friendly name |

On Linux the list comes from the sound server's sink list; LAMP's own PulseAudio client reads it, with no libpulse. On Windows it comes from WASAPI's active render endpoints.

`--device` (playback only) takes any of the three:

- An exact name or description.
- The output's number.

An output that matches none of them prints `Unknown audio device` and exits with code 3 before playing.

In the Windows player (`lamp.exe`) the context menu chooses the output:

- **Opening it:** right-click the window, or press Shift+F10 or the menu key.
- **Output submenu:** it lists `Default output` and each active render endpoint by friendly name, the one playing checked.
- **Choosing one:** playback continues on it from the file heard, at the heard position. The choice holds for the files played after it, until another is chosen.
- **Enumeration:** the menu lists endpoints with its own enumerator, so it never touches the stream playing.

## Rates and channels

Shared mode is the default. Current Windows source builds offer [`--exclusive`](exclusive-output.md) in the CLI and **Output mode** in the window, with exact-rate negotiation, float/integer stereo packing, device-clock position/draining and separate native component/playback reports. Exclusive mode reserves the selected endpoint.

In shared mode, LAMP never reconfigures an output. Its stream is float32 stereo at the session rate:

- **Session rate:** by default, the first file's rate. Later files at another rate pass through LAMP's windowed-sinc resampler (see [queue notes](queue.md)).
- **Output conversion:** when the session rate differs from the output's, the sound server converts it with its own resampler. That is PulseAudio's configured method (PipeWire's on PipeWire), or the Windows audio engine's sample-rate converter at default quality.
- **`--rate HZ`:** makes HZ the session rate. Every file, the first included, passes through LAMP's resampler: at least 90 dB stopband attenuation, checked against `tests/resample-oracle.c` sample for sample.
- **`--rate device`:** uses the output's own rate, so the server or engine passes the stream through unresampled. That is the PulseAudio sink's sample rate (the default sink, or `--device`'s, asked by name), or the WASAPI endpoint's shared-mode mix rate. When the rate cannot be read, the first file's rate stays.
- **Where `--rate` applies:** `--check` and `--decode` take `--rate HZ` but not `device`; the tag, chapter, cover and device listings take neither.
- **Channels:** every file is mixed to stereo with the shared [speaker weights](flac.md#stereo-policy); native surround output remains open.

Seeking in a resampled file is exact. The decoder seeks a filter half-width before the target's input span, and the resampler restarts there, so the output from the target on equals continuous decoding.

## Following the Windows default output

Windows console and graphical playback now subscribe to `IMMNotificationClient` when using **Default output**. A change to the default render endpoint for the console role (the role used to open WASAPI) wakes the playback owner, which reopens the queue in the heard file at its recorded millisecond position. Paused playback stays paused; active playback resumes after prebuffering. Notifications received during startup are checked before starting the client. This is a restart, not a seamless handoff or a latency guarantee.

An explicitly selected endpoint remains pinned. Capture-device changes, other endpoint roles and property/state notifications do not cause a default-output restart. If a selected endpoint disappears and the existing recovery path falls back to the default, subsequent default changes are followed. The CLI retains its session rate across automatic restarts; `--rate device` chooses the initial output's rate, and Windows converts in shared mode when a later output has a different mix rate. The graphical player resolves its configured rate for each new worker as described below. Exclusive mode keeps its explicit request and reports an error if the new endpoint cannot accept the resulting rate. Linux/Mac following behavior remains separate platform work.

The original assembly callback in `src/win/output_notifications.s` only sets a coalescing flag and signals the audio event. It does not allocate, wait, decode or call COM. The playback owner consumes the flag, preserving an already pending user command. During cleanup it detaches the event, unregisters the static callback and drains in-flight signalers before the event can close. This avoids signaling a stale or recycled handle. Registration failure leaves the existing invalidated-endpoint recovery available.

### Native notification checks

```powershell
python tools/build-windows.py --out bin/default-check --tests --probe-default-device
.\tests\verify-windows-notifications.ps1 -OutputDirectory .\bin\default-check -Playback
```

Normal builds require LLVM/Python. The optional oracle also needs Visual Studio x64 C++ Build Tools, a Windows SDK and FFmpeg; playback checks need a working default endpoint. The [native report](../reports/windows-notifications-verification.json) passes 6,102 callback/ownership checks, including 2,000 lifecycles, 1,000 concurrent teardowns, callbacks during unregister, registration replacement/failure and 32 registrations with Windows' real enumerator. Mock notifications exercise role filtering, explicit selection, coalescing and late callbacks without changing the system output.

Six native WASAPI scenarios add silent WAV, FLAC, MP3, Vorbis, Opus and AIFF playback. Each injects the callback into its own process during paused and active playback, requires the restart command and exact captured millisecond position, and reopens through the same engine entry point while checking pause retention or renewed progress. A pending user seek command and its paired file/time snapshot must survive a notification unchanged. Existing pause/resume, stop/reopen, indexed/paused seek and cancelled-open checks also run. This verifies the callback-to-restart path; moving between two physical devices, loopback PCM accuracy across such a move, actual handoff latency and default changes in dense queues remain unverified. No system output selection or desktop input is changed by these tests.

## Windows output mode and rate controls

The context menu (right click, Shift+F10 or the menu key) offers:

- **Output mode:** Shared (other apps can play), the default, or Exclusive
  (reserve this output). Exclusive mode keeps ownership while paused; choosing
  Shared releases it through the worker restart.
- **Output sample rate:** First opened file, Device mix rate, or fixed
  8,000/11,025/12,000/16,000/22,050/24,000/32,000/44,100/48,000/88,200/96,000/
  176,400/192,000 Hz. LAMP's assembly resampler converts files to the chosen
  session rate. These are session choices, not persisted preferences.
- **Output:** the existing default or explicit endpoint selection.

A mode, rate or endpoint change reopens the heard file at its millisecond
position and preserves pause. A running worker finishes before the new one
applies settings. Changes made while it is stopping update the next settings
without replacing an already pending seek, chapter, track or list request.
Selecting the same mode or rate does not restart playback.

Each launch captures immutable mode/rate choices. The playback owner applies
them before opening the queue; a device-mix-rate query runs on that worker,
not the window thread. **First opened file** uses the first file opened by
that new worker, including a restarted heard file. **Device mix rate** queries
the selected endpoint again for each worker, including output recovery.
Fixed rates stay fixed. Heard positions are carried in milliseconds when a
restart changes the rate. CLI automatic-restart rate policy is separate.

Exclusive output still requires an accepted exact-rate stereo representation;
the device mix rate is not guaranteed to be accepted. An audio error gives a
mode-specific title and hint. Choosing Shared or a different rate after an
error retries the same file and position while retaining pause. File/decoder
errors retain their generic guidance. No failed exclusive initialization
silently changes mode. See [exclusive limits](exclusive-output.md).

### Native GUI output checks

```powershell
python tools/build-windows.py --out bin/ui-output-check --tests --probe-ui-output
.\tests\verify-windows-ui-output.ps1 -OutputDirectory .\bin\ui-output-check -Playback -UnsupportedRate 44100
```

The oracle needs Visual Studio x64 C++ Build Tools and a Windows SDK. Playback
also needs FFmpeg and a default endpoint supporting exclusive stereo at 48 kHz;
it acquires that endpoint and plays silence. The optional `-UnsupportedRate`
must name a menu rate known to reject on the test endpoint; omit it if 44.1 kHz
is supported. Omit `-Playback` for menu/ownership/error-text checks without
opening an audio stream.

The [recorded native report](../reports/windows-ui-output-verification.json)
passes 8,269 checks. It covers all 30 mode/rate configurations, actual Win32
labels/IDs/checks, 64 menu create/destroy cycles with no leaked USER handles,
1,000 rapid staged-change iterations, immutable worker choices, pending
request retention and error guidance. A test-only assembly wrapper includes
the shipping UI source; its object stays outside decoder-library object lists.

An owned hidden window runs the real window procedure, worker and WASAPI
engine on a silent 44.1 kHz 5.1 FLAC source. Native `WM_COMMAND` messages to
that window switch shared/exclusive output, fixed 44.1/48 kHz, device rate and
the default endpoint. Pause and heard milliseconds survive those restarts.
Synthetic default-output callbacks exercise paused and active GUI recovery;
an unsupported 44.1 kHz exclusive stream shows the specific error and recovers
paused at 48 kHz. The test closes its own window and worker. It never shows
the window, searches for another application, sends desktop input or changes
the system default. Physical handoffs, interactive popup/screen-reader use,
mixed-monitor DPI behavior and loaded-system/long-run performance remain open.

## Losing the output

LAMP reopens the output when it fails during console playback:

- **What counts as a failure:**
  - On Linux, the server kills the stream or fails it after it started.
  - On Windows, WASAPI reports the endpoint invalidated (`AUDCLNT_E_DEVICE_INVALIDATED`), or sends no callback for two seconds.
- **What LAMP does:** it prints `Audio output lost; reopening.` and opens a new stream in the file being heard, at the heard position. It uses navigation's restart (see [queue notes](queue.md)).
- **When the chosen output is gone:** a `--device` output that can no longer be activated is replaced by the default output from then on.
- **When nothing can be reopened:** when no output opens at all, playback ends with the usual audio error (exit code 3).

Removing a PulseAudio sink normally moves its streams to another sink, and playback simply continues there. The Windows player (`lamp.exe`) reopens a lost endpoint the same way, in the file heard at the heard position, and falls back to the default output when the chosen one is gone ([player check](../reports/player-verification.json)).

## Verification

`python3 tests/verify-rate.py` ([report](../reports/rate-verification.json)) checks `--rate`:

- `--decode --rate 48000` of 44.1 kHz FLAC, WAV, MP3, Vorbis and AAC equals the resampler oracle applied to each file's own decode. `--rate` at a file's own rate changes nothing, and a 44.1/48/96 kHz list resamples each file but the 48 kHz one.
- `--start` in resampled files reads exactly from the start, and `--check` counts the resampled frames. Eight malformed or misplaced `--rate` arguments print the usage.
- `--rate device` on the private 48 kHz sink plays a 44.1 kHz file bit for bit as `--decode --rate 48000` gives it, reporting `rate=48000`. Right seeks 5 s within it, and on a 44.1 kHz sink chosen with `--device` it reports `rate=44100`.
- `--wine` runs the same with `lamp-cli.exe` ([report](../reports/rate-wine-verification.json)). Its decodes are exact, and its playback is compared by order.

`python3 tests/verify-devices.py` ([report](../reports/devices-verification.json)) loads two null sinks into a private PulseAudio server beside the default `lamp_test` sink, then checks:

- `--list-devices` lists the three sinks with their names and descriptions.
- `--device` by name, description and number plays on the second sink only: its monitor records the file bit for bit while the default sink stays silent.
- An unknown device exits 3, and `--device` with `--decode` prints the usage.
- A stream killed with `pacmd kill-sink-input` reopens where it was heard and plays to the end.
- A sink unloaded during playback hands the stream to the default sink, where the file plays to its end.

`python3 tests/verify-devices.py --wine` ([report](../reports/devices-wine-verification.json)) runs the same checks with the Windows `lamp-cli.exe` under Wine. WASAPI there goes through Wine's PulseAudio driver, so the endpoints are the server's sinks, and playback is compared by order and position because that driver drops audio:

- The listing, the selection and the unknown device behave as on Linux.
- A killed stream reports an invalidated endpoint and reopens.
- After a removed sink, the chosen endpoint fails to initialize and the default endpoint takes over.

`python3 tests/verify-player.py` ([report](../reports/player-verification.json)) checks the Windows player's Output menu:

- It sends the menu's command for a second null sink's endpoint during playback.
- The stream moves to that sink, which records the file from the heard position.
- The `Default output` command brings it back.
