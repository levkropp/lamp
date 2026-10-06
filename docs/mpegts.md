# MPEG transport and program streams

LAMP 0.4.0-dev plays the audio of MPEG-2 transport streams (`.ts`, `.m2ts`, `.mts`) and MPEG-1/MPEG-2 program streams (`.mpg`, `.mpeg`, `.vob`) with a handwritten demuxer (`src/mpegts.s`) following ISO/IEC 13818-1. The first supported audio stream is gathered from its PES packets into one buffer, which then opens as the raw stream it carries, so decoding, timing and seeking are those of `.mp3`, `.aac`, [`.loas`](latm.md) and [`.ac3`](ac3.md) files. DVD and Blu-ray LPCM become a Wave64 image of little-endian PCM for the WAV reader ([below](#lpcm)). Video, subtitles and other streams are skipped. `--track N` plays the Nth audio stream instead ([track selection](tracks.md)).

## Transport streams

- 188-byte packets, 192-byte M2TS/BDAV packets (a 4-byte time stamp before each) and 204-byte packets (16 parity bytes after each); at least five consecutive packets (or every packet of a shorter file) must start with the sync byte. Packets with the transport error flag or without payload are skipped, as are other PIDs.
- The program association table names the first program's map; the map's first supported audio stream is selected: stream types 0x03 and 0x04 (MPEG audio Layers I-III), 0x0F (AAC in ADTS), 0x11 (AAC in LATM, [LOAS framing](latm.md)), 0x81 (AC-3) and 0x80 ([Blu-ray LPCM](#lpcm), when the program carries an `HDMV` or `HDPR` registration, as FFmpeg requires), or private data (0x06) with the DVB AC-3 descriptor or an `AC-3` registration. Private data without an identifying descriptor (as FFmpeg's M2TS mode writes MPEG audio) is identified from its first PES packet: audio stream ids carry MPEG audio or ADTS, private stream 1 an AC-3 sync frame. Tables must fit in the packet that starts them.
- E-AC-3 (stream type 0x87 or its DVB descriptor), DTS, TrueHD and stream type 0x80 without an HDMV registration reject with `decode_error` 101 when no supported audio stream precedes them; a stream without tables or audio rejects with 100.

## Program streams

- MPEG-2 pack headers with stuffing, MPEG-1 pack headers, system headers and end codes; PES packets of either MPEG version (MPEG-1 stuffing, buffer sizes and time stamps). Bytes between start codes are skipped.
- The first audio stream is selected: stream ids 0xC0-0xDF (MPEG audio) or private stream 1 substreams 0x80-0x87 (AC-3, after their four-byte substream header) and 0xA0-0xA7 ([DVD LPCM](#lpcm)). A 0xA0-0xA7 substream whose first packet's dynamic range byte is not 0x80 is MLP to FFmpeg; it and DTS substreams reject with 101 when nothing else is present.

## LPCM

LAMP reads LPCM as FFmpeg's `pcm_dvd` and `pcm_bluray` decoders read it (`src/lpcm.s`). Each packet's header must repeat the first packet's format.

- DVD: each packet holds the substream number, a frame count and first access unit pointer (both unused), and a three-byte header. The header gives the sample size (16, 20 or 24 bits), the rate (48, 96, 44.1 or 32 kHz) and 1-8 channels. Emphasis, mute, the frame number and dynamic range control are ignored, as in FFmpeg. Samples are big-endian and run on across packets. At 20 and 24 bits they come in groups of four samples (two in mono): the groups' top 16 bits, then their low bits. Only whole blocks of groups play, as in FFmpeg. Channels take FFmpeg's default layout for their count (for example FL FR FC LFE BL BR for six).
- Blu-ray: each PES packet holds a four-byte header and frames of big-endian 16- or 24-bit samples at 48, 96 or 192 kHz. The header's channel assignment is one of mono, stereo, 3/0, 2/1, 3/1, 2/2, 3/2, 3/2+LFE, 3/4 or 3/4+LFE. Channels are padded to an even count in the stream and are remapped to FFmpeg's layouts. A packet's last partial frame is dropped, as FFmpeg decodes whole frames per packet.
- Unsupported (`decode_error` 101): 28-bit DVD samples; 20-bit Blu-ray samples, which FFmpeg 6.1 rejects too; reserved Blu-ray rates or channel assignments; and a format change. A Blu-ray packet too short for its header is malformed (100), as is a stream without samples.

The samples are converted when the file opens into 16-bit or 24-bit little-endian PCM (20 bits in 24, the low four bits zero), behind a WAVE_FORMAT_EXTENSIBLE format with the layout's channel mask. They then decode, mix and seek as WAV does, and `--check` reports codec 18.

Time stamps are not used: gaps and discontinuities play continuously, and the output starts with the stream's first frame rather than at its first presentation time.

## Verification

`python3 tests/verify-mpegts.py` checks:

- Raw MPEG Layer II and III, ADTS AAC, stereo and 5.1 AC-3 streams written by FFmpeg and copied into transport streams with 188-, 192- and 204-byte packets, with video, AC-3 with the DVB descriptor, two audio streams (the first selected), MPEG-2 VOB and MPEG-1 system streams, and VOB with video: 31 files whose decode equals the raw stream's exactly.
- The transport streams against FFmpeg's decode of the same files: MPEG Layer II 116 dB, Layer III 126 dB (FFmpeg's float decoders), AAC 138 dB, AC-3 139 dB.
- 60 exact seeks in an AC-3 transport stream, M2TS MPEG audio, a transport stream with video and a VOB.
- E-AC-3 (both signallings) rejects as unsupported; video-only transport and program streams and a transport stream without tables reject as malformed; a cancelled open stops cleanly; one transport stream plays through the Linux null sink.

LATM transport streams are checked by `tests/verify-latm.py` ([LATM notes](latm.md#verification)).

`python3 tests/verify-lpcm.py` checks LPCM:

- FFmpeg-written files, each equal to LAMP's decode of FFmpeg's WAVE copy of the same stream, channel masks included:
  - 17 DVD VOB files: `pcm_dvd` at 16 and 24 bits, 48 and 96 kHz, mono, stereo, 5.1 and 7.1 (within FFmpeg's encoder's 9.8 Mbit/s limit), and `pcm_s16be` at 44.1 and 32 kHz;
  - 20 Blu-ray M2TS files: `pcm_bluray` with all ten channel assignments at 16 and 24 bits and 48–192 kHz.
- 25 DVD streams written by `tests/lpcm_vectors.py`: 1–8 channels at 16, 20 and 24 bits at all four rates, with sample blocks straddling packets and the emphasis, mute and frame number bits set, plus a stream with a second substream (the first plays).
- 21 Blu-ray streams written by the same file: every assignment at 16 and 24 bits in 188- and 192-byte transport streams, plus packets ending in seven bytes of a cut frame.
- Each written stream's LAMP decode equals a WAVE file of the samples written, and FFmpeg's decode equals the samples.
- 90 seeks in DVD and Blu-ray files equal continuous decoding.
- 11 rejections:
  - unsupported (101): 28-bit DVD samples, a DVD substream marked as MLP, 20-bit Blu-ray samples, a reserved rate, a reserved assignment, a format change in each kind, and stream type 0x80 without an HDMV registration;
  - malformed (100): a Blu-ray packet too short for its header, Blu-ray packets holding only headers, a DVD stream shorter than one block.
- A cancelled open stops cleanly, and a Blu-ray 5.1 stream plays through the Linux null sink.

`tests/verify-robustness.py` also mutates a DVD VOB and a Blu-ray M2TS file 500 times each.
