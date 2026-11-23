# Timestamped H.264 packet frontend

The shared assembly frontend now accepts an AVC decoder configuration record
(`avcC`) and complete length-prefixed access units with timestamps. This is a
component for connecting MP4/Matroska/FLV video to the existing hardware decoder.
**The shipping video commands still accept Annex B files only.** Native container
video extraction, timestamp-driven presentation, the real audio clock and seeking
remain unfinished.

## API and ownership

The existing 16,384-byte, caller-owned parser context and Microsoft x64 ABI remain
unchanged. Windows and Linux build the same assembly; Apple Silicon translation
and assembly are checked separately. No C codec or external decoder is linked.

| Function | Arguments | Result |
| --- | --- | --- |
| `h264_packet_open` | parser, configuration payload, configuration bytes, optional cancellation DWORD pointer | 1 configured, 0 failure |
| `h264_packet_next` | parser, pointer to a 48-byte packet descriptor | 1 complete picture at `HP_DESC`, -1 sticky error |
| `h264_close` | parser | releases compressed scratch, clears context; idempotent |

The packet descriptor is `{data:pointer, bytes:u64, dts_ns:i64, pts_ns:i64,
duration_ns:u64, epoch:u64}`. Duration must be positive and no greater than
`INT64_MAX`; `pts_ns + duration_ns` must fit signed 64-bit. DTS and PTS may be
negative for preroll. DTS must not decrease after the first successful packet.
PTS may decrease in decode order, as required for B pictures. Epoch is a nonzero
caller generation and must stay constant until close/reopen; it is separate from
the codec's IDR/MMCO5 output-order epoch.

Successful calls preserve timestamps in `HP_PACKET_DTS`, `HP_PACKET_PTS`,
`HP_PACKET_DURATION` and `HP_PACKET_EPOCH`. Failed calls retain the last committed
packet timestamps and leave a sticky error. Their other parser state may already
have advanced; callers must close and reinitialize before retrying input after
an error. Cancellation uses the existing error 61. Seek/restart requires a fresh
configuration and suitable IDR input, rather than changing the epoch on a live DPB.

Configuration bytes are consumed/copied during open and need not outlive it.
Each access-unit buffer must stay valid through `h264_packet_next`; the returned
compressed submission lives in the parser's existing scratch. The caller must
complete any pending hardware submission before the next parser call, and retain
output surfaces separately until presentation/readback completes. Access is
serialized by one owner. Context, descriptor and input storage must be valid,
sized and nonoverlapping. Use a new/closed context for open and close after a
partly initialized failure.

## Configuration, framing and limits

The configuration reader accepts version 1 and NAL length widths **1, 2 or 4**.
Reserved bits are checked. One SPS/PPS pair is supported, at most 4 KiB each;
record profile/compatibility/level must match the SPS. High's optional extension
must describe 8-bit 4:2:0 with no SPS extensions. Older High records omitting that
extension are accepted. Multiple or changing parameter sets, higher bit depths,
other chroma formats and the existing unsupported H.264 features remain explicit
[profile limits](h264.md#supported-boundary).

The packet reader walks length-prefixed NAL units directly in the input. It
shares the existing slice, quantization, DPB and DXVA assembly code with Annex B
input. There is no whole-file conversion or second 16 MiB input-copy allocation.
The existing compressed scratch remains lazily committed and reused. Each packet
is at most 16 MiB, with at most 4,096 NAL reads and the existing 256-slice picture
limit. Zero/truncated/oversized lengths and forbidden headers fail before an
out-of-bounds read. One packet must produce exactly one picture; a second picture
is rejected, as are empty or parameter-only packets. Identical in-band SPS/PPS
and supported trailing non-VCL units are allowed.

The configuration layout follows ISO/IEC 14496-15. The valid length widths and
record fields were cross-checked against the BSD-licensed
[Chromium configuration reader at a fixed revision](https://chromium.googlesource.com/chromium/src/+/4220b02361218e0ab36eb67203390185ded7bb86/media/formats/mp4/box_definitions.cc).
The implementation is original assembly; no C++ parser code is copied or linked.

## Verification

Test-only FFprobe extracts configuration and packets from six independently
encoded MP4 files. LAMP itself does not invoke FFprobe or FFmpeg. Thirteen
packetizations cover the length widths, Baseline/Main/High, CABAC/CAVLC, B-pyramid,
multiple slices, crops, negative initial DTS and variable frame intervals.

- **795 GPU image comparisons / 60,577,200 NV12 bytes** match independent FFmpeg
  references exactly. Each decoded picture is compared with the reference at its
  presentation rank, while input stays in decode order.
- Windows/Linux serialize identical picture, matrix, slice and bitstream bytes
  for all packetizations. They pass 38 configuration/timestamp/boundary cases,
  including negative preroll, equal coarse DTS, trailing filler, in-band parameter
  repeats and integer boundaries.
- Protected-prefix and deterministic-mutation tests cover both Main/High records
  and packets, with 6,238 opens per platform. The mutation/result fingerprints
  agree. These malformed streams remain CPU-only.
- Five isolated CPU-only broken objects prove the checks detect accepting the
  reserved length width, inconsistent profile, changed epoch, reversed DTS or a
  second picture. No deliberately broken object is submitted to a GPU.

The native test requires a supported D3D11 hardware adapter; Linux verifies
parsing/serialization only. This establishes the packet/frontend contract,
rather than end-to-end container playback or audio/video synchronization.

```powershell
python tests/verify-h264-packet.py --bin bin/h264-packet-check --generate --controls
```

The Linux invocation can reuse `--fixtures` from Windows. Recorded results:
[Windows](../reports/h264-packet-windows-verification.json),
[Linux](../reports/h264-packet-linux-verification.json),
[Mac translation/assembly only](../reports/h264-packet-mac-assembly-verification.json).
