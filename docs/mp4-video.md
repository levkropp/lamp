# Native MP4 video packets and clocks

The shared assembly reader now indexes a selected AVC video track in a mapped
MP4/MOV file, including classic sample tables, movie fragments, composition
timestamps and a bounded edit list. It supplies the existing
[timestamped H.264 frontend](h264-packets.md) directly, without a whole-file
Annex B conversion or an external demuxer.

The [Windows video commands](mp4-play.md) now use this API for video-only MP4/MOV
playback, checking and export, with composition timestamps in the window. The
real audio clock, accurate seeking and synchronized playback remain separate
work. The existing MP4 audio reader is unchanged; complete audio-clock coverage
and unrestricted MP4 video/codec support are not established by this component.

## Ownership and API

The reader uses a zero-initialized, caller-owned **8,192-byte** context and the
Microsoft x64 calling convention, as do the other shared assembly components.
It has no mutable global state; two readers can operate independently.

| Function | Arguments | Result |
| --- | --- | --- |
| `video_mp4_open` | context, mapped input, input bytes, optional options pointer | 1 indexed, 0 failure |
| `video_mp4_next` | context, 80-byte output descriptor | 1 packet, 0 EOF, -1 sticky error |
| `video_mp4_rewind` | context, strictly greater unsigned external epoch | 1 rewound, 0 refused |
| `video_mp4_close` | context | releases index storage, clears context; idempotent |

Options are `{video_ordinal:u32, reserved_zero:u32, cancel_DWORD*:pointer,
epoch:u64}`. Null options select the first enabled supported clear AVC video
track, with epoch 1 and no cancellation pointer. A positive ordinal counts all
video tracks, including disabled and unsupported choices. Explicitly selecting
an unsupported choice fails; a disabled supported choice can be selected
explicitly. Audio and other handlers do not consume video ordinals.

Input and configuration remain borrowed until close. No compressed media bytes
are copied into the index. Context, input, options and output must be valid,
sufficiently sized, nonoverlapping and accessed by one serialized owner.
Initialized open failures still require close. Opening an already owned context
is refused without changing it. Close before freeing/unmapping the input.

The descriptor contains these fields, at byte offsets:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | pointer | borrowed sample data |
| 8 | u64 | sample bytes |
| 16 | i64 | decode time, nanoseconds |
| 24 | i64 | composition time, nanoseconds |
| 32 | u64 | positive decoder duration, nanoseconds |
| 40 | u64 | external epoch |
| 48 | u32 | flags: sync 1, no display 2, zero duration 4, empty sample 8 |
| 52 | u32 | zero-based decode-order sample index |
| 56 | i64 | edit-clipped display start |
| 64 | u64 | edit-clipped display duration; zero means hidden |
| 72 | u64 | unclipped display duration |

The first 48 bytes match `h264_packet_next`'s input. **Skip empty samples** before
calling the codec: its contract requires a nonempty access unit. Hidden nonempty
preroll/postroll may still be needed for reference history. Container sync flags
are metadata, not proof that a picture is a safe decoder restart point; accurate
H.264 seeking must also handle IDR/recovery and dependent pictures.

Packets remain in decode order; composition times can decrease for B pictures.
EOF and errors leave the output untouched. Cancellation is sticky. Rewind changes
only the cursor and external epoch, and refuses a non-increasing epoch or an
errored reader. The consumer must drain/release old submissions, reopen the codec
and manage output generations before replay. Rewind alone does not reset a GPU
decoder or implement seeking.

Errors are 1 malformed input, 2 unsupported selection/layout, 3 bounded resource
or clock-range limit, 12 allocation failure and 61 cancellation.

## Layout and clock boundary

Classic tables support `stsz`, 4/8/16-bit `stz2`, changing samples per chunk in
`stsc`, `stco`/`co64`, run-length `stts`, unsigned version-0 and signed version-1
`ctts`, and optional `stss`. An absent sync table marks nonempty samples sync;
an explicitly empty table marks none. Chunk placement may be nonmonotonic, and
samples may occupy multiple `mdat` payloads. Every nonempty selected sample must
fit wholly inside one such payload. An empty sample dereferences no bytes and
may have any offset within the file, including zero or EOF.

Movie fragments support `trex`, `tfhd`, `tfdt` and `trun`, explicit bases,
default-base-is-moof and inherited bases after preceding track fragments. Sizes
of ignored tracks are followed to resolve implicit bases. Per-run data offsets
are signed; duration/size/flags can come from defaults or per-sample fields.
Version-0/1 composition offsets and 32/64-bit decode times are supported. An
omitted `tfdt` continues the selected track's previous decode end; backwards
decode times and unsigned decode-counter overflow fail. Hybrid files can contain
both classic samples and fragments.

