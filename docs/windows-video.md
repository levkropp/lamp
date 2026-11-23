# Windows hardware video backend

This backend now feeds the experimental [Windows file check/export commands](h264.md).
The assembly module `src/win/video.s` submits H.264 I/P/B pictures directly to
Direct3D 11 and reads back decoded NV12 images. The normal Windows build links it
with the assembly Annex B frontend. Source builds can check files and export
cropped NV12 or use the [GPU video-only window](video-present.md). The
[reference-picture extension](h264-references.md) adds short/long-term DPB
surfaces; the [Main/High extension](h264-profiles.md) adds CABAC, P weights and
8×8/custom quantization. The [B-picture extension](h264-b.md) adds bidirectional
prediction, output holds and display order. The real audio clock/scheduler
connection remains unfinished. The earlier backend
report below retains its component-only scope; the file integration has its own
current reports.

## Current boundary

The backend uses `D3D11CreateDevice` with the default **hardware** adapter and
video support, then requests `ID3D11VideoDevice`/`ID3D11VideoContext`. It selects
the H.264 VLD NoFGT profile, NV12 and an unencrypted raw-bitstream configuration
with short slice controls (`ConfigBitstreamRaw = 2`). It uses the returned
minimum surface count, limited to 1–32, and a texture-array configuration.
Other adapters, configurations and software fallback are not implemented.

The current submission contract is a progressive, 8-bit 4:2:0 **I/P/B picture with
retained reference surfaces**, at coded widths/heights from 16 through 4,096 in
multiples of 16. Dimensions, current/reference surface indices, bitstream bounds
and contiguous short-slice locations are checked
before calling the driver. The caller must provide consistent, already parsed
picture/matrix/slice data; this API is not a validator for arbitrary H.264 files.
It accepts VCL NAL types 1/5 and 4×4/8×8 transforms while rejecting field pictures.
The assembly frontend enforces the supported 8-bit profile syntax and normative
reference marking. The [current image reports](h264-references.md#verification)
extend the historical IDR component evidence below.

A zeroed, single-owner **1,024-byte context** retains seven base COM resources and
one output view per array slice (up to 39 references total).
There are no heap allocations in the assembly. The texture pool plus one staging
surface is limited to **128 MiB of nominal NV12 pixels**; driver allocations,
alignment and overhead are additional. Compressed frames are limited to 16 MiB
and 256 slices, and must fit the actual driver buffer capacities. The bitstream
size includes 128-byte padding. Short-slice structures are packed **10-byte**
SDK records; the picture and matrix records are 1,040 and 224 bytes.

The exported Microsoft x64 ABI functions are:

| Function | Arguments | Result |
| --- | --- | --- |
| `win_video_open` | context, coded width, coded height | HRESULT; partial resources released on failure |
| `win_video_open_refs` | context, coded width, coded height, max reference count | HRESULT; pool also includes a free destination surface |
| `win_video_open_pool` | context, coded width, coded height, required pool count (2–32) | HRESULT; used for reference and output holds, subject to driver minima and memory cap |
| `win_video_decode` | context, pointer to 48-byte submission | HRESULT; picture selects a destination distinct from retained references |
| `win_video_select` | context, retained surface index | HRESULT; selects an initialized output, preserving the current selection while readback is pending |
| `win_video_readback` | context, destination, capacity in bytes | HRESULT; packed NV12 (Y then interleaved UV) on success |
| `win_video_close` | context | releases resources, clears context; idempotent |

The submission record contains picture pointer, matrix pointer, bitstream pointer,
`bytes:u32`, zero reserved `u32`, slices pointer, `count:u32`, and zero reserved
`u32`. All caller storage must be valid, sized and nonoverlapping with the context.
Access is serialized by the caller; the backend does not synchronize workers.
Repeated open on an owned context refuses instead of losing resources.

Every acquired compressed buffer is released, including a short/null buffer.
After a frame has begun, failures attempt `DecoderEndFrame` before returning.
Driver failures make the context unusable until close/reopen. Input rejection
does not submit work. A busy `DecoderBeginFrame` returns `E_PENDING` for retry.

Readback copies the successful current array slice once and flushes, then maps
with `DO_NOT_WAIT`. A busy GPU
returns `E_PENDING` without touching the output; retrying does not enqueue another
copy. The owner can cancel between attempts and close the context. A new decode
is refused while that copy is pending. Successful maps validate the pointer and
row pitch, copy only visible coded-row bytes, and always unmap. The caller must
use a deadline/event policy for retries. This does not promise that every driver
call can be interrupted or that hung hardware recovers without the OS/driver.

## Verification

Build the ordinary Windows objects, then run on a machine with the required GPU
profile (the controls also require LLVM on PATH or the local WSL toolchain):

```
python tests/verify-windows-video.py --bin bin/windows-video-check --controls
```

The [recorded native report](../reports/windows-video-verification.json) covers an
Intel Core i7-12700KF / NVIDIA GeForce RTX 5070 Ti, driver 32.0.16.1692, on Windows
11 build 26300. Six generated Baseline/CAVLC, all-IDR, single-slice files contain
48 pictures: **64×64, 192×112, 320×240, 640×368, 1280×720 and 1920×1088**. All
**40,181,760 packed NV12 bytes** equal FFmpeg 8.0.1 software-decoded references
exactly. The report pins the FFmpeg executable and generated compressed/reference
files. FFmpeg and C/Python run only in tests, never as player dependencies.

The independent mocked interface test passes **381,069 checks**, including all
22 fallible COM call positions, partial creation cleanup, eight short/null driver
buffers, invalid mapped pointers/pitches, busy begin/map retries, one-copy
readback, 14 invalid submissions rejected before the driver, resource release,
and context/output/buffer canaries. Five isolated deliberately broken objects
each fail: omitted capacity checking, omitted releases, repeated copies, blocking
maps and missing syntax-field validation. No mock or broken object enters the
player. Image tests also exercise close/reopen across sizes and padded GPU rows.

This historical component coverage predates the window and P-picture extension.
It establishes no container demuxing, B-picture/reordered-output and higher-bit-depth coverage, accurate
video seeking, screenshots, audio synchronization, multi-adapter behavior,
software fallback, native Linux/Mac video, power use, playback latency or
performance advantage. Oracle elapsed times and retry counts are test observations,
not playback benchmarks. Milestone 4 remains open.

## Sources and next integration

This is original assembly written against Windows SDK 10.0.26100 headers and
Microsoft's [Direct3D 11 video interfaces](https://learn.microsoft.com/en-us/windows/win32/medfound/supporting-direct3d-11-video-decoding-in-media-foundation)
and [DXVA H.264 specification](https://www.microsoft.com/en-us/download/details.aspx?id=11323).
The assembly frontend and independent test-only header reader follow [ITU-T H.264 (08/2024)](https://www.itu.int/rec/T-REC-H.264-202408-S/en).
Chromium's BSD-licensed [DXVA picture mapping](https://chromium.googlesource.com/chromium/src/+/135.0.7049.84/media/gpu/windows/d3d11_h264_accelerator.cc)
and [D3D11 wrapper](https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/windows/d3d11_video_decoder_wrapper.cc)
were consulted for interoperability; no C/C++ implementation is linked or copied
into the runtime. Copyrighted specifications are not redistributed.

The assembly frontend now supplies bounded file-derived decode metadata to the
GPU video window. Next, connect actual container timestamps and the
[audio-master scheduler](video-sync.md). Extend H.264 profile coverage,
followed by HEVC, VP9 and AV1. Their
software fallbacks and other milestone requirements remain explicit roadmap work.
