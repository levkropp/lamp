# Matroska and WebM audio

LAMP 0.4.0-dev plays the audio track of Matroska (`.mka`, `.mkv`) and WebM (`.webm`) files: audio-only files, and the audio of video files while video remains future work. The demuxer (`src/mkv.s`) follows RFC 9559 (Matroska) and RFC 8794 (EBML). It feeds a container-neutral packet track layer (`src/track.s`) that the [MP4 demuxer](mp4.md) shares.

## Track selection

The demuxer selects one audio track: the first enabled audio track with a supported codec whose FlagDefault is set, or else the first enabled audio track with a supported codec. Video, subtitle and other tracks, unsupported audio tracks, and tracks with ContentEncodings (header stripping, compression or encryption) are skipped. A file without a usable audio track rejects. `--track N` plays the Nth audio TrackEntry instead ([track selection](tracks.md)).

| CodecID | Decoder |
| --- | --- |
| `A_OPUS` | Opus families 0/1 (OpusHead in CodecPrivate); CodecDelay when present, otherwise OpusHead pre-skip |
| `A_VORBIS` | Vorbis (three Xiph-laced headers in CodecPrivate) |
| `A_FLAC` | FLAC (`fLaC` and metadata blocks in CodecPrivate) |
| `A_ALAC` | Apple Lossless (`ALACSpecificConfig` in CodecPrivate); see [MP4 notes](mp4.md#apple-lossless) |
| `A_AAC` | [AAC-LC or HE-AAC (v1 and v2)](aac.md) (AudioSpecificConfig in CodecPrivate); the legacy `A_AAC/MPEG2/...` and `A_AAC/MPEG4/...` IDs are not recognised |
| `A_AC3` | [AC-3](ac3.md); `A_EAC3` supports the partial [conventional-mantissa profile](eac3.md) |
| `A_WAVPACK4` | [WavPack](wavpack.md) frames (block headers reduced to flags, CRC and sizes); CodecPrivate is optional |
| `A_MS/ACM` | [Speex](speex.md), WAVE tag `0xa109`, with a WAVEFORMATEX wrapper and appended Speex identification header; NB/WB/UWB mono or stereo |
| `A_MPEG/L1`, `A_MPEG/L2`, `A_MPEG/L3` | MPEG audio Layers I–III, one frame per packet |
| `A_PCM/INT/LIT`, `A_PCM/INT/BIG`, `A_PCM/FLOAT/IEEE` | PCM: unsigned 8-bit, signed 16/24/32-bit in either byte order, float32/64; 1–8 channels; integral 8–192 kHz SamplingFrequency |

DTS and other unsupported CodecIDs are skipped. AC-3 and the supported E-AC-3 profile pass through the track decoder.

## Speex through ACM

Speex files written by FFmpeg use the standard
[`A_MS/ACM` mapping](https://www.matroska.org/technical/codec_specs.html#a_msacm),
whose CodecPrivate contains an unpacked little-endian WAVEFORMATEX and its
extra format bytes. LAMP recognizes the
[Speex WAVE tag `0xa109`](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/riff.c).
The 18-byte wrapper's `cbSize` must fit the private payload and contain at
least the 80-byte Speex header. Extended headers are accepted within that
declared size; undeclared trailing private bytes are ignored. WAVE and
Speex sample rates and channel counts must agree. The Speex header then
sets the decoder's mode, rate and channel count; Matroska Audio fields do
not override this codec configuration. Arbitrary other ACM formats remain
unsupported: they count as audio tracks and Automatic skips them, while an
explicit unsupported choice rejects.

All three Speex bands, mono/intensity stereo, CBR/VBR/VAD/DTX and 1–64
frames per packet use the same assembly packet adapter as FLV. Packets may
use the usual Matroska lacing, with a shorter or end-marker-filled final
group. Float output is normalized by 1/32768 without int16 clipping; mono
is duplicated. Speex seeks rebuild complete prediction, noise, filter and
QMF histories from packet zero and discard up to the target. They are
exact and cancellable, but a long recording may take time to seek.

CodecDelay and signed per-block DiscardPadding trim the presentation as
described below. No Ogg granule trimming is inferred for this mapping.
Timestamp scheduling/gaps remain unimplemented here. This adds Matroska
audio coverage; it does not establish WebM Speex conformance or video/A/V
synchronization. Matroska reports codec kind 8 as for its other audio codecs.

The [Windows report](../reports/speex-matroska-windows-verification.json)
and [Linux report](../reports/speex-matroska-linux-verification.json) each pass
58 files and 870 exact seeks against independent packet extraction and the
unchanged Speex 1.2.1 float decoder. The suite covers standard 8/16/32 kHz
mono/stereo streams, qualities 0/5/10, grouped 1/2/5/8-frame packets,
VBR/VAD/DTX, interleaved MPEG-4 video, all three lacing forms, unknown-size
Segment/Clusters, 64-frame stereo null packets in each band, extended/trailing
private data, final padding and header authority. Mixed-codec default and
explicit ordinals include exact selected-track seeks, seven catalog/reopen
checks and an unsupported ACM track before Speex. The third Opus track
matches its standalone Matroska copy; remuxing it to Ogg would change its
padding representation.

Each platform also passes 65,353,842 guarded checks with 2,635,800 exact float
words, 1,136 protected truncated file prefixes and 512 single-bit mutations;
accepted mutations establish bounded behavior, not correct damaged-file
audio. Sixteen malformed wrappers/headers/payloads/padding cases reject,
and cancelled open/read plus reopen pass. Native Windows additionally passes
muted play/pause/resume/stop/reopen, active/paused seek, cancelled open,
simulated default-output callback recovery and exclusive 48 kHz output for
8 kHz mono, 16 kHz stereo and 32 kHz stereo. Captured hardware PCM, audible
latency and physical device hotplug are not established. Changed modules
translate and assemble for ARM64 macOS; native Mac and Linux output-device
execution remain unverified for this addition.

Run `python3 tests/verify-speex-matroska.py --bin build/speex-mkv-check`.
On Windows use `python`, `--bin bin/speex-mkv-check` and optionally `--probe`
after a `--tests --probe-default-device --probe-exclusive --probe-silent`
build. `--fixtures PATH` reuses the same encoded corpus without FFmpeg.
The [52-check Matroska regression](../reports/speex-matroska-regression-windows-verification.json)
and [13-check track regression](../reports/speex-matroska-tracks-windows-verification.json)
also pass on the current native Windows decoder objects.

## Structure

The EBML header must name DocType `matroska` or `webm`. Element sizes are checked against their parents. Segment and Cluster may have unknown sizes, as live recorders write them; an unknown-size Cluster ends at the next Segment-level element. Other elements must have known sizes. SimpleBlock and BlockGroup/Block frames of the selected track become packets in file order, with Xiph, EBML and fixed lacing; laced sizes must fit their block and fixed lacing must divide it exactly. Timestamps are not used for decoding: the codec's own packet durations place samples, so gaps or overlaps in timestamps do not change output.

Opening reads every cluster, so opening a long video file reads most of it; Cues are not used yet.

## Codec delay and block padding

The selected track's unsigned `CodecDelay` removes initial coded samples.
An explicitly present value, including zero, takes precedence over OpusHead
pre-skip; an absent value retains the existing OpusHead fallback. The two
values are never added. Other tracks' timing does not alter the selected
audio. Delay beyond the coded stream rejects; delay equal to its length
produces an empty presentation.

Signed `DiscardPadding` works on any BlockGroup. Positive values remove
the end of its Block; negative values remove the beginning. A laced Block
is one interval across all its packets, so padding can span several
packets. Magnitudes cannot exceed that Block's coded duration. Overlap with
global start/end trimming is removed once. Nanoseconds convert at the
decoded sample rate using a 128-bit product and nearest rounding, with
half-sample ties away from zero. Duplicate timing elements, multiple or
missing Blocks in a BlockGroup, and integers longer than eight bytes reject.
These rules follow the [Matroska element definitions](https://www.matroska.org/technical/elements.html).

The existing 24-byte packet index retains coded positions. An optional
32-byte-per-padded-Block map reserves up to 512 MiB of virtual address space
and commits 64 KiB at a time; files without block padding allocate no map.
Presentation duration excludes removed samples. Reads still decode fully
discarded packets to preserve codec history, and seeks translate between
coded and presented positions before applying the existing codec pre-roll.
Packet FLAC validates frame positions against its complete coded scan,
including when playback duration is shortened by trimming.

The [Windows](../reports/matroska-timing-windows-verification.json) and
[Linux](../reports/matroska-timing-linux-verification.json) timing suites
each cover 117 files and 1,872 presentation seeks: six PCM rates from
8–192 kHz, FLAC, Opus, MP2/MP3, AAC, ALAC, Speex and Vorbis, lacing,
interior/head/whole-block deletion, explicit zero delay, rounding boundaries,
empty output, unselected timing, eight malformed inputs and cancellation.
An independent per-sample visibility mask selects unchanged unpadded PCM;
this establishes trimming rather than new codec DSP conformance. Opus/AAC
seek PCM is compared to fresh unpadded codec seeks at the same coded
position, preserving their existing reset/pre-roll policy. Other tested
formats compare seek output to continuous PCM. Separate map-only
[Windows](../reports/track-cuts-windows-verification.json) and
[Linux](../reports/track-cuts-linux-verification.json) tests each pass
2,054 cases and 3,016,820 checks, including adjacent removals, resource and
allocation failures and commit-boundary growth.

Two unlaced PCM padding cases match FFmpeg 8.0.1 exactly. That FFmpeg
version exposes generic CodecDelay as `initial_padding` without applying
the generic sample skip; its Opus decoder consumes OpusHead pre-skip.
Its laced padding handling can also differ from the whole-Block rule.
The independent interval model therefore remains the timing comparator;
the ordinary MP2/MP3 regression explicitly removes the declared delay from
older FFmpeg output when its frame count shows the omission.

Muted native Windows testing covers a delayed, laced Speex stream with
mixed signed padding through play/pause/resume, stop/reopen, active and
paused seeks, cancelled open, simulated default-output recovery and
exclusive 48 kHz output. Hardware PCM capture and physical hotplug are
not established. Changed sources translate and assemble for Apple Silicon;
native Mac execution and Linux output-device playback remain unverified
for this addition. Timestamp gaps/overlaps, video and A/V synchronization
remain open. Track-requested seek history is covered separately below.

Run `python3 tests/verify-track-cuts.py --bin build/mkv-timing-check` and
`python3 tests/verify-matroska-timing.py --bin build/mkv-timing-check`.
On Windows use `python` and `--bin bin/mkv-timing-check`; `--probe` requires
a build marked with `--probe-silent` (plus the default-device/exclusive
options for those lifecycle checks). `--fixtures PATH` reuses generated
fixtures without FFmpeg.
For the Windows map-only oracle, first assemble its test wrapper:
`llvm-mc -triple=x86_64-pc-windows-msvc -filetype=obj -defsym=WINDOWS=1 -I src tests/track-cuts-probe.s -o bin/mkv-timing-check/track-cuts-probe.obj`.

## Track-requested seek history

The selected track's unsigned `SeekPreRoll` supplies a minimum duration of
coded history to decode after a seek. Its nanoseconds convert upward to
whole samples, using a 128-bit product. The packet search starts at or
before that history cutoff in the coded timeline, before any presentation
cuts. The existing codec restart rules still apply: a short or zero value
cannot reduce Opus's 80 ms minimum, MPEG reservoir history, overlap primers
or Speex's complete-history policy. Codec primers can move the decode
start earlier still. A history request longer than the available prefix
starts from the first packet; even the full unsigned 64-bit value is
handled without allocating more memory. Continuous PCM and duration do not
change. These semantics follow [SeekPreRoll's element definition](https://www.matroska.org/technical/elements.html).

Missing and zero values add no container minimum. Empty unsigned elements
mean zero; duplicate values or payloads over eight bytes reject. Unselected
tracks' values do not affect playback, and close clears the selected
history. This applies to audio in the existing coded packet timeline;
timestamp gaps and A/V clock scheduling remain unfinished.

Repeated seeks now reset the decoder when the requested position is zero,
including after EOF. AAC reset also restores its PNS noise seed alongside
overlap/window/SBR state. Repeated AAC seeks therefore match a fresh codec
restart at the same packets; this does not promise continuous-noise
identity after a different restart point.

The [Windows](../reports/matroska-preroll-windows-verification.json) and
[Linux](../reports/matroska-preroll-linux-verification.json) suites each pass
143 files and 2,145 modeled seeks, with 154,097,941 checks and 30,404,434
exact float comparisons. Six PCM rates (8–192 kHz), FLAC, Opus, MP2/MP3,
AAC, ALAC, Speex and Vorbis cover absent/zero/one-nanosecond history,
boundaries around 80 ms, upward fractional-sample rounding, 250 ms and
the maximum unsigned value. Delayed, signed-padding, EBML-laced files,
selected ordinals, metadata ordering, repeated EOF/zero seeks, cancellation
and close/reopen are included. An independent sample mask and packet model
determine restart positions. Opus/AAC sample expectations come from
continuous decoding of independently constructed packet suffixes, rather
than another seek through this implementation. Other tested codecs compare
to their unchanged continuous PCM; separate codec suites establish DSP
conformance.

Each platform also passes 61,789,073 guarded checks, 1,274 protected input
prefixes and 512 mutations; accepted damaged inputs establish bounds, not
correct damaged-file audio. Malformed duplicate/oversized elements reject,
and an empty unsigned element is checked against absent metadata.
[Counterfactual controls](../reports/matroska-preroll-negative-controls-verification.json)
reproduce the old zero-rewind failure, then isolate the AAC noise-reset
failure by substituting only the previous AAC object. The current runtime
passes both. The 117-file timing suite, 68-check AAC, 67-check HE-AAC,
52-check Matroska and 72-check MP4 regressions also pass on the current
Windows objects.

A muted native Windows probe checks a 250 ms pre-roll Opus stream with
delay and signed laced padding through pause/resume, stop/reopen, active
and paused seek, cancelled open, simulated default-output recovery and
exclusive 48 kHz output. Changed sources and their decoder/timing
dependencies [translate and assemble for Apple Silicon](../reports/matroska-preroll-mac-assembly-verification.json);
native Mac execution, Linux output-device playback, hardware PCM capture
and physical hotplug remain unverified for this addition.

Run `python3 tests/verify-matroska-preroll.py --bin build/mkv-preroll-check`.
Windows uses `python` and `--bin bin/mkv-preroll-check`; add `--probe` only
after a marked `--tests --probe-silent` build (plus default-device/exclusive
options for those checks). `--fixtures PATH` reuses the encoded corpus,
sample masks and independently prepared seek references without FFmpeg.

## Track layer

A demuxer lists packets as pointers into the mapped file and names the codec, its private data and start/end trimming. `track_finish` opens the codec and asks it for every packet's duration: Opus TOC, Vorbis block sizes and overlap, FLAC frame headers (positions must be consecutive), ALAC frame headers, MPEG audio headers (layer, version, rate and channels must not change), Speex frame structure, and PCM sizes, which must be whole frames. Each decoded packet must produce exactly its scanned duration. A track may hold 16,777,216 packets; the table reserves 384 MiB of address space and commits 192 KiB per 8,192 packets, so memory follows the file. The common PCM buffer permits up to 262,144 stereo frames per packet, subject to smaller codec limits; Speex permits at most 40,960 frames (64 UWB frames).

Seeking finds the packet holding the target and restarts there with the codec's pre-roll: FLAC, ALAC and PCM packets decode independently, Vorbis decodes one primer packet whose output is skipped, MPEG audio decodes two frames before the target and Layer III also earlier frames holding up to 2 KiB of bit-reservoir data, and Opus starts at least 80 ms before the target. Layer III frames whose reservoir lies before the restart point emit silence and are discarded; once a frame finds all of its main data, later frames are exact. Vorbis, FLAC, PCM and MPEG audio seeks therefore equal continuous decoding; Opus seeks equal LAMP's Ogg Opus seeks.

## Verification

`python3 tests/verify-matroska.py` muxes fixtures with FFmpeg:

- 24 files: Opus stereo/mono CBR/5.1 and Vorbis stereo/mono/5.1 as both `.mka` and `.webm`; FLAC 16/24-bit and 5.1; MP3; MP2; PCM s16/s24/s32be/f32/f64/u8 and 5.1. Mono and stereo outputs are compared with FFmpeg's decode of the same file: exact for FLAC and PCM, and within the codec suites' tolerances for Opus, Vorbis and MPEG audio. Opus and FLAC must also equal LAMP's decode of the same stream remuxed to Ogg, 5.1 PCM its WAV remux, and 5.1 Vorbis a direct Ogg encode.
- A test-only muxer rewrites seven of them with Xiph, EBML and fixed lacing, unknown-size Segment and Clusters, a second track with FlagDefault, and an unsupported DTS track and a VP9 video track before the audio; all 42 variants decode identically.
- 90 exact seeks on six files (Vorbis, FLAC, PCM, MP3, MP2, 5.1 Vorbis WebM) and ten Opus seeks equal to Ogg Opus seeks.
- Eight malformed files reject: a truncated file, a wrong DocType, no supported audio, a ContentEncodings track, Opus without CodecPrivate, a corrupt FLAC frame, and Xiph and fixed lacing that do not fit. Midstream DiscardPadding has an exact sample-interval check. Cancelled open and read stop cleanly; optional playback checks use a WebM Opus file.

FFmpeg's Ogg remux from Matroska drops DiscardPadding and rounds granules from millisecond timestamps. LAMP therefore compares Opus against the Matroska presentation range, ignores FLAC-in-Ogg granules (FLAC frames carry exact positions), and uses a direct Ogg encode for the Vorbis comparison, because LAMP rejects Vorbis granules that contradict packet durations.
