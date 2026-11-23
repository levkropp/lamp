# ASF AAC presentation time

AAC with an AudioSpecificConfig, including supported HE-AAC v1/v2 signaling,
now places completed ASF media objects on the shared audio presentation map.
Leading and internal gaps produce silence; negative prefixes and later
overlaps are clipped. Duration and seeks follow the resulting media time.
Codec packets and their history remain in source order, including packets
whose entire presentation is clipped.

The implementation now also applies object clocks to
[PCM/float, G.711, ADPCM, MPEG audio, AC-3 and configuration-free ADTS](asf-gathered.md).
The AAC-specific evidence below remains the packetized-AAC baseline. WMA,
video and A/V synchronization remain unfinished.

## Clock contract

Following sections 3.2, 3.3, 5.2.2 and 5.2.3 of Microsoft's
[ASF specification, revision 01.20.03](https://download.microsoft.com/download/7/9/0/790fecaa-f64a-4a5e-a430-0bccdab3f1b4/ASF_Specification.doc),
the selected object's clock is:

```text
nanoseconds = presentation_milliseconds × 1,000,000
            + selected_stream_time_offset_100ns × 100
            − file_preroll_milliseconds × 1,000,000
```

Ordinary replicated data supplies an unsigned 32-bit presentation time.
Fragments repeating that data must agree on object size and time; a
replicated-data-free continuation inherits both. For compressed groups,
the offset field supplies the initial time and the replicated byte supplies
the increment between complete subobjects. That field must be present.
The accumulator is 64-bit, so advancing past the largest initial 32-bit time
does not wrap. Packet send times and advertised play durations do not replace
object clocks or fabricate trailing samples.

The implementation evaluates the unsigned products and subtraction at
128-bit precision before checking the signed nanosecond result. Large offset
and preroll terms can cancel without premature rejection. Results outside
±INT64_MAX reject. Sample placement rounds to nearest, with half samples away
from zero. A one-millisecond tolerance absorbs timestamp quantization when
the offset from continuous coded time changes by at most one tick. The first
tick-sized offset is likewise treated as continuous. Negative presentation
is tolerated and clipped as an explicit playback policy.

Audio spreading finishes before a completed AAC object becomes a packet.
Its clock marker occupies the existing packet index; this change adds no
separate per-object timestamp allocation. The shared sparse event/span map
and fixed read scratch retain their [documented bounds](matroska-clock.md).
Seeking primes the codec privately, then returns the requested media position.
Cancellation is checked between compressed subobjects as well as packets,
fragments and spreading chunks. Scratch is released on every open return.

## Evidence and limits

`python tests/verify-asf-clock.py --bin PATH` generates and checks the corpus;
`--fixtures PATH` replays hash-pinned inputs without an encoder. `--probe` adds
native Windows lifecycle checks through a binary built with silent output.
The [Windows](../reports/asf-clock-windows-verification.json) and
[Linux](../reports/asf-clock-linux-verification.json) runs each pass:

- 223 files and 3,568 exact media seeks: all twelve supported AAC-LC rates,
  mono/stereo, HE-AAC v1/v2 with implicit, explicit and sync-extension signaling,
  gaps, overlap, negative/repeated clocks, fragment inheritance, compressed
  groups, selected offsets and cancellation of large clock terms.
- Six bounded sparse-clock cases, including compressed increments beyond
  unsigned milliseconds and positive signed-nanosecond boundaries.
- Four rejected layouts: contradictory fragment time, missing compressed
  start field, overflowing stream offset and overflowing preroll.
- 624,995,996 protected-input/output checks across three files, 766 truncated
  prefixes and 1,536 mutations; mutated reads stop after 128 calls and seek
  midway on call 64. Cancelled open/read both permit a clean reopen.

Expected presentation is calculated independently per sample from untimed
codec output. AAC seek references decode packet suffixes with the appropriate
LC or SBR/PS primers. These tests establish clock placement and restart
behavior; codec DSP has separate reference suites. The original ASF regression
also checks a real FFmpeg-muxed AAC stream against its elementary copy.

Muted Windows checks pass AAC and HE-AAC v2 playback, pause/resume, stop/reopen,
ordinary and paused seeks, cancelled open, default-output recovery and
exclusive-session lifecycle. Seven [saved published-binary controls](../reports/asf-clock-negative-controls-windows-verification.json)
reproduce the earlier timing differences and acceptance of inconsistent or
unrepresentable clocks. [Apple Silicon translation and assembly](../reports/asf-clock-mac-assembly-verification.json)
pass; native Mac execution and Linux device playback are unverified.

The existing audio, spreading and embedded-stream suites also pass on
[Windows](../reports/asf-clock-extended-windows-verification.json) and
[Linux](../reports/asf-clock-extended-linux-verification.json), with 93, 72 and
88 checks respectively per platform. Linux replays the pinned Windows-prepared
FFmpeg reference PCM; no Linux FFmpeg or device execution is claimed. Their
audio comparisons, selected-track
catalogs, guarded parsers, large sparse headers, metadata and mutation checks
remain enabled. The spreading serializer now gives AAC coherent object clocks;
the embedded-stream suite explicitly marks its large Windows fixture sparse
and measures its allocated bytes through the native file API.
