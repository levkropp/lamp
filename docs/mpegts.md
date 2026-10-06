# MPEG transport and program streams

LAMP 0.4.0-dev plays the audio of MPEG-2 transport streams (`.ts`, `.m2ts`, `.mts`) and MPEG-1/MPEG-2 program streams (`.mpg`, `.mpeg`, `.vob`) with a handwritten demuxer (`src/mpegts.s`) following ISO/IEC 13818-1. The first supported audio stream is gathered from its PES packets into one buffer, which then opens as the raw stream it carries, so decoding, timing and seeking are those of `.mp3`, `.aac`, [`.loas`](latm.md) and [`.ac3`](ac3.md) files. Video, subtitles and other streams are skipped.

## Transport streams

- 188-byte packets, 192-byte M2TS/BDAV packets (a 4-byte time stamp before each) and 204-byte packets (16 parity bytes after each); at least five consecutive packets (or every packet of a shorter file) must start with the sync byte. Packets with the transport error flag or without payload are skipped, as are other PIDs.
- The program association table names the first program's map; the map's first supported audio stream is selected: stream types 0x03 and 0x04 (MPEG audio Layers I-III), 0x0F (AAC in ADTS), 0x11 (AAC in LATM, [LOAS framing](latm.md)) and 0x81 (AC-3), or private data (0x06) with the DVB AC-3 descriptor or an `AC-3` registration. Private data without an identifying descriptor (as FFmpeg's M2TS mode writes MPEG audio) is identified from its first PES packet: audio stream ids carry MPEG audio or ADTS, private stream 1 an AC-3 sync frame. Tables must fit in the packet that starts them.
- E-AC-3 (stream type 0x87 or its DVB descriptor), DTS, TrueHD and Blu-ray LPCM reject with `decode_error` 101 when no supported audio stream precedes them; a stream without tables or audio rejects with 100.

## Program streams

- MPEG-2 pack headers with stuffing, MPEG-1 pack headers, system headers and end codes; PES packets of either MPEG version (MPEG-1 stuffing, buffer sizes and time stamps). Bytes between start codes are skipped.
- The first audio stream is selected: stream ids 0xC0-0xDF (MPEG audio) or private stream 1 substreams 0x80-0x87 (AC-3, after their four-byte substream header). DVD LPCM and DTS substreams reject with 101 when nothing else is present.

Time stamps are not used: gaps and discontinuities play continuously, and the output starts with the stream's first frame rather than at its first presentation time.

## Verification

`python3 tests/verify-mpegts.py` checks:

- Raw MPEG Layer II and III, ADTS AAC, stereo and 5.1 AC-3 streams written by FFmpeg and copied into transport streams with 188-, 192- and 204-byte packets, with video, AC-3 with the DVB descriptor, two audio streams (the first selected), MPEG-2 VOB and MPEG-1 system streams, and VOB with video: 31 files whose decode equals the raw stream's exactly.
- The transport streams against FFmpeg's decode of the same files: MPEG Layer II 116 dB, Layer III 126 dB (FFmpeg's float decoders), AAC 138 dB, AC-3 139 dB.
- 60 exact seeks in an AC-3 transport stream, M2TS MPEG audio, a transport stream with video and a VOB.
- E-AC-3 (both signallings) and DVD LPCM reject as unsupported; video-only transport and program streams and a transport stream without tables reject as malformed; a cancelled open stops cleanly; one transport stream plays through the Linux null sink.

LATM transport streams are checked by `tests/verify-latm.py` ([LATM notes](latm.md#verification)).
