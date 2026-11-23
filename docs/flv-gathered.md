# FLV PCM, G.711 and MPEG media time

PCM, G.711 and MPEG audio now use FLV tag clocks, completing timestamp
placement for the currently supported FLV audio paths. All use the shared
packet/media map: gaps emit bounded silence, later overlaps and negative
prefixes are clipped, and seeks/duration follow media time. AAC/HE-AAC,
Flash ADPCM and Speex keep their [existing timed packet path](flv-clock.md).
Video presentation and A/V synchronization remain open.

## Byte fragments and frame ownership

Selected PCM/G.711/MPEG payload bytes are still gathered in their original
order, preserving samples or compressed frames split across tags. The
gathered bytes now become packet views rather than a synthetic Wave64 file.
A second bounded pass associates those views with original tags.

A sample/MPEG frame belongs to the tag containing its first byte, even
when later tags finish it. A continuation-only tag owns no new frame and
does not independently retime a frame already started. If a continuation
tag contains a new frame, its first new frame receives the tag timestamp
plus the complete preceding sample/frame's duration. Later frames within
the same tag remain contiguous. This gives fragmented legacy input a
deterministic policy without dropping or duplicating payload bytes.

That continuation adjustment is carried in signed nanoseconds, avoiding
overflow when a positive signed-millisecond timestamp is already at its
maximum. The shared one-millisecond quantization tolerance and nearest
sample rounding still apply. Empty tags and skipped/encrypted/other-layout
audio do not advance the gathered-byte position or the selected clock.

PCM and G.711 views contain whole samples. Only an incomplete final sample
is discarded; inter-tag sample fragments survive. A large tag is split
into views of at most 262,144 stereo-output frames, with one timestamp
anchor on its first view. Valid empty/less-than-one-sample PCM/G.711 opens
with zero duration and seekable EOF; it does not read an uncommitted packet
index entry.

MPEG views use the original validated frame/CRC parser, including frames
that cross tag boundaries. Native ID3/APE stripping, Xing/Info-frame removal
and encoder delay/end trimming are retained before creating packet views.
MPEG rate, channel, layer and version changes still reject. The gathered
bytes remain owned until the decoder closes; packet views never own or
free individual frame memory.

## MPEG seek history corrections

Tests exposed a packet seek failure in a valid VBR stream: zero-filled
unknown reservoir bytes could survive as supposedly known unused history,
causing a later Huffman error before playback reached its target. The
reservoir now retains only real, unused bytes. Pre-roll frames missing
earlier main data remain silent until their actual history is available.

The backward packet search now counts 2 KiB of usable main-data bytes,
excluding headers, CRC and side information, before the existing two-frame
synthesis pre-roll. A cancellation check runs on every backward step.
Native MPEG open also resets packet-mode reservoir tolerance, so a prior
packet seek/close cannot make a malformed native stream acceptable.

[Counterfactual controls](../reports/flv-gathered-negative-controls-windows-verification.json)
reproduce the VBR error with the previous prefix/history behavior; fixing
only prefix provenance passes that same fixture. Omitting only the
native-open tolerance reset reproduces acceptance of a missing reservoir
after packet seek/close. The current runtime rejects it both cold and after
reopen. Control objects are test-only and never enter shipping links.

## Resources and verification

The gathered buffer still reserves input-sized address space and commits
as payload is copied. The shared packet index adds 24 bytes per view,
reserving at most 384 MiB and committing 192 KiB per 8,192 entries, capped
at 16,777,216 packets. The codec uses the existing bounded 2 MiB stereo
PCM buffer. Clock events/spans use the shared [sparse-map limits](matroska-clock.md#sparse-mapping-and-seeks);
identity maps release their temporary allocations. Opening scans the
selected payload and frame structure; this addition does not establish
startup/seek performance on every input or device.

The [Windows](../reports/flv-gathered-windows-verification.json) and
[Linux](../reports/flv-gathered-linux-verification.json) suites each pass
177 files and 2,832 media seeks. They compare an
independent per-sample placement model with actual PCM and seeks. PCM
uses exact known samples, MPEG source PCM is checked against native raw
decoding, and G.711/codec DSP has the existing independent reference suites.
Tests cover mono/stereo PCM at three rates/depths, both G.711 laws, MPEG
CBR/VBR at 8–48 kHz, arbitrary byte fragmentation, gaps/overlaps/negative
and reversed clocks, ignored foreign tags, format-0 byte order, large tags,
empty output and native MPEG metadata/trims. Sparse maximum-clock cases
include continuation adjustments beyond signed-millisecond range.

Three guarded files exercise protected/read-only input pages, truncated
prefixes, output canaries and 1,536 mutations. Accepted damaged input
establishes bounds rather than correct damaged-file audio; mutation reads
stop at 128 calls and seek at call 64. Cancelled open/read and reopen pass.
The earlier FLV packet-clock and Matroska-clock suites also pass, alongside
the existing FLV, track, MP4 and native MP3 regressions. The shared clock
component adds absolute-nanosecond cases to its random/allocator/bounds
coverage.

Muted native Windows probes cover timed PCM, G.711 and MPEG through
play/pause/resume, stop/reopen, active/paused seeks, cancelled open,
simulated default-output recovery and exclusive 48 kHz output. Changed
modules [translate and assemble for Apple Silicon](../reports/flv-gathered-mac-assembly-verification.json).
Native Mac execution, Linux device playback, hardware PCM capture and
physical hotplug remain unverified here.

Run `python tests/verify-flv-gathered.py --bin bin/flv-gathered-check`
and `python tests/verify-mpeg-restart.py --bin bin/flv-gathered-check`.
Linux uses `python3` and `build/flv-gathered-check`. The first suite's
`--fixtures PATH` replays its encoded/reference corpus without FFmpeg;
the restart controls use the resulting fixtures. Windows controls need
`llvm-mc` on PATH, or the documented WSL LLVM build environment.
Windows `--probe` requires a marked muted build.
