# RIFF/WAVE precision and speaker layouts

Current 0.4.0-dev source accepts little-endian RIFF/WAVE with 1–8 channels and rates from 8–192 kHz. PCM containers are unsigned 8-bit or signed 16/24/32-bit; IEEE input can be float32 or float64. Both basic and extensible headers are supported. The public v0.3.0 download retains its earlier mono/stereo PCM/float32 implementation.

## Precision and numeric conversion

Extensible PCM accepts valid precision from 1 bit through the physical container width. Samples are left-aligned as specified by [Microsoft's WAVEFORMATEXTENSIBLE documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-waveformatextensible). Unused low bits are ignored, so 24-bit precision in a 32-bit container is read as four bytes per sample. Zero valid precision is interpreted as the full container width. Float valid precision must equal the container width or be zero.

Every integer sample converts exactly to double before scaling and mixing; the final stereo value rounds once to float. Float32 input is promoted exactly. NaN and infinity become silence. Finite float64 samples are bounded to the representable float32 range before mixing, and mixed outputs receive the same bound before conversion. This prevents float overflow while retaining finite headroom above unit amplitude. Extremely large cancelling float64 samples therefore follow this bounded input policy, rather than arbitrary double-range algebra. Export and WASAPI output remain stereo float32; native float64/surround output and configurable headroom/limiting remain unfinished.

## Channel assignment and mixing

Basic headers lack speaker masks; LAMP infers the conventional FLAC/WAVE layouts for 1–8 channels. Extensible headers specify increasing WAVE speaker-bit order. The shared [stereo speaker policy](flac.md#stereo-policy) handles all eighteen defined positions, including height speakers. It uses double coefficients and accumulation, with one shared normalization factor for both output channels.

WAVE-specific rules differ from FLAC comment masks. A nonzero mask with fewer set bits than channels leaves the remaining tracks unassigned and silent. A mask with more bits than channels uses its lowest assigned positions and ignores the extra high bits, following Microsoft's channel-count rule. Reserved speaker bits fail cleanly. A zero mask denotes direct-out data; LAMP presents the first two source ports as stereo, duplicates a single port, and consumes other tracks without mixing them. It does not infer an Ambisonic transform or surround layout from direct-out data.

## Bounds, seeking and cancellation

RIFF/chunk lengths, format extensions, subtype GUID, channel/rate/container values, byte rate and block alignment are checked before playback. A data payload must contain whole interleaved frames. Unknown chunks are skipped with RIFF word padding; duplicate format chunks and data preceding the format are rejected. Declared extension bytes must fit their chunk; future extension bytes can be skipped after the known fields.

The decoder reads directly from its existing file mapping. Multichannel WAV adds no PCM/index allocation. Direct seeking multiplies the frame position by the physical block alignment, regardless of valid precision, and clamps at EOF. Zero-capacity reads write nothing. Cancelled open/read requests fail cleanly; read errors remain sticky until close/reopen. A cancelled seek performs no work and leaves decoding state untouched.

RF64, RIFX, WAVE64 and compressed WAV codecs remain roadmap work. The current RIFF length is 32-bit; this extension does not claim large-file container support or complete WAV coverage.

## Verification and reference limits

Run `build.ps1 -OutputDirectory bin/verify-build`, then `tests/verify-wav-layouts.ps1 -OutputDirectory bin/verify-build`. Tests require Node.js, FFmpeg and MSVC for isolated C oracle executables; runtime code remains assembly without a codec DLL or CRT.

The [recorded report](../reports/wav-layout-verification.json) checks 965 files and 14,475 byte-exact seeks. It covers every supported PCM container/valid-precision combination across all eight channel counts; basic/extensible float32/64; maximum finite values, nonfinite values, signed zero and subnormals; all speaker bits; zero/partial/excess masks; padded metadata; zero valid precision and future extension bytes; and a Unicode filename. A separate set of 144 FFmpeg-produced files spans six PCM/float encodings, every channel count and three rates. Twenty-eight malformed header/chunk/data cases fail cleanly.

FFmpeg n8.0.1's [WAVE header parser](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/riffdec.c) selects the PCM codec using valid precision. When that falls into a smaller byte-size bucket, it can misread the physical sample size. For example, 1-bit precision in a 16-bit container appears as unsigned 8-bit PCM and twice as many frames. The test report identifies those cases and compares their source channels through FFmpeg's raw physical-container reader. It retains the original WAVE input for LAMP and uses Microsoft semantics for header construction; it does not change implementation behavior to match the comparator error. Other clean samples use the original WAVE header for the independent channel comparison. Four dirty-padding files intentionally test LAMP's low-bit discard policy without claiming FFmpeg equality.

An independent numeric speaker calculation supplies expected stereo floats. Direct C checks protect output boundaries, vary capacity, verify untouched tails/EOF/closed-state refusal, exercise cancellation and repeat 64 open/close cycles per file. Existing WAV/FLAC PCM and 1,470 seek regressions pass; the shared mixer also retains the 404-file FLAC regression suite. Actual WASAPI lifecycle checks add 24-bit and float64 5.1/7.1 silence playback, pause/resume, stop/reopen, seek, paused seek and cancelled open. Performance reports from older builds retain their original hashes and do not measure these new paths.
