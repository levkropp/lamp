# Native FLAC decoding and stereo rendering

Current 0.4.0-dev source accepts native FLAC with 1–8 channels, 4–32-bit integer samples and rates from 8–192 kHz. The public v0.3.0 download retains its earlier mono/stereo decoder. This extension adds no runtime codec library or CRT.

Constant/verbatim samples, fixed predictors 0–4, LPC orders 1–32, Rice methods/partitions/escapes, wasted bits and the three stereo decorrelation modes use signed 64-bit samples and intermediates. A 32-bit stream can require a 33-bit side channel. Reconstructed predictor samples are checked before entering history; residuals exclude the signed 32-bit minimum, as required by [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.html). CRC8/CRC16 and frame/sample chronology are checked. STREAMINFO MD5 remains unchecked.

## Speaker layouts

The default channel order follows RFC 9639. A case-insensitive `WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x…` Vorbis-comment field overrides it. All eighteen defined speaker bits are accepted in increasing bit order. Hexadecimal digits and `0x` are case-insensitive; leading zeros are accepted. Unknown bits, more assigned speakers than coded channels, malformed values, conflicting masks, duplicate comment blocks and out-of-bounds comment lengths fail cleanly. Identical repeated masks are accepted.

A mask can assign fewer speakers than the stream contains. Remaining tracks decode and validate but contribute no stereo output. An explicit zero mask renders silence; it does not assume a speaker layout for an unknown multitrack or Ambisonic recording. Metadata is parsed for layout; general tag/cover-art display is still unfinished.

## Stereo policy

The engine currently renders two channels. The default horizontal layouts use the [RFC 7845 stereo downmix](https://www.rfc-editor.org/rfc/rfc7845.html#section-5.1.1.5), reordered into FLAC/WAVE order. Extended layouts use the following original policy. Let `q = 1/√2` and `a = √3/2`:

| Speaker | Left coefficient | Right coefficient |
| --- | --- | --- |
| Front left / right | 1 / 0 | 0 / 1 |
| Front center; LFE | q | q |
| Back or side left | a | 1/2 |
| Back or side right | 1/2 | a |
| Front left / right of center | q / 0 | 0 / q |
| Back center | a·q | a·q |
| Top center; top front center | 1/2 | 1/2 |
| Top front left / right | q / 0 | 0 / q |
| Top back left | a·q | q/2 |
| Top back center | a/2 | a/2 |
| Top back right | q/2 | a·q |

Normalize both rows by the larger row sum: the target sum is 1 for up to four assigned speakers, and 2 for five or more. The assignment count determines this gain, so a four-track file tagged as front left/right retains ordinary stereo gain. Default mono duplicates its sample; ordinary stereo retains the existing exact conversion path. This policy includes LFE without a low-pass filter. It is a rendering choice, not a FLAC requirement or an Ambisonic decoder. Dense coherent surround signals can exceed unit float amplitude; the player applies its existing final output bounds.

Other layouts convert integer samples to double precision, multiply and accumulate in channel order, apply the exact power-of-two sample scale, then round once to float. This avoids losing small results when large channel contributions cancel. Native surround routing and configurable mixing remain roadmap work.

## Seeking, resources and cancellation

The existing validated seek-table and bounded frame-search paths work with all supported depths/layouts. Every channel, including unassigned tracks, is reconstructed and range-checked before a frame is emitted. Samples in the first two channels use the existing 1 MiB workspace. Additional channels allocate `(channels − 2) × maximum_block_samples × 8` bytes only when needed, capped below 3 MiB and released on close. Including page rounding, the eight-channel decoded workspace is at most 4 MiB. No per-seek allocation is required.

Comment blocks retain FLAC's 24-bit size bound; vendor/field lengths are checked against the mapped block. Metadata, byte reservoir and unary reads observe cancellation. A cancelled read leaves a sticky error until close/reopen; buffered frames also honor a cancellation request. Zero-capacity reads write nothing. The existing unary-prefix/resource and speculative seeking caps remain in force.

## Verification

Run `build.ps1 -OutputDirectory bin/verify-build`, then `tests/verify-flac-layouts.ps1 -OutputDirectory bin/verify-build`. Node.js, FFmpeg and the MSVC C compiler are test prerequisites; the C harnesses link only into isolated test executables.

The [recorded report](../reports/flac-layout-verification.json) checks 404 files and 6,060 byte-exact stereo seeks. Synthetic files cover every depth/channel combination, extreme signed values, 33-bit decorrelation, fixed/LPC predictors including 32 taps and large cancelling products, both Rice methods, escape widths, partitions and wasted bits. Layout cases cover each speaker bit, the RFC mask examples, case/padding, duplicate masks and unassigned tracks. Maximum blocks contain 65,535 samples in all eight channels. Seventy-two modern FFmpeg files span 16/24/32-bit depths, every channel count and compression levels 0/5/12; the harness rejects an encoder that silently reduces depth. Its 32-bit encoding uses FFmpeg's experimental option only in fixture generation.

FFmpeg independently decodes the assigned lossless channels. Known integer samples and an independent speaker-matrix calculation supply expected stereo floats. Dedicated output guard pages check variable capacities, untouched tails, zero-capacity reads, EOF and closed-state refusal. Cancellation and repeated open/close checks cover allocation release. Twenty malformed streams are rejected, including invalid masks/lengths, forbidden residuals and invalid predictor reconstruction. The earlier 42 non-playback WAV/FLAC checks and 1,470 exact seek checks also pass. Actual WASAPI lifecycle checks add 32-bit 5.1/7.1 silence playback, pause/resume, stop/reopen, seek, paused seek and cancelled open.

These tests establish the stated coverage. Ogg FLAC, rates outside 8–192 kHz, MD5 validation and native surround output remain unfinished; this is not complete FLAC conformance or a performance comparison of the new path.
