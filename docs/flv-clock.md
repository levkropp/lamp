# FLV packet audio timestamps

AAC (including HE-AAC v1/v2), Flash ADPCM and Speex now use the FLV tag's
media clock for audio placement. Leading/internal gaps produce silence,
negative prefixes are clipped and earlier samples win when tags overlap.
Duration and seek targets include gaps. Codec history still decodes through
clipped samples. PCM, G.711 and MPEG audio currently use the older gathered
path and do not yet schedule tag timestamps. Actual video/A/V synchronization
also remains unfinished.

## Timestamp rules

Adobe's [FLV specification 10.1, annex E.4.1](https://ossrs.io/lts/en-us/assets/files/flv_v10_1-5244d3059e5425eb03a15eb24537bd59.pdf)
defines a signed 32-bit millisecond clock: the three Timestamp bytes form
the low 24 bits and TimestampExtended supplies the high eight bits. LAMP
uses that signed value, including negative times and the full positive
range. It does not reinterpret the field as an unsigned clock or infer
wraparound. The audio origin stays relative to file time zero, so delayed
audio does not move ahead of earlier video/script tags.

Only accepted, complete audio packets anchor PCM. AAC sequence headers,
repeated sequence headers, skipped formats, video/script data, encrypted
tags and incomplete final packets do not move the clock. Existing stream
selection remains: the first audio tag's format selects the stream, and
its existing codec/header restrictions still apply.

Samples are placed using the shared [sparse media map](matroska-clock.md#sparse-mapping-and-seeks).
Offset changes of at most one millisecond are treated as timestamp
quantization; larger changes use the nearest decoded sample, with half
ties away from zero. This preserves ordinary rounded FLV clocks without
periodically inserting/deleting samples. It does not resample clock drift.
Long silence uses bounded reads and sparse spans, not gap-sized PCM memory.

The existing 24-byte packet entries temporarily hold signed tag clocks
before duration scanning. After scanning they again hold source sample
positions and counts. No extra timestamp table is allocated per packet.
Mapped seeks report the exact media target, then privately decode/discard
the source codec's pre-roll. AAC-LC retains one preceding packet; HE-AAC
retains two for SBR filtering. Speex retains its complete-history policy.
Neither mapped seeking nor this addition promises continuous-noise identity
when a codec restarts at a different packet.

## Verification

The [Windows](../reports/flv-clock-windows-verification.json) and
[Linux](../reports/flv-clock-linux-verification.json) suites each pass 184
files and 2,944 media seeks. They cover AAC-LC
at 8/16/32/44.1/48/96 kHz, HE-AAC SBR and parametric stereo with implicit,
explicit and sync-extension signaling, Speex groups of 1/5/8 frames, and
all four Flash ADPCM code sizes in mono/stereo. An independent per-sample
placement model checks continuous audio, leading/internal gaps, overlap,
negative/reversed clocks, the signed minimum, extended headers and ignored
foreign clocks. Source PCM is explicitly exported without the media map;
AAC seek references decode independently constructed packet suffixes,
including HE-AAC's two preceding packets. Codec DSP has separate reference
suites; this is a timing comparison.

Sparse tests exercise TimestampExtended and the signed maximum using small
files with very long leading silence: guarded reads, gap-boundary seeks,
EOF/clamping, cancellation and reopen. Three guarded fixtures also test
read-only/protected inputs, truncated prefixes, output canaries and 1,536
bit mutations. Accepted damaged input establishes bounded behavior rather
than correct damaged-file audio; mutation reads stop after 128 calls and
seek at call 64.

The existing [67-check FLV regression](../reports/flv-clock-regression-windows-verification.json),
[25-file official Speex comparison](../reports/flv-clock-speex-windows-verification.json)
and [track selection regression](../reports/flv-clock-tracks-windows-verification.json)
also pass. Synthetic continuous remuxes now derive timestamps from audio
duration instead of unrelated tag ordinals. The Matroska clock regression
checks that its original timestamp marker still works. The existing
[67-check HE-AAC suite](../reports/flv-clock-heaac-windows-verification.json)
continues to match FFmpeg across its recorded profiles and tolerances.

Muted native Windows playback probes cover timed AAC, Flash ADPCM and
Speex through pause/resume, stop/reopen, active/paused seek, cancelled open,
simulated default-output restart and exclusive 48 kHz output. Changed/shared
modules [translate and assemble for Apple Silicon](../reports/flv-clock-mac-assembly-verification.json).
Native Mac execution, Linux output-device playback, captured hardware PCM,
physical hotplug and video/A/V synchronization are not established here.

Run `python tests/verify-flv-clock.py --bin bin/flv-clock-check`.
Linux uses `python3` and `build/flv-clock-check`; `--fixtures PATH` replays
the generated corpus without FFmpeg. Native Windows `--probe` requires a
marked muted build. The separate Speex regression remains
`python tests/verify-speex-flv.py --bin bin/flv-clock-check`.