One self-contained local data reference, one `avc1`/`avc3` description and one
borrowed `avcC` record are supported. Decoder configuration/profile validation
remains the H.264 frontend's responsibility. External data, protected selected
samples, changing sample descriptions/configurations, other codecs and general
edit programs remain unsupported. Unknown box payloads are skipped using
validated 32/64-bit boundaries; a zero-size box extends to its parent end.

Movie/media header versions 0 and 1 and nonzero unsigned 32-bit scales are
supported. Edits may contain leading empty intervals and one nonnegative active
media start at rate 1. Leading empty intervals shift the movie origin. An active
edit duration of zero spans subsequent media; empty-only edits display nothing.
Later active/empty edits, reverse playback and dwell/rate changes fail explicitly.
The zero-duration active-edit rule is documented in the
[W3C ISO BMFF byte-stream note](https://www.w3.org/TR/2026/NOTE-mse-byte-stream-format-isobmff-20261109/#initialization-segments).
The file reader also supports general fragment addressing and inherited decode
times; this is not an MSE or network implementation.

All clock conversion uses integer arithmetic, with signed wide intermediates and
nanosecond results rounded toward negative infinity. Fractions from different
movie/media scales are combined before rounding, including negative preroll.
Overflow fails instead of wrapping. A separate stable presentation index sorts
by composition time and then decode index. Display duration extends to the next
composition time; the final displayed sample uses its decode span, following
[Apple's composition-time description](https://developer.apple.com/documentation/quicktime-file-format/composition_offset_atom).
Equal timestamps can produce zero display duration. Zero/sub-nanosecond decode
spans retain that display information but use duration 1 for the codec contract.
Display intervals are clipped to the supported edit; raw decoder times remain.

## Bounds and verification

The index admits at most 1,048,576 selected samples, 65,536 `mdat` ranges, 256
track IDs/default records, 4,096 edits and 16 MiB per selected packet. Box visits
and total fragment sample work each have a 16,777,216 limit. Index reservations
commit in 64 KiB increments. Record/range reservations and the presentation sort
use at most **53 MiB**, plus the context and platform allocation rounding. Input
mapping and downstream codec/GPU allocations are separate. Sorting is bounded
O(n log n); cancellation is checked during parsing, expansion and heap work,
and again before publishing a ready reader.

- **15 encoded files / 1,185 GPU images / 56,277,720 NV12 bytes** match independent
  FFmpeg references exactly. FFprobe configuration and every extracted payload
  byte, offset, DTS, PTS and sync flag agree before hardware submission. Cases
  include Main/High B pictures, Baseline, slices, crops, VFR, classic/fragmented
  hybrids, explicit/implicit bases, audio-first tracks and fragment interleaving.
- Windows/Linux each pass 188 independent rational-clock/layout models
  (1,748 packets), 50 rejected layouts, 16 track choices, ownership/epoch tests,
  allocation-failure/cancellation injection, the exact million-sample limit and
  the 65,536/65,537 media-range boundary. Serialized encoded packets agree.
- Protected-prefix and deterministic-mutation tests cover four model layouts and
  real classic/interleaved files: 18,444 opens per platform. Fingerprints agree.
  Synthetic/malformed payloads remain CPU-only.
- Five isolated broken objects prove the suite detects missing final cancellation,
  media outside `mdat`, signed interpretation of unsigned composition offsets,
  lost fractional carry and an incorrectly hidden zero-duration active edit.
- Every prior runtime object remains byte-identical (113 Windows, 86 Linux).
  Six linked audio decode comparisons per platform match the previous build;
  Windows imports/resources pass. Apple Silicon translation and assembly pass;
  native Mac execution of this reader remains unverified.

FFmpeg, FFprobe, Python and C are test-only. The runtime reader is original
assembly and links no external demuxer or codec library.

```powershell
python tests/verify-mp4-video-gpu.py --bin bin/mp4-video-check --generate
$env:LAMP_OUT='bin/mp4-video-check'
python tests/verify-mp4-video.py --large --controls --encoded-dir tests/generated/mp4-video
```

Linux can reuse the generated encoded corpus, setting `LAMP_OUT` to its build
directory for the second command. Reports:
[Windows](../reports/mp4-video-windows-verification.json),
[Linux](../reports/mp4-video-linux-verification.json),
[hardware images](../reports/mp4-video-gpu-verification.json),
[regressions](../reports/mp4-video-regression-verification.json),
[Mac assembly](../reports/mp4-video-mac-assembly-verification.json).
