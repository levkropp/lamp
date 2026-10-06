# Output devices

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

## Losing the output

LAMP reopens the output when it fails during console playback:

- **What counts as a failure:**
  - On Linux, the server kills the stream or fails it after it started.
  - On Windows, WASAPI reports the endpoint invalidated (`AUDCLNT_E_DEVICE_INVALIDATED`), or sends no callback for two seconds.
- **What LAMP does:** it prints `Audio output lost; reopening.` and opens a new stream in the file being heard, at the heard position. It uses navigation's restart (see [queue notes](queue.md)).
- **When the chosen output is gone:** a `--device` output that can no longer be activated is replaced by the default output from then on.
- **When nothing can be reopened:** when no output opens at all, playback ends with the usual audio error (exit code 3).

Removing a PulseAudio sink normally moves its streams to another sink, and playback simply continues there. The Windows player (`lamp.exe`) still uses the default endpoint and does not reopen yet.

## Verification

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
