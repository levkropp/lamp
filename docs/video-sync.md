# Video scheduling foundation

The shared assembly scheduler is a component for milestone 4. It orders decoded
frame descriptors against an audible media clock; it does not decode video,
present images, or connect to the audio engine yet. Source builds remain audio
players. No end-to-end A/V, accurate video seeking, frame-step UI, GPU acceleration
or video codec support is claimed by this component.

## Contract

`src/video_sync.s` exports Microsoft x64 ABI functions on Windows and Linux.
`src/video_sync.inc` defines the layout. A caller owns one **1,152-byte** context,
with 32 frame slots and no allocations. Access must be serialized by one owner;
these functions do not provide cross-thread synchronization. Input, output and
context storage must be valid, sufficiently sized and nonoverlapping.

Each 32-byte frame descriptor contains signed `pts_ns`, positive signed
`duration_ns`, a nonzero opaque 64-bit surface token, and a nonzero 64-bit epoch.
The exclusive endpoint `pts_ns + duration_ns` must fit signed 64-bit. Negative
presentation times are allowed for preroll. Tokens are handles, never dereferenced
by the scheduler. Surface allocation, reference counting and a separate byte
budget remain the decoder/presenter's responsibility; 32 descriptors do not bound
the memory occupied by their images.

The clock is `{epoch:u64, media_ns:i64, state:u32, reserved:u32}` (24 bytes).
`media_ns` must be nonnegative and must never move backward within an epoch.
States are running (0), paused (1), starved (2), or an explicit single-step request
(3); `reserved` must be zero. The result is a 32-byte frame descriptor followed by
signed `wait_ns` (40 bytes).

| Function | Arguments after context | Result |
| --- | --- | --- |
| `video_sync_init` | late tolerance in ns, 0 through 1,000,000,000 | 1 initialized, 0 invalid; use only new storage or storage with no owned tokens |
| `video_sync_epoch` | new increasing nonzero epoch, nonnegative seek target in ns | 1 changed, 0 refused; queue must be empty |
| `video_sync_push` | pointer to frame descriptor | 1 accepted, 0 full, -1 invalid/stale/duplicate queued token |
| `video_sync_drain` | pointer to 32-byte output | 1 transferred earliest frame, 0 empty, -1 invalid count |
| `video_sync_select` | pointer to clock, pointer to result | action from table below |
| `video_sync_sample_ns` | **no context**: audible media samples (`u64`), rate (`u32`) | floor(samples × 1e9 / rate), or -1 for invalid/overflow |

The sample conversion accepts rates from 1 through 768,000 Hz. It uses a 128-bit
integer product and rejects results above `INT64_MAX`; no floating rounding or
wall-clock extrapolation is involved. The future engine adapter must provide
the heard entry's media position, including its seek, timestamp and rate mapping.
Submitted or decoded samples ahead of the device are not an audible clock.

| Select action | Value | Ownership and wait |
| --- | --- | --- |
| WAIT | 0 | No frame transferred; positive ns until earliest PTS |
| PRESENT | 1 | One frame transferred; wait 0 |
| DROP | 2 | One frame transferred for release; wait 0 |
| EMPTY | 3 | No frame; wait -1 (event-driven wakeup) |
| HOLD | 4 | Paused/starved; no frame transferred; wait -1 |
| ERROR | -1 | Context and result unchanged |

Successful pushes transfer ownership to the queue. Failed/full pushes leave it
with the caller. PRESENT, DROP and successful drains transfer exactly one token
back to the caller, which must release it or retain it as the displayed frame.
Removed slots are cleared. Equal PTS retain insertion order; out-of-order
completions are inserted by PTS using at most 32 bounded moves. Duplicate tokens
already queued are rejected, including when full. Reusing a retired token is
allowed after its previous ownership has been resolved.

Paused and starved states hold even an empty queue. Running/step selection first
drops frames ending at or before the seek target, and frames older than the last
presented PTS. A delayed completion cannot reverse the picture. A step then takes
one remaining frame immediately, including across a future timestamp gap;
preroll drops may require additional calls before that one presentation. The
caller freezes/repositions audio and issues one step request per desired frame.

Running selection waits for a future PTS. A due frame is dropped for lateness only
when the audible clock is **strictly more** than the configured tolerance past
its endpoint and another queued frame is already due. The last available frame
and a frame before a future gap are presented even if late. The presenter must
retain its displayed image between decisions; dropping a token is not a request
to clear the screen. Presented/dropped counters saturate at `UINT64_MAX` and reset
on epoch changes.

For seek, stop, cancellation or reopen, stop accepting old work, drain/release all
queued tokens, then install a greater epoch and the seek target. A stale producer
or clock is rejected without mutation. Seeking backward requires a new epoch;
epochs never wrap. This is an ownership protocol, not an asynchronous cancellation
primitive. Device loss, decoder flushing and worker locks remain integration work.

## Verification and limits

Build first, then run:

```
python tests/verify-video-sync.py --bin bin/video-sync-check --controls
python3 tests/verify-video-sync.py --bin build/video-sync-check --controls
```

Windows and Linux each pass **37,698,315 checks**, 500,000 deterministic randomized
operations and **14,371** exact sample-to-nanosecond vectors generated with Python
integer arithmetic. The independent test-only C model uses an unsorted bag and
insertion serials, rather than the assembly's sorted storage. Three simulated
sessions use 44.1, 48 and 192 kHz audio masters with 600 variable-duration frames
each (8.342/25.025/16.683 ms intervals, average 59.94 fps), a frozen starvation
clock, pause/steps and a 250 ms presentation-worker stall. These are metadata
simulations, not decoded image or real-time playback measurements.

Coverage includes exact late boundaries, future gaps, last-frame retention,
seek-containing intervals, stable equal PTS, negative preroll, late completions,
full-queue backpressure, stale epochs, backward clocks, invalid reserved fields,
signed endpoint overflow, unsigned epoch exhaustion, saturating counters,
output/context canaries, protected-page queue bounds and drain/reopen ownership.
Five isolated broken-policy objects each fail cleanly on both hosts: stale-epoch
acceptance, paused advancement, reversing pictures, backward clocks and dropping
the last frame. None enters a shipping binary. Native Windows runtime/import
checks and six-format Windows/Linux audio smoke checks retain their existing
scope. ARM64 macOS translation/assembly passes; native execution remains unverified.

Reports: [Windows](../reports/video-sync-windows-verification.json),
[Linux](../reports/video-sync-linux-verification.json),
[Mac compile-only](../reports/video-sync-mac-assembly-verification.json).
The elapsed oracle times measure a component test, not frame latency, playback
CPU use, wakeups, power, GPU cost or an advantage over another player.

Next work is a decoded-frame producer, timestamped demux integration, Windows GPU
presentation and a real audible-clock adapter. H.264, HEVC, VP9 and AV1 remain the
priority codecs. Reference images, actual mixed-media sync/seek fixtures, hardware
profiles/fallback behavior, color/aspect/rotation, deinterlacing, HDR/tone mapping
and screenshots remain open. Milestone 4's acceptance gate is still unchecked.
