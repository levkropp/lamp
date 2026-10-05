# Vorbis input, native PCM and stereo output

LAMP 0.4.0-dev decodes one Ogg/Vorbis logical stream with **1–255 channels**, floor 1, residue types 0/1/2 and mapping type 0. Rates are 8–192 kHz and block sizes are 64–8192 samples. Ordered, unordered and sparse codebooks, lookup types 0/1/2, up to 256 coupling steps and 16 submaps are supported. All channels are decoded and checked, including channels excluded from stereo output. Chained/multiplexed Ogg, floor 0 and corruption recovery remain unsupported.

## Channel policy

The standard channel roles follow the [Vorbis I specification, section 4.3.9](https://xiph.org/vorbis/doc/Vorbis_I_spec.html). The native reader preserves encoded channel order:

| Channels | Encoded order |
| --- | --- |
| 1 | Front center |
| 2 | Front left, front right |
| 3 | Front left, front center, front right |
| 4 | Front left, front right, rear left, rear right |
| 5 | Front left, front center, front right, rear left, rear right |
| 6 | Front left, front center, front right, rear left, rear right, LFE |
| 7 | Front left, front center, front right, side left, side right, rear center, LFE |
| 8 | Front left, front center, front right, side left, side right, rear left, rear right, LFE |
| 9–255 | Application-defined ports; speaker positions are unspecified |

Playback and CLI export remain stereo. Mono duplicates at its original amplitude; stereo passes through. Layouts with 3–8 channels use the shared WAV/FLAC/AIFF speaker weights: front left/right feed their respective outputs, center and LFE feed both at `1/sqrt(2)`, rear/side pairs use `sqrt(3)/2` on their own side and `1/2` on the opposite side, and rear center uses `sqrt(3/8)` on both sides. Rows are normalized to a maximum sum of 1 for 3–4 channels or 2 for 5–8 channels. Samples accumulate in double precision and round once to float32; headroom beyond unit amplitude is retained.

For 9–255 channels, stereo output takes native ports 0 and 1 directly. Every remaining port is still decoded and validated. This policy does not assign speakers to application-defined layouts. Native WASAPI surround routing remains future work.

## Reader and resource limits

`vorbis_read_native(float *destination, unsigned frame_capacity)` returns interleaved native-channel float32 PCM. Its destination needs `frame_capacity * source_channels` floats. It shares the existing stereo reader's cursor and overlap state; switching readers consumes the next frames from the same stream. Zero capacity, closed state, EOF and sticky errors refuse output. Cancellation also refuses already-buffered PCM.

Mono/stereo retain their static buffers. Higher counts allocate 133,120 working bytes per channel from the existing 64 MiB setup arena, including spectrum, time, overlap, floor and classification storage. At 255 channels this is 33,945,600 bytes before setup data and commit rounding. Setup and working buffers share the cap; a valid but oversized combination rejects cleanly. The arena commits 64 KiB increments and releases on close. There are no per-frame heap allocations or duplicate native PCM caches. The seek index adds at most 64 KiB.

Packets are capped at 4 MiB, codebooks at 65,536 entries and 256 dimensions. Ogg CRC, page sequence, continuation and timing validation remain in place. Nonfinite reconstructed or mixed PCM rejects with a sticky error. Sparse seeks restore the previous packet's overlap for every channel; existing positive/cropped granule origins and final trimming apply to the native and stereo readers.

## Verification and comparator limits

Run:

```sh
python3 tests/verify-containers.py vorbis-multichannel
```

On Windows, `.\tests\verify-engine.ps1 -OutputDirectory .\bin\verify-build` adds the WASAPI 5.1/7.1 lifecycle checks.

The multichannel suite checks every channel count 1–255, native PCM before mixing, byte-exact independently calculated stereo routing, native/stereo seeks, guarded output, mixed-reader cursor continuity, cancellation, closed/sticky state and repeated allocation release. It includes all residue types, absent floors and channels, coupled channels, submaps, classword dimensions, 8192-sample blocks, maximum classification storage, 256 coupling steps, 16 submaps, continued packets and a Unicode path. A nonzero 65,537-packet three-channel stream exercises two index compactions. Another 128 independently encoded files cover 1–8 channels, eight rates and two quality settings. Malformed mapping/floor/residue indices, coupling pairs, truncated floor data and a combined-arena overflow exercise rejection and cleanup.

The test-only float reference is unmodified **Xiph libvorbis 1.3.7 with libogg 1.3.6**. Bundled source archives retain their licenses and match Xiph's published SHA-256 checksums; pins are in [`vorbis-reference-hashes.json`](../tests/reference/vorbis-reference-hashes.json). Reference C is compiled only into test executables. Neither player links or invokes these libraries.

Xiph's `vorbis_book_decodevv_add` rounds residue-2 partition boundaries to channel boundaries. Its output differs from the specification's flattened-vector placement when those boundaries are unaligned. Xiph comparisons therefore use aligned partitions. A separate original specification oracle checks unaligned partitions with independently constructed residue values, mathematical dB floors, a direct cosine inverse MDCT and sine-window overlap. Large classification cases use independently constructed specification spectra with Xiph's inverse MDCT. The bundled stb_vorbis reference is unsuitable for the full channel range because it clamps residue-2 size to two channels.

The full run passes 797 files and 71,042,304 native float values. It records 11,955 native plus 11,955 stereo exact seeks, 201,056 guarded reads, 22,190 mixed-reader checks, 3,188 cancellation checks, 17,968 valid-stream reopens and 14 malformed/resource rejections. Rejected streams also undergo 24 reopen/cleanup attempts each. The minimum observed SNR is 129.09 dB and maximum scaled peak error is 0.000000429. All 24 WASAPI lifecycle scenarios pass, including Vorbis 5.1/7.1 stereo downmix; the prior 83 Vorbis checks and 1,305 mono/stereo seeks pass.

Native comparisons require at least 90 dB SNR and peak error divided by `1 + reference_peak` no greater than 0.00004. Stereo routing and seeks must match the verified native/continuous assembly PCM exactly. The [recorded report](../reports/vorbis-multichannel-verification.json) identifies each comparator path and retains source/object hashes and observed errors. Tests establish this documented coverage, not full Vorbis conformance.
