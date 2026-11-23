# Audio position snapshots

The Windows audio engine now publishes a coherent position snapshot for a
future audio-master video controller. It fixes shared-mode position reporting
when a render buffer contains both real PCM and inserted starvation silence.
The video-only window still uses its own clock; synchronized A/V playback is
not implemented by this change.

## Windows engine contract

`engine_clock_snapshot(output)` uses the Windows x64 ABI and returns 1 on
success or 0 when no generation is available or publication is busy. Output
must be a valid, nonoverlapping 40-byte buffer. Failure leaves it unchanged.
Reading makes no COM calls, allocates nothing and tries at most eight times.
The engine retains the page after stop so readers can inspect the final state.

| Offset | Field |
| --- | --- |
| 0 | Nonzero increasing generation (`u64`) |
| 8 | Media position in nanoseconds (`i64`) |
| 16 | State (`u32`) |
| 20 | Reserved zero (`u32`) |
| 24 | Absolute output-session frame position (`u64`) |
| 32 | Session sample rate (`u32`) |
| 36 | Reserved zero (`u32`) |

States are running (0), paused (1), starved (2), ended (4), stopped (5) and
failed (6). There is no single-step state in the audio publisher. A new engine
start/reopen creates a new generation and captures the rate and seek base.
Within a generation, frame position never decreases. Nanoseconds use exact
integer `floor(frames * 1e9 / rate)`; there is no wall-clock extrapolation.

Frames are queue/session coordinates, including the seek base. A queue
controller must map them to the heard entry's media timeline. A future A/V
controller must also handle generation changes and terminal states explicitly:
only the first 24 bytes of states 0–2 match the scheduler's clock contract.
Audio ended/stopped/failed states must not be passed directly to `video_sync`.
A failed open before clock initialization can leave the previous generation's
snapshot visible; callers must wait for the expected new generation and
readiness rather than treating any nonzero snapshot as a successful open.

Shared mode maps **accepted submitted frames minus current endpoint padding**
through a bounded list of real-PCM intervals. App-inserted starvation zeros
freeze media position; actual decoded silence and container timestamp-gap
silence advance it. For example, a 100-frame packet with a 60-frame real prefix
and 80 frames still queued has consumed 20 real frames. Subtracting padding
from the real-frame count incorrectly reports zero in this case.

The interval is committed only after successful `ReleaseBuffer`, using the
same real prefix reserved before `GetBuffer`. Failed acquisition/publication
does not consume queued PCM. After refill, state can become running at the
same observed position, without counting newly submitted frames as consumed.
Prebuffering alone does not claim a running stream. Stop/pause refresh the
frozen cursor after stopping the client; natural EOF publishes the exact real
frame count, including empty files and partial final packets. Automatic
default-output recovery refreshes its final heard position while preserving
the file/time pair of an already pending user command.

Exclusive mode retains its existing device-clock-to-real-PCM interval mapping
and publishes the mapped result through the same snapshot page. This does not
change format negotiation, gain, buffering or endpoint selection.

Shared padding measures the endpoint queue, **not physical speaker latency**.
The snapshot is not a measured audible playhead. Hardware/system latency,
actual mixed-media synchronization, connected late-frame handling and physical
device handoffs remain to be verified.

## Shared assembly component

`src/audio_clock.s` and `src/audio_clock.inc` define a 1,664-byte, zero-initialized
context with 64 bounded interval records. Context storage must be aligned to
at least eight bytes, remain live for every reader and have one serialized
writer. All input/output buffers must be valid and nonoverlapping. The component
uses no heap, operating-system calls or external codec/runtime dependency.

| Function | Arguments after context | Result |
| --- | --- | --- |
| `audio_clock_begin` | Config pointer: epoch/base frames (`u64` each), rate/mode (`u32` each), reserved zero (`u64`) | 1 initialized, 0 refused |
| `audio_clock_can_submit` | Total submitted packet frames, real prefix frames (`u64`) | Read-only capacity/range check |
| `audio_clock_submit` | Same packet counts | Commit accepted packet, 1/0 |
| `audio_clock_observe` | Consumed submitted frames (`u64`), state (`u32`; 0 selects real/gap automatically) | Map and publish, 1/0 |
| `audio_clock_publish` | Already mapped absolute media frames (`u64`), explicit state (`u32`) | Direct-mode publication, 1/0 |
| `audio_clock_status` | State (`u32`) | Freeze position and change state, 1/0 |
| `audio_clock_read` | 40-byte output pointer | Bounded coherent snapshot, 1/0 |

Mode 0 maps submitted intervals; mode 1 accepts the adapter's already mapped
position. Do not mix these methods in a generation. Rates are 1–768,000 Hz.
Epochs must increase without wrapping. Absolute frames cannot exceed
`floor(INT64_MAX * rate / 1e9)`. Packet totals are nonzero; real data must be a
prefix no larger than the packet. Consumed counts cannot decrease or exceed
accepted submission. Contiguous real intervals coalesce; zero-only packets do
not consume slots. Capacity, arithmetic and protocol failures leave state
unchanged. Preflight and commit must be serialized on the same writer.
Terminal states cannot return to a lower state without a new generation.
Mapped EOF requires all real data to have been consumed. A direct-mode adapter
is responsible for validating its own hardware mapping and EOF condition.

Publication uses an aligned version counter and explicit memory barriers.
Readers copy generation, position, rate and state from the same publication.
Apple Silicon translation emits `dmb ish` for the new `mfence` instruction;
native Mac concurrency and engine integration remain unverified. Linux tests
exercise the component, without connecting it to PulseAudio.

## Verification

`tests/verify-audio-clock.py` runs an independent interval-sum model, 150,000
operations, capacity/overflow/terminal-state boundaries and concurrent readers
against 100,000 updates across 100 generations. Windows and Linux produce
the same deterministic model fingerprint; scheduling-dependent reader counts
are recorded separately.

On Windows, `tests/verify-player-clock.py --bin bin/audio-master-check` exercises
the real render function with fake COM clients: 32,000 refill iterations,
PCM/silence boundaries, rejected buffers and lifecycle helpers. It opens no
endpoint. `verify-player-padding.py` reproduces the 0-versus-20-frame bug using
the previous published engine and verifies the corrected result.

`tests/verify-engine-clock.py --bin bin/audio-master-check` uses only generated
zero WAV files and sets engine gain to zero before every owned session. Shared
and exclusive checks cover coherent position/rate, pause hold, resume, stopped
snapshots, paused seek/reopen generations and exact partial/empty EOF. The
existing silent lifecycle probe also passes default-output callbacks and
pending-command preservation. These tests do not alter system volume or
default devices and do not establish speaker latency or A/V synchronization.

Reports: [Windows model](../reports/audio-clock-windows-verification.json),
[Linux model](../reports/audio-clock-linux-verification.json),
[render integration](../reports/player-clock-windows-verification.json),
[previous/current counterexample](../reports/player-padding-windows-verification.json),
[native sessions](../reports/engine-clock-windows-verification.json),
[regressions](../reports/audio-master-regression-verification.json) and
[Mac translation/assembly](../reports/audio-clock-mac-assembly-verification.json).

The queue interpretation follows Microsoft's
[GetCurrentPadding contract](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getcurrentpadding);
accepted-packet ownership follows
[ReleaseBuffer](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiorenderclient-releasebuffer).
Exclusive position uses
[IAudioClock::GetPosition](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclock-getposition).
