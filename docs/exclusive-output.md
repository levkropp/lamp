# Windows exclusive-output foundation

Exclusive playback is **not available yet**. The shipping console and window
continue to use shared-mode float32 stereo WASAPI. There is no `--exclusive`
option. These original assembly components prepare milestone 2's exclusive
output path; they are assembled by the Windows builder and linked only into
the optional component oracle for now.

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

## Native component verification

```powershell
python tools/build-windows.py --out bin/default-check --tests
.\tests\verify-windows-output-format.ps1 -OutputDirectory .\bin\default-check -DeviceProbe
```

The ordinary build needs LLVM and Python. The optional oracle additionally
needs Visual Studio x64 C++ Build Tools and a Windows SDK. Omit `-DeviceProbe`
to run entirely against numeric models, guarded memory and mock COM objects.

The [recorded report](../reports/windows-output-format-verification.json)
passes 1,223 checks and 20,404,016 sample-value comparisons. Coverage includes
all nine descriptors over a rate sweep, exact-size buffers ending at protected
pages, zero/tiny/maximum frame counts, finite/nonfinite/extreme/random samples,
four gains, clipping, packed 24-bit and 24-in-32, overlap and invalid-request
rejections, and integer output in all four MXCSR rounding directions. Mock
clients check exclusive-only queries, preference/failure behavior, full SDK
method signatures and GUIDs, one fresh-client alignment retry, null interfaces,
zero/oversized buffers, invalid periods/frequency and cleanup at every COM
failure. Guarded state buffers end exactly before an inaccessible page.

The optional device query on the recorded Windows host accepted 48 kHz stereo
PCM16 and rejected 8, 44.1, 96 and 192 kHz across the candidate formats. These
results describe that endpoint at that time, not all Windows hardware. It
never initialized/started a stream, changed the default device or took
exclusive control. Source, object and oracle hashes are retained in the report.

## Remaining integration

Connect an explicit playback option; service full exclusive event buffers;
pack samples with the current volume; handle short final blocks and starvation;
use the device clock for position and draining; preserve pause, seek, queue and
device-restart behavior. Then verify native exclusive playback and submitted
PCM, busy/disabled/unsupported devices, actual device loss, long runs and
latency/CPU/wakeups on named hardware. GUI controls and platform parity remain
separate work. These component checks do not establish any of those behaviors.
