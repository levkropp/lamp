# Windows exclusive audio output

Current Windows source builds support explicit exclusive WASAPI output in the
CLI. Shared mode remains the default and the Windows graphical player's mode.
This option is not in the older published v0.3.0 prerelease.

```powershell
.\bin\lamp-cli.exe --exclusive --rate device 'C:\Music\track.flac'
.\bin\lamp-cli.exe --exclusive --rate 48000 'C:\Music\track.flac'
```

Exclusive mode reserves the selected endpoint and can interrupt other
applications' audio. Omit `--exclusive` to share the output. Pausing stops the
stream and freezes its clock but retains endpoint ownership until stop/close.
LAMP applies its own volume to samples without changing system endpoint
volume. Native surround, passthrough and dither are not provided.

The exact session rate must be supported. By default this is the first file's
rate; `--rate HZ` resamples every file with LAMP's filter. `--rate device` uses
the endpoint's shared mix rate, which is not guaranteed to be accepted for
exclusive playback. Busy, disabled or unsupported exclusive output exits with
code 3 and suggests another rate or shared mode. It does not silently switch
to shared mode or another endpoint on an exclusive initialization failure.
Existing recovery of a missing explicitly selected endpoint remains.

## Format negotiation and packing

`src/win/output_format.s` provides three bounded functions using the Windows
x64 ABI:

- `output_format_make(destination, rate, kind, capacity)` constructs a 48-byte
  descriptor: the first 40 bytes hold a `WAVEFORMATEXTENSIBLE`-sized format,
  followed by a 32-bit kind and zero reserved word. It accepts stereo rates
  from 8,000 through 192,000 Hz and rejects invalid requests without writing.
- `output_format_choose(client, rate, destination, capacity)` queries
  `IAudioClient::IsFormatSupported` in exclusive mode, with a null closest-match
  pointer, at exactly the requested rate. It commits a descriptor only on
  `S_OK`. Unsupported formats and `S_FALSE` try the next kind; other failures
  stop. It never initializes or starts a stream.
- `output_format_pack(destination, floatStereo, frames, kind, destinationBytes,
  volume)` converts at most 262,144 frames into the negotiated representation.
  Input and output must not overlap. Invalid sizes, pointers, kinds or gains
  fail before any writes. Gain is finite and within 0–1, nonfinite input becomes
  zero, and gain precedes clipping to full scale. Integer conversion rounds to
  nearest with ties away from zero and saturates positive full scale. Float32
  output follows the caller's floating-point environment; normal runtime
  round-to-nearest is the tested float path.

The preference order is extensible float32, PCM32, 24 valid bits left aligned
in a 32-bit container, packed PCM24 and PCM16; then basic float32, PCM32, packed
PCM24 and PCM16. All are stereo, with FL/FR mask 3 for extensible formats. The
basic descriptors have `cbSize=0`. Packing uses little-endian samples and no
heap, locks or operating-system calls. This supports devices that accept
integer PCM but reject float32. It does not add native surround or passthrough.

## Stream setup and ownership

`src/win/output_exclusive.s` provides
`output_exclusive_open(device, rate, event, destination)` and
`output_exclusive_close(state)`. The 96-byte state contains the descriptor,
owned client/render/clock interfaces, clock frequency, buffer frame count and
requested period. The destination must have no owned interfaces when opened;
it is unchanged on failure. Close releases clock, render and client in that
order, clears the state and tolerates a null pointer or repeated close. The
owner must stop a running client before closing it.

Open negotiates the exact rate, uses the greater of the device's default and
minimum periods and 10 ms, and rejects periods above 200 ms. Exclusive
event-driven initialization receives matching duration and periodicity, with
no Windows conversion flags. A buffer-alignment failure retrieves the aligned
frame count, releases that client, computes the nearest whole 100-ns duration
and activates a fresh client for one retry. Returned buffers must contain
1–262,144 frames and the audio clock must have a nonzero frequency. Every
failure releases acquired interfaces; unexpected positive statuses are errors.
There is no silent fallback to another output or shared mode in this helper.

**Open can acquire the endpoint.** It is not a read-only capability probe.
The optional real-device test described below calls only format queries, not
this helper. Neither helper starts a stream. Calls, interface use and cleanup
belong on the playback owner's STA thread.

The contracts follow Microsoft's [format-query documentation](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-isformatsupported),
[format layout](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible)
and [exclusive initialization/alignment rules](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize).

## Event buffers, position and draining

