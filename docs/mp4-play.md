# MP4/MOV video playback and export

Windows source builds now accept supported AVC video in MP4/MOV, including
fragmented files, in the existing video commands:

```powershell
lamp-cli.exe --video-check movie.mp4
lamp-cli.exe --video-decode movie.mov frames.nv12
lamp-cli.exe --video-play movie.mp4
```

These operations select the first enabled supported clear AVC video track.
They remain video-only: accompanying audio is skipped, and the audio-library
window stays separate. The video commands accept one input, plus a new output
path for export. Audio options and explicit video-track selection are not yet
accepted. Decoder [profile/hardware limits](h264.md#supported-boundary) and
[MP4 layout/edit limits](mp4-video.md) apply. There is no external demuxer,
FFmpeg subprocess or software fallback in the runtime.

The reader recognizes common MP4/MOV opening boxes, including `ftyp`, `moov`,
`mdat`, `free`, `skip`, `wide`, `uuid`, `pdin`, `sidx` and `styp`. Unambiguous
three/four-byte Annex B prefixes retain the existing elementary-stream path.
Codec headers and every nonempty access unit are preflighted before GPU creation
and output-file creation. Container indexing also completes before decoding.
This can take time on large files; cancellation remains cooperative.

## Timestamps and controls

MP4 presentation uses the reader's integer composition timestamps and supported
edit-list intervals. Decode order stays separate from presentation order. Hidden
nonempty preroll and postroll still decode to preserve reference history; empty
samples are skipped. Only pictures with a nonzero clipped display interval enter
presentation/export. Export remains headerless, cropped NV12 in display order,
without frame duplication to fill timestamp gaps. The printed frame count is
the number of visible output pictures, rather than the number of coded inputs.

The video window uses a video-only QueryPerformanceCounter clock. It waits for
each file timestamp, handles a leading empty-edit gap, holds the last image
through its interval and freezes at the indexed display end. VFR is independent
of the SPS's nominal frame rate. Space pauses/replays, period steps, Esc closes,
and resize/minimize behavior remains available. A step jumps the frozen media
position to the next visible picture's timestamp. Replay creates a new external
epoch and reopens the parser after releasing old output ownership.

The window can prepare the next picture while retaining the displayed surface.
Looking ahead does not select or release that surface; paused redraws and resize
therefore keep the displayed image. Hidden pictures do not consume step requests.
The next-frame probe also drains hidden postroll, so the final paused step can
reach EOF without an extra request.

The real audible-sample clock, synchronized audio, accurate seeking, a connected
late-frame drop policy, other video codecs/containers and higher bit depths remain
unfinished. This feature does not complete the roadmap's synchronization gate.

## Queue and source contract

The Windows display-order bridge now uses a caller-owned **1,536-byte** context.
Its 17 bounded 64-byte records retain codec epoch/POC/surface, raw PTS/duration,
external epoch, flags/index and clipped display interval. The old Annex B source
remains the default. `win_video_stream_set_source(stream, next, context)` binds
an optional borrowed callback before work starts; rebinding is refused.

The callback receives `(context, parser, packet80*)`. It returns 1 parsed picture,
0 EOF, -1 failure or 2 cooperative yield. The packet layout is
[`video_mp4_next`'s descriptor](mp4-video.md#ownership-and-api). Empty packets must
be consumed by the callback; a successful picture must have a positive decoder
duration, a nonzero constant external epoch and a consistent bounded display
interval. Source errors, changed epochs and reversed visible timestamps stick.
The consumer must finish its GPU reads before calling the bridge again.

`win_video_stream_peek` pumps bounded work and returns the next visible interval
in `VS_HEAD_PTS`/`VS_HEAD_DURATION`, retaining all pins and the prior backend
selection. `win_video_stream_next` consumes/selects the same head. Both return
S_OK, S_FALSE at EOF, E_PENDING for retry or a sticky failure. A call admits at
most 32 new parsed inputs; decode/readback retries remain bounded by the owner.

The shared `video_mp4_h264_next` callback skips at most 128 empty samples before
yielding, and feeds nonempty access units to the existing packet frontend.
`video_mp4_h264_reset` advances the source epoch, rewinds and reopens that parser.
Callers must already have released/drained old work. It owns neither input nor
the MP4 index. The native window state is now **4,096 bytes**, containing the
expanded bridge and the unchanged presenter in disjoint regions.

## Verification

Tests use known encoded files and independent reference images before hardware
submission. Opaque or malformed models remain CPU-only.

- The public check/export matrix covers all 15 earlier MP4 reader inputs:
  1,185 images / 56,277,720 exact reference bytes, including Main/High B pictures,
  Baseline, slices, crops, VFR, mixed audio/video and fragment-addressing variants.
- Native window tests cover CFR, seven-second VFR with a 30 fps codec header,
  and a 750 ms leading gap with preroll and clipped postroll. Each stepped image
  reaches its independently calculated timestamp. Pause with a prepared future
  head, paused resize, EOF, replay, cancellation and uninterrupted file duration
  are checked through an owned hidden window.
- 544 existing output permutations and 136 timestamped/hidden-picture
  permutations verify pins and metadata. Six invalid timestamp cases stick;
  isolated altered objects prove the ownership and timestamp checks fail when
  those policies are removed.
- Windows/Linux each compare the shared callback against direct demux/parser
  calls for all 1,185 encoded pictures, replay/cancellation and a 300-empty-sample
  run requiring two cooperative yields. Apple Silicon translation/assembly
  passes; native Mac execution and Mac video presentation remain unverified.
- Existing Annex B image, presentation and window checks remain regressions.
  Existing output files are preserved. Controlled cancellation/write failures
  remove only the partial export created by that invocation. The public MP4
  `--video-play` path also opens/closes its own PID-owned hidden test windows.

Recorded reports: [MP4 window](../reports/mp4-play-windows-verification.json),
[public exports](../reports/mp4-export-windows-verification.json),
[MOV and fast-start](../reports/mov-video-windows-verification.json),
[Windows source](../reports/mp4-source-windows-verification.json),
[Linux source](../reports/mp4-source-linux-verification.json),
[regressions](../reports/mp4-play-regression-verification.json),
[Mac assembly](../reports/mp4-play-mac-assembly-verification.json).

```powershell
python tests/verify-mp4-play.py --bin bin/mp4-play-check --generate
python tests/verify-mp4-export.py --bin bin/mp4-play-check
python tests/verify-mov-video.py --bin bin/mp4-play-check
$env:LAMP_OUT='bin/mp4-play-check'
python tests/verify-mp4-source.py
```
