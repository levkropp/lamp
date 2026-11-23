# H.264 reference pictures

Windows source builds now decode and present progressive Baseline/CAVLC H.264
I/P pictures, including non-IDR I pictures and retained short/long-term references.
The existing [play/check/export commands](h264.md) accept these elementary Annex B
files. B pictures, higher bit depths/chroma formats, video containers, accurate seeking and
audio/video synchronization remain unfinished.

## Parser and reference ownership

Original shared assembly in `src/h264_dpb.inc` adds a compact 16-record decoded
picture buffer to the 16,384-byte parser context. Each record identifies a surface,
frame number, full picture-order count and optional long-term index. Before
marking a new picture, the parser snapshots all retained pictures into DXVA
`RefFrameList`, `FieldOrderCntList`, `FrameNumList` and `UsedForReferenceFlags`.
The destination excludes every reference in that snapshot, including a picture
which will be removed after decoding the current picture.

Frame-number wrap, POC types 0/2, sliding-window eviction, IDR long-term marking
and adaptive memory-control operations 1–6 are implemented. Marking is applied
after the current submission snapshot. MMCO5 resets the stored current frame
number/order count and subsequent counters. Long-term bounds, missing targets,
conflicting commands and DPB overflow reject. Header work is bounded to 64
memory-control operations and 32 list modifications per slice, at most 16 active
P references and the existing 256-slice/16 MiB compressed-picture limits.

The current output path follows decode order. Streams requiring reordered output
reject when POC decreases or repeats outside an IDR/MMCO5 reset. Missing/inferred
frame-number gaps, POC type 1, fields/MBAFF, B/SP/SI slices,
redundant pictures, slice groups and changing parameter sets remain unsupported.
Unsupported input fails preflight before creating an export or opening the video
window. Slice coefficient/entropy conformance is delegated to the driver.

## Windows surfaces and presentation

`win_video_open_refs(context,width,height,max_num_ref_frames)` allocates at least
`max(max_num_ref_frames,1)+1` array slices, also respecting the driver's minimum.
The legacy `win_video_open` retains its minimum-driver-pool entrypoint. Pools
remain capped at 32 surfaces and 128 MiB of nominal NV12 pixels including staging;
driver overhead is additional. Each slice has an owned decoder output view.
Partial creation and close release every view exactly once.

Submission validates current/reference indices against the pool, rejects a
destination also used as a reference and rejects surfaces never successfully
decoded. The frontend supplies the normative reference validity/marking rules.
Only successful decoding changes the current output slice; readback copies that
slice. The [GPU presenter](video-present.md) changes its video-processor input
view when the current slice changes, after the previous GPU fence completes.
The normal presentation path continues to keep pixels on the GPU.

The [Main/High extension](h264-profiles.md) now supplies CABAC, explicit P weights,
8×8 transforms and custom scaling lists on top of this reference map.

## Recorded Baseline verification

The [Windows report](../reports/h264-reference-windows-verification.json) records
12 encoded sequences / **626 GPU images**, with all **44,047,650 NV12 bytes** equal
to FFmpeg 8.0.1 references on the RTX 5070 Ti / driver 32.0.16.1692. Coverage
includes 1/3/8/16 references, four slices, cropped non-square pixels, 1280×720,
frame-number wrap, POC-LSB wrap, non-IDR I pictures, IDR long-term references and
all six adaptive marking operations. FFmpeg header traces independently verify
frame numbers and record the marking commands present in the inputs.

The POC/marking/non-IDR I cases rewrite only headers of genuine flat CAVLC
encodes, preserving coded coefficients. Each transformed file is first decoded
by FFmpeg and checked byte-for-byte against the original encode's decoded
pixels. Original streams, raw inputs, both reference outputs and transformed
streams are retained/hash-pinned. CPU-only synthetic bodies and mutations are
never submitted to hardware.

Windows and [Linux](../reports/h264-reference-linux-verification.json) pass the
same 25 syntax/marking cases and produce identical submission packets for the
encoded corpus. Each passes **52,672,916 guarded checks / 3,075 opens**, with the
same mutation fingerprint. These include protected prefixes, deterministic
mutations, cancellation, sticky failures and reopen. The Windows mock passes
472,548 checks, including 24 ordinary fallible-call positions, all 26 creation
failures for a 17-surface pool, reference-index rejection and selected-slice
readback. [Apple Silicon translation/assembly](../reports/h264-reference-mac-assembly-verification.json)
passes; native Mac execution and Linux/Mac GPU playback remain unverified.

The [presentation report](../reports/h264-reference-present-verification.json)
checks **43 rendered images / 3,225 RGB channels**, with at most one 8-bit level
of conversion difference, including changing P-picture surfaces. A real
90-frame reference-dependent sequence passes pause, exact single-frame stepping,
resize, minimize/restore, three-second EOF timing, replay, cancellation and close.
The shipping CLI is also exercised in its own hidden child window. Presenter
failure mocks cover switching the current input view. The [current IDR regression](../reports/h264-reference-idr-windows-verification.json)
retains all 115 exact images / 64,813,440 bytes; six-format audio smoke and binary
resource/import checks also pass.

```
python tests/verify-h264-reference.py --bin bin/h264-reference-check --generate
python3 tests/verify-h264-reference.py --bin build/h264-reference-check
python tests/verify-video-present.py --bin bin/h264-reference-check --references --report reports/h264-reference-present-verification.json
python tests/verify-h264-file.py --bin bin/h264-reference-check --fixtures tests/generated/h264-reference-idr --generate --controls
```

Both hosts can share the generated `--fixtures` folder. These establish image
correctness and hidden-window controls on one hardware adapter; they do not
measure visible latency, CPU/GPU utilization, power or synchronized mixed media.
The separate audio-master scheduler, timestamped container video queues, seeking,
broader profiles/codecs and milestone 4's remaining gates stay open.

The implementation follows [ITU-T H.264 (08/2024), clauses 7.3/7.4 and 8.2](https://www.itu.int/rec/T-REC-H.264-202408-S/en)
and Microsoft's DXVA H.264 picture/surface contract recorded in the
[backend notes](windows-video.md). Runtime and codec work remains original
assembly; FFmpeg, C and Python remain test-only.
