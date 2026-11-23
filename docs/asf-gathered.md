# ASF gathered audio presentation

All currently supported ASF audio paths now apply media-object presentation
time, selected-stream offset and file preroll. This extends the
[AAC object clock](asf-clock.md) to PCM/float, both G.711 laws,
IMA/Microsoft/Duck ADPCM, MPEG audio, AC-3 and AAC gathered as ADTS.
WMA, video rendering and A/V synchronization remain unfinished.

## Source bytes and clocks

The first pass rebuilds selected objects and restores audio spreading exactly
as before. The existing WAVE or ADTS reader validates the gathered codec.
`src/asf_views.inc` then replays the bounded ASF framing to associate complete
objects with source-frame boundaries. This second pass advances a checked
logical byte cursor; it neither copies audio again nor repeats spreading.
It must consume exactly the original gathered audio byte count.

WAVE ADPCM, AC-3 and ADTS already supply validated packet starts and durations.
Native MPEG parsing retains its ID3, APE, Xing and encoder-trim rules before
frame views replace its native index. A final 128-byte ID3v1 record is metadata,
as in the native reader. Objects containing only metadata own no audio clock
anchor. ID3v2 can occupy its own object with an unrelated timestamp without
moving the following audio.

PCM/G.711 uses packet views of at most 262,144 sample frames, preserving the
native WAVE reader's validated precision, float conversion, speaker mask,
direct-out routing and mixing state. It shares the existing 2 MiB packet PCM
buffer. The internal prepared-state flag is cleared when the track closes,
so later ordinary container PCM still initializes its own format.

A sample or coded frame belongs to the object containing its first byte.
Objects may contain several frames, and gathered byte boundaries may cross
frames. A continuation-only object owns no new anchor. When an object starts
inside the preceding frame and contains a new frame, its first newly owned
frame advances that object's clock by the full preceding-frame duration.
ADTS ownership includes its header, although the AAC packet pointer addresses
only its raw payload. This is an explicit tolerant policy for byte-oriented
object layouts; complete-frame producer objects retain their ordinary clocks.

The shared map inserts silence for gaps, clips negative prefixes and later
overlaps, and keeps source decoding/history in file order. Source trimming
remains intact. Media seeks return the requested position after private codec
priming. Frame-duration advancement is checked for signed-nanosecond overflow;
the clock formula, rounding and one-millisecond quantization tolerance remain
[the same as packetized AAC](asf-clock.md#clock-contract).

There is no additional object-timestamp index: replay emits sparse events at
source-frame boundaries. Existing object, packet, index, allocation
and map limits remain in force. Cancellation is checked during packetization,
replay and frame iteration. Buffered packet reads now check cancellation
before copying already decoded audio, fixing a delayed-abort case exposed by
large PCM views.

## Verification

`python tests/verify-asf-gathered.py --bin PATH` writes and checks independent
fixtures; `--fixtures PATH` replays their pinned hashes. The
[Windows](../reports/asf-gathered-windows-verification.json) and
[Linux](../reports/asf-gathered-linux-verification.json) runs each pass:

- 374 files and 5,984 exact media seeks, with native WAVE/ADTS source PCM and
  an independent per-sample placement model. Fresh native codec seeks supply
  restart references for MPEG, noisy AC-3 and AAC/HE-AAC.
- Integer PCM, float32/64, multichannel masks, reduced valid precision,
  direct-out routing, G.711, 2–5-bit IMA, Microsoft and Duck ADPCM, Layer II/III,
  AC-3 and ADTS AAC/HE-AAC v1/v2. Layer I shares the MPEG implementation but
  still lacks a specific ASF interoperability fixture.
- Fragmented and compressed objects, spreading with a clock gap, foreign
  streams, negative/repeated clocks, cancellation of large clock terms,
  empty PCM/G.711 and a single object crossing the PCM packet-buffer boundary.
- Five bounded sparse-clock cases, nine rejected clocks, twelve alternating
  ASF/ordinary-FLV PCM reopens, and eight cancelled-open/read checks.
- 398,114,605 input/output guard checks, 1,024 protected prefixes and 2,048
  mutations. Direct protected parsing checks ASF framing; full-file decoding
  separately checks WAVE setup, replay and output canaries. Mutated reads stop
  after 128 calls and seek to the midpoint on call 64.

Six [MPEG metadata cases](../reports/asf-gathered-metadata-windows-verification.json)
retain exact native source PCM and trimming through gaps, negative clipping,
separate ID3v2 and ID3v1/APE tail objects. The
[buffered cancellation control](../reports/asf-gathered-buffer-cancel-windows-verification.json)
reproduces the old failure with only the cancellation placement reverted in a
test object; the current reader aborts before writing output and reopens cleanly
for both ASF and FLV.

Sixteen [published-binary controls](../reports/asf-gathered-published-controls-windows-verification.json)
per platform preserve the earlier executable and show the expected gap,
clipping and overflow differences without changing remote history.

The existing ASF audio/spreading/embedded-stream suites pass 93/72/88 checks
per platform, including catalogs, metadata, large sparse headers and seeks.
The real multitrack mux retains its independently measured 46 ms PCM and 21 ms
MP3 start delays. Synthetic continuous fixtures now carry coherent clocks.
Their full-decoder mutation probes bound reads and also seek into long valid
gaps; these are test work limits, not runtime duration limits. Linux replays
pinned Windows-prepared FFmpeg PCM and creates sparse files on its native
filesystem.

The prior 223-file AAC object-clock suite and the 177-file FLV and 145-file
Matroska clock suites remain regression checks. Native Windows muted lifecycle
checks cover PCM, ADPCM, MPEG and both AAC mappings, including paused seeks,
output recovery and exclusive sessions. Changed modules
[translate and assemble for Apple Silicon](../reports/asf-gathered-mac-assembly-verification.json);
native Mac execution and Linux device playback remain unverified.
