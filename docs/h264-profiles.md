# Main/High H.264 I/P pictures

Windows source builds now accept progressive 8-bit 4:2:0 **Baseline, Main and
High I/P pictures** through the existing [play/check/export commands](h264.md).
Main/High add CABAC, explicit P-picture luma/chroma weights and the High profile's
8×8 transform and custom quantization matrices. B pictures/reordered output,
10-bit/4:2:2/4:4:4, transform bypass, bottom-field POC deltas, fields and video
containers remain unfinished.
This does not establish general playback of every Main/High file.

## Header and matrix contract

The original assembly SPS/PPS reader accepts profile IDs 66/77/100 and preserves
the existing [reference-picture limits](h264-references.md). High SPS extensions
require chroma format 1, zero bit-depth offsets and no transform bypass. Baseline
still rejects CABAC/weighted prediction, and Baseline/Main reject 8×8 mode and
custom matrices. A stream cannot enable features by mislabelling its profile.

`src/h264_scaling.inc` reads each signed delta in −128…127, handles early zero
termination and explicit default lists, and implements sequence fallback A and
picture fallback A/B. The eight 4:2:0 lists occupy 224 bytes in DXVA zig-zag
order. A separate 224-byte sequence copy supports PPS inheritance and overrides.
The parser context remains **16,384 bytes**, with no new scratch allocation.
Default list constants match the pinned BSD-licensed Chromium reference and
H.264 Tables 7-3/7-4; [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES) preserves the
attribution/license. All runtime parsing remains assembly.

P-picture weights are read for at most 16 active references. Luma/chroma
denominators are bounded to 0…7, and explicit weights/offsets to −128…127.
Absent weights retain the standard inferred values, including 128 for denominator
7. The raw-slice driver applies the supplied table; LAMP does not convert pixels
on the CPU. CABAC initialization indices are bounded to 0…2 and alignment bits
must be one. Both signed deblocking offsets are checked before alignment.

DXVA picture flags now signal weighting/8×8 mode and entropy coding. The existing
hardware backend accepts 4×4 or 8×8 transforms while retaining its progressive
NV12, surface-index, capacity and resource-ownership checks. Hardware/profile
availability still depends on the default adapter; software/alternate-adapter
fallback is not yet implemented.

## Verification

The [Windows report](../reports/h264-profile-windows-verification.json) records
**14 encoded sequences / 506 GPU images**, with all **75,255,660 exported NV12
bytes** equal to FFmpeg 8.0.1 references on the RTX 5070 Ti / driver 32.0.16.1692.
Cases include Main CABAC, luma/chroma-weighted fades, explicit changed chroma
offsets, High CABAC/CAVLC with 8×8 transforms, JVT/asymmetric custom matrices,
SPS inheritance/PPS rule B, nonzero deblocking offsets, four slices, crop/SAR,
16 references and 1280×720. Encoder statistics record actual 8×8 use; independent
FFmpeg traces verify profile/entropy/transform flags, weights and frame numbers.

Scaling relocation cases preserve the original coded slices and must reproduce
the original software-decoded pixels before the GPU comparison. The explicit
chroma-offset case preserves the CABAC payload and intentionally changes the
prediction pixels; FFmpeg independently decodes the resulting valid stream to
supply the new reference. Original/transformed inputs, references and normalized
header traces are hash-pinned.

Windows and [Linux](../reports/h264-profile-linux-verification.json) pass the
same **33 CPU syntax cases**, including fallback A/B, explicit defaults, early
zero termination, scaling value 255, 16 weights, signed endpoints, invalid
denominators/deltas, CABAC alignment/initialization and both deblocking offsets.
Each passes **51,389,552 guarded checks / 3,075 opens**, with identical mutation
fingerprints and encoded submission packets. Synthetic coefficient bodies and
mutations never go to the GPU. An isolated test object omitting only the beta
offset parse rejects the valid nonzero-beta CABAC case, reproducing the header
ordering failure that the shipping parser fixes.

Both [Main](../reports/h264-profile-main-present-verification.json) and
[High](../reports/h264-profile-high-present-verification.json) pass 43 rendered
image checks / 3,225 RGB samples each, with at most one 8-bit level of conversion
difference. Their real 90-picture sequences pass pause, exact single-frame steps,
resize, minimize/restore, EOF timing, replay and cancellation; the actual CLI
also opens/closes its own hidden child window. Positive fixtures explicitly
disable B pictures. Genuine B-picture and High10 files reject before windows.
No test sends global desktop input or audio.

The current [reference-picture regression](../reports/h264-profile-reference-windows-verification.json)
retains 626 exact images / 44,047,650 bytes; the
[IDR regression](../reports/h264-profile-idr-windows-verification.json) retains
115 exact images / 64,813,440 bytes. Binary import/resource and six-format audio
decode smoke checks pass. [Apple Silicon translation/assembly](../reports/h264-profile-mac-assembly-verification.json)
passes; native Mac execution and Linux/Mac GPU presentation remain unverified.

```
python tests/verify-h264-profile.py --bin bin/h264-profile-check --generate --controls
python3 tests/verify-h264-profile.py --bin build/h264-profile-check
python tests/verify-video-present.py --bin bin/h264-profile-check --references --profile main --report reports/h264-profile-main-present-verification.json
python tests/verify-video-present.py --bin bin/h264-profile-check --references --profile high --report reports/h264-profile-high-present-verification.json
```

Both hosts can share the generated `--fixtures` folder. Controls require LLVM on
PATH or the documented local WSL toolchain. These prove image and hidden-window
control correctness on one adapter. Visible latency, dropped frames, CPU/GPU
cost, audio synchronization, seeking and the remaining milestone 4 gates stay open.

The header implementation follows [ITU-T H.264 (08/2024), clauses 7.3/7.4](https://www.itu.int/rec/T-REC-H.264-202408-S/en)
and the DXVA picture/matrix contract linked in the [backend notes](windows-video.md).
FFmpeg and C/Python helpers remain test-only.