The playback owner registers a separate device event in exclusive mode.
Pause/resume and default-device callbacks wake the control event, so they do
not request a packet before the hardware signals readiness. The producer still
fills the stereo-float queue; the render owner copies real samples through a
bounded scratch buffer, packs them with the current gain and submits exactly
the device buffer size. Partial tails get zero padding; wholly empty blocks use
`AUDCLNT_BUFFERFLAGS_SILENT`. Queue consumption is published only after a
successful `ReleaseBuffer`.

`output_exclusive_write(state, input, realFrames, volume)` implements the
whole-buffer write/release contract. It releases a defensively rejected packet
as silence and propagates device failures. A `BUFFER_ERROR` means no packet
was acquired and does not release one; the player waits for another processing
pass, bounded to 16 consecutive failures before output-loss recovery.

`output_exclusive_position(state, destination)` converts `IAudioClock` position
and frequency into session frames with a 128-bit integer product/division.
`S_FALSE` is accepted as a less precise reading without spinning. Errors, zero
frequencies and numeric overflow leave the destination unchanged. A bounded
64-entry interval FIFO maps device frames onto real queue frames, so inserted
silence does not advance media position. A stalled or regressing clock fails
instead of growing the FIFO indefinitely. At EOF the owner waits until the
device clock reaches the last real sample's end before stopping. Diagnostics
append negotiated container/valid bits, buffer size and `heard_frames` (an
absolute queue position including the initial seek).

Pause, seek, queue navigation and default-output restarts reuse existing owner
paths. A default-output restart keeps the session rate and exclusive request;
a new endpoint that cannot accept them reports an error. This is not a seamless
handoff. The graphical player has no exclusive-mode menu yet.

## Native verification

```powershell
python tools/build-windows.py --out bin/exclusive-check --tests --probe-exclusive --probe-default-device
.\tests\verify-windows-output-format.ps1 -OutputDirectory .\bin\exclusive-check -DeviceProbe
python tests/verify-windows-exclusive.py --bin bin/exclusive-check
```

The ordinary build needs LLVM and Python. The optional oracle additionally
needs Visual Studio x64 C++ Build Tools and a Windows SDK. The final command
also needs FFmpeg and a default endpoint supporting exclusive 48 kHz stereo;
it acquires that endpoint and plays silence. Run only the component oracle,
omitting `-DeviceProbe`, for models, guarded memory and mock COM objects without
using a real endpoint.

The [recorded report](../reports/windows-output-format-verification.json)
passes 2,132 checks across 63,704,348 sample positions. Coverage includes
all nine descriptors over a rate sweep, exact-size buffers ending at protected
pages, zero/tiny/maximum frame counts, finite/nonfinite/extreme/random samples,
four gains, clipping, packed 24-bit and 24-in-32, overlap and invalid-request
rejections, and integer output in all four MXCSR rounding directions. Mock
clients check exclusive-only queries, preference/failure behavior, full SDK
method signatures and GUIDs, one fresh-client alignment retry, null interfaces,
zero/oversized buffers, invalid periods/frequency and cleanup at every COM
failure. Whole-buffer writes check full/partial/silent packets, exact protected
buffers, failed acquisition/release and rejected packing. Clock tests cover
arbitrary frequencies, overflow, `S_FALSE` and errors. Guarded state buffers end
exactly before an inaccessible page.

The optional device query on the recorded Windows host accepted 48 kHz stereo
PCM16 and rejected 8, 44.1, 96 and 192 kHz across the candidate formats. These
results describe that endpoint at that time, not all Windows hardware. It
never initialized/started a stream, changed the default device or took
exclusive control. Source, object and oracle hashes are retained in the report.

The separate [native playback report](../reports/windows-exclusive-verification.json)
covers silent WAV, FLAC, MP3, Vorbis, Opus and AIFF sources, including resampled
44.1 kHz and multichannel source layouts, at a 48 kHz session. Each passes
pause/resume, stop/reopen, seek, paused seek, cancelled open, paused/active
synthetic default-device restart and preservation of a pending user command.
Thirteen natural-EOF cases include empty files, 1–3 frames and partial blocks,
requiring exact final heard positions. A mixed-rate queue starts 29.5 s into
its first file and crosses into the next at the expected heard position. CLI
misuse and queried unsupported rates reject. A second exclusive process gets
`DEVICE_IN_USE` while the first plays to its natural end.

## Remaining verification and controls

Actual physical default changes/device loss, captured hardware PCM, sustained
load/glitches, long-run clocks, latency/CPU/wakeups and a wider hardware matrix
remain unverified. Full-buffer mock PCM and silent native lifecycle checks do
not prove audible hardware accuracy or low latency. Disabled-mode behavior is
covered by setup error propagation rather than changing Windows settings.
GUI controls, releasing ownership while paused/inactive and equivalent platform
output choices remain separate work.
