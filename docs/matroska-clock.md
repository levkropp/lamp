# Matroska audio media time

Matroska/WebM audio now follows selected-track Block timestamps. Leading
and internal gaps produce silence; negative media positions are clipped.
For overlap, samples already presented win and the later overlapping prefix
is discarded. Decoding still consumes skipped audio to preserve codec history.
Duration and seeking include gaps. This is audio presentation groundwork;
video rendering, an audio-master video clock and A/V synchronization remain open.

## Clock and rounding

The [RFC 9559 timestamp formula](https://www.rfc-editor.org/rfc/rfc9559.html#section-11.2)
is `(ClusterTimestamp + signedBlockTimestamp * TrackTimestampScale) * TimestampScale - CodecDelay`.
Only the relative Block timestamp uses the legacy track scale. Segment
TimestampScale defaults to 1 ms. Positive finite 32/64-bit track scales are
accepted; Cluster Timestamp is mandatory, including when written after Blocks.
Info may appear after Clusters. Laced packets are contiguous, with the Block
timestamp attached to the first packet.

The ordinary integer-scale path uses exact integer arithmetic. The legacy
float scale rounds the relative product to the nearest nanosecond. Absolute
times convert to decoded samples with nearest rounding, half ties away from
zero. Nanosecond intermediates must fit signed 64-bit magnitude; overflow,
duplicate clocks/scales, zero Segment scale, nonfinite/nonpositive track scale
and malformed field sizes reject. Unselected audio clocks do not alter the
selected track's presentation.

To tolerate container timestamp quantization, an offset change must exceed
one Segment tick (or one scaled track tick when larger). Comparisons use
nanoseconds, so a fine timestamp scale can preserve a single-sample gap.
This policy is deliberate: sub-tick discrepancies do not accumulate into
periodic inserted or discarded samples. It does not resample drifting clocks.

[CodecDelay and signed whole-Block padding](matroska.md#codec-delay-and-block-padding)
retain their existing sample-removal rules. Real timestamp gaps around
removed samples remain gaps. Test remuxes intended to represent compressed
presentation explicitly update timestamps to describe that presentation.

## Sparse mapping and seeks

The existing 24-byte packet index temporarily stores the first packet's
Cluster/relative timestamp in fields not yet used by duration scanning.
After scanning, those fields again hold coded positions and lengths; there
is no second timestamp record for every packet.

Changed clock offsets use 16-byte sparse events, reserving at most 256 MiB
and committing in 64 KiB steps. A sweep intersects those events with the
existing padding map and produces 32-byte source/media spans, reserving at
most 512 MiB and committing in 64 KiB steps. Both have a 16,777,216-entry
limit. Events are released after the sweep; ordinary identity timelines
release both allocations. Allocation/commit failures reject cleanly.

The source codec keeps its coded history, existing trims and requested
SeekPreRoll. A mapped seek returns the exact clamped media sample and
privately primes/discards the source decoder before audible output. A seek
inside a gap emits the remaining silence, then resumes source PCM. Reads
use caller-sized output and a fixed 32 KiB discard buffer; a trillion-frame
gap does not allocate a trillion samples. Identity files keep the existing
codec seek-base contract. Cancellation and close/reopen clear mapping state.

Vorbis packet output now follows center-to-center sample intervals. The
existing synthesis can emit a long-to-short prefix early; a bounded 2,048-frame
stereo buffer carries those samples into the correct packet interval.
Container timestamps and padding therefore address the correct packet
samples without changing the continuous source waveform. Ogg's native
granule/overlap reader remains separate. A real encoded stream can begin
with a small media offset; comparisons retain that offset rather than
assuming raw decoded PCM starts at media time zero.

## Evidence and limits

The [Windows](../reports/matroska-clock-windows-verification.json) and
[Linux](../reports/matroska-clock-linux-verification.json) integration suites
each pass 145 files and 2,320 seeks. An independent per-sample placement
model covers PCM at six rates from 8–192 kHz plus FLAC, Opus, MP2, MP3,
AAC, ALAC, Speex, Vorbis, AC-3, E-AC-3 and WavPack. Fine/signed/scaled
clocks, leading/internal gaps, overlap, negative clipping, late metadata,
unknown Clusters, lacing, delay/padding/pre-roll intersections, selected
ordinals and foreign clocks are included. Fourteen malformed metadata
cases reject. PCM source extraction explicitly bypasses the media map;
Opus/AAC/AC-3/E-AC-3 seek references decode independent packet suffixes.
Codec DSP conformance is established by its separate suites.

Protected input/output checks cover three files, 1,536 bit mutations and
3,738 truncated prefixes. Accepted damaged inputs establish bounded behavior,
not correct damaged-file audio; mutation reads stop after 128 calls and
seek at call 64. A tiny file with a trillion-frame gap verifies bounded
reads, direct gap-boundary seeks, EOF, cancellation and reopen.

The map-only [Windows](../reports/track-time-windows-verification.json) and
[Linux](../reports/track-time-linux-verification.json) tests each pass 521
cases, 22,255,077 checks and 27,066 seeks, including randomized cuts and
placement, allocator failures, growth boundaries and arithmetic limits.
The direct Vorbis packet [Windows](../reports/vorbis-packet-clock-windows-verification.json)
and [Linux](../reports/vorbis-packet-clock-linux-verification.json) suites
compare every packet's count and PCM to the pinned unmodified Xiph 1.3.7
decoder: 34 mono/stereo streams, eight rates, two qualities, transients,
extreme 64/8192 windows, six cold suffix/reset runs and guarded failures.
This does not establish every Vorbis profile or atomic error recovery.

Muted native Windows lifecycle checks cover timed, laced Opus and Vorbis
through pause/resume, stop/reopen, active/paused seek, cancelled open,
simulated default-output recovery and exclusive 48 kHz output. Changed
modules [translate and assemble for Apple Silicon](../reports/matroska-clock-mac-assembly-verification.json).
Native Mac execution, Linux device playback, captured hardware PCM,
physical hotplug and video/A/V synchronization are not established here.

Run `python tests/verify-track-time.py --bin bin/mkv-clock-check`,
`python tests/verify-matroska-clock.py --bin bin/mkv-clock-check` and
`python tests/verify-vorbis-packet-clock.py --bin bin/mkv-clock-check`.
Linux uses `python3` and `build/mkv-clock-check`; `--fixtures PATH` replays
the generated integration/packet corpus without FFmpeg. Windows `--probe`
is only for a marked muted probe build. The Windows map oracle also needs
`tests/track-time-probe.s` assembled as `track-time-probe.obj` in that directory.
