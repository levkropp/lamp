# Windows video presentation and playback

Windows source builds provide an experimental video-only window for the
[supported H.264 Annex B subset](h264.md), including [Main/High B pictures](h264-b.md):

```
lamp-cli.exe --video-play file.h264
```

Space pauses or resumes, `.` advances one picture while paused, and Esc or Q
closes the window. At the end, the last picture stays visible and Space replays
the file. The audio-library window remains separate. Video containers, audio,
seeking, higher bit depths/chroma formats and other video codecs are not yet
connected to this path.

## Image path

Original assembly in `src/win/video_present.s` uses the decoder's default
hardware D3D11 device, an NV12 video-processor input view, an owned BGRA8 output
texture and a two-buffer flip-discard HWND swapchain. Normal playback keeps
pixels on the GPU. A GPU event query completes before the caller can reuse the
decoder's selected output slice; retries do not enqueue duplicate blits or copies.
Present uses `DO_NOT_WAIT`; busy operations return `E_PENDING` to the message
loop. There is no alternate-adapter or software fallback.

SPS crop offsets select the source rectangle. Integer aspect fitting includes
sample aspect ratio and produces opaque black letterboxing. The video processor
performs full/limited nominal-range expansion and BT.601/BT.709 matrix conversion;
automatic enhancements are disabled. Unspecified matrix tags choose BT.709 for
coded heights above 576 or widths at least 1280, otherwise BT.601.

This is an initial SDR path. Accepted primaries are 1/2/5/6, transfer tags
1/2/6/13 and matrix tags 1/2/5/6. These tags do not establish display color
management: gamut/EOTF conversion, ICC profiles, HDR/tone mapping, rotation and
deinterlacing remain open. Other tags fail before presentation allocation.

A 1,024-byte presenter owns at most 12 COM references. Each render target is
limited to 4,096 by 4,096; larger client areas use a proportionately smaller
target stretched by DXGI. Two swapchain buffers plus one BGRA output consume at
most 192 MiB of nominal pixels, in addition to decoder resources and driver
overhead. Optional diagnostic capture adds at most one 64 MiB staging surface;
normal playback does not allocate it. Resize releases size-dependent resources
after outstanding work finishes. Failed partial opens and resizes can always be
closed; close is idempotent. Capture is an internal packed-BGRA API, not yet a
user screenshot command.

## Clock and window ownership

`src/win/video_window.s` owns one window, its message loop and a fixed 2,048-byte
state allocation including the presenter. It uses integer QueryPerformanceCounter
time and the SPS VUI nominal rate `time_scale/(2*num_units_in_tick)`, falling back
to 24 fps when timing is absent. Rates above 240 fps and overflowing durations
reject. VUI timing is a nominal schedule, not container timestamps, SEI timing or
an audio clock. The separate [audio-master scheduler](video-sync.md) is not yet
connected.

Playback shows every picture, waiting until its nominal due time before decoding.
There is no queue or frame-dropping policy in this initial window. A picture more
than one period late increments a diagnostic count. GPU decode/present retries
have five-second deadlines and yield to messages. Pause and step take effect at
completed picture boundaries; one already submitted picture may finish. A step
updates the frozen media position to the next picture's nominal timestamp.
The final picture stays for its full period before the EOF hold.

Minimization and swapchain occlusion suspend the nominal clock. Paused/minimized
hosts can wait on an optional cancellation event; the CLI instead checks its
Ctrl+C flag at most every 250 ms while idle. No audio device is opened. Closing
releases presentation resources before destroying the owned window. The API
cleans up only its own HWND/class and preserves a host's WM_QUIT message.

The [reference-picture extension](h264-references.md) adds retained decoder
surfaces and switches input views after the preceding draw completes. Its
[current presentation report](../reports/h264-reference-present-verification.json)
checks changing P pictures and reference-dependent pause/step/replay.

## Recorded initial verification

The [native Windows report](../reports/video-present-windows-verification.json)
records nine encoded inputs at two target sizes: four chromatic range/matrix
combinations, four black/white endpoints, and a colored-border four-sided crop
with 4:3 sample aspect ratio. All 1,350 sampled RGB channels equal independent
NV12-to-RGB calculations exactly on the RTX 5070 Ti / driver 32.0.16.1692.
Every output pixel is checked for opaque alpha and letterbox pixels for black;
guarded contexts/output buffers, invalid dimensions, HDR rejection, repeated
open and idempotent close are also checked.

An isolated COM mock passes 43,107 checks, injecting all 15 open failures,
11 resize failures, five GPU/capture failures, two invalid maps and six busy
retries. Every owned reference is released exactly once; failed maps preserve
output guards, and retries issue one blit/copy per operation. These mocks test
ownership/error branches and do not establish hardware support.

An owned hidden window plays a real 90-picture, 30 fps file. Tests check a frozen
pause clock, ignored key autorepeat, exactly two single-picture steps, resize,
minimize/restore, a 3,000,000,000 ns EOF position, replay, close, cancellation and
Esc. The shipping CLI also creates its own hidden test child, accepts pause/step
requests and closes successfully. Tests address only their own HWND/PID; they
send no global desktop input or audio. The [current 115-image NV12 export regression](../reports/video-present-h264-regression.json) and
six-format audio decode smoke regressions pass.

```
python tests/verify-video-present.py --bin bin/video-present-check
python tests/verify-h264-file.py --bin bin/video-present-check --controls
node tests/verify-runtime.js bin/video-present-check
node tests/smoke.js bin/video-present-check
```

These prove GPU image conversion and hidden-window control behavior on one
adapter. They do not measure visible-display latency, dropped frames, CPU/GPU
utilization, power, cross-adapter behavior or synchronized mixed media. Those
milestone 4 gates remain open.

API layouts follow the installed Windows SDK and Microsoft's documentation for
[video-processor input views](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videodevice-createvideoprocessorinputview),
[video-processor color space](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ns-d3d11-d3d11_video_processor_color_space),
[video-processor blits](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videocontext-videoprocessorblt)
and [HWND swapchains](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforhwnd).
All runtime changes are original assembly; C/Python/FFmpeg remain test-only.
