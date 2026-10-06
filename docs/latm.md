# AAC in LOAS/LATM

LAMP 0.4.0-dev plays AAC carried in LATM (ISO/IEC 14496-3, 1.7), framed by LOAS sync words. DVB broadcasts carry AAC this way, and FFmpeg's `latm` muxer writes it to `.loas` and `.latm` files. A handwritten demuxer (`src/latm.s`) reads the frames when the file opens. It realigns each AAC payload to whole bytes as a packet of the [track layer](matroska.md#track-layer), and the [AAC decoder](aac.md) decodes them as it decodes ADTS, MP4 and Matroska packets. Decoding, timing and seeking are therefore those of raw ADTS files. Parsing follows FFmpeg's LATM decoder (`libavcodec/aacdec.c`).

## Coverage

- LOAS AudioSyncStream frames: the 0x2B7 sync, a 13-bit length and one AudioMuxElement. Raw files may start with an ID3v2 tag and end with an ID3v1 tag. A file is recognised by two consecutive frames, or by one frame that fills it.
- StreamMuxConfig of audioMuxVersion 0 or 1 (taraBufferFullness, ascLen and the bits it covers), one program and one layer, frame length type 0 (byte counts), other data in either version's coding, and the configuration CRC (read, not checked). Frames with useSameStreamMux use the last configuration.
- AudioSpecificConfig: object types 1–4 (LC; Main, SSR and LTP reach the AAC decoder, which rejects them), with SBR (object type 5) or PS (object type 29) around them and escaped object types. GASpecificConfig with a channel configuration, the core coder delay and the extension flag. In version 1, the backward-compatible SBR and PS signalling inside ascLen reaches the decoder, as from MP4.
- Payloads: each sub-frame's PayloadLengthInfo and payload, at any bit position.
- MPEG transport streams: stream type 0x11 opens the gathered PES data as a LOAS stream ([MPEG-TS notes](mpegts.md)). PES packets need not start at a frame. A stream of that type that starts with an ADTS frame plays as ADTS, as FFmpeg plays it; FFmpeg writes such streams when it copies ADTS with `-mpegts_flags latm`.

Frames before the first StreamMuxConfig use it. FFmpeg's command line decodes them too, because its stream probe has found the configuration before decoding starts. A frame whose payloads run past the frame, or leave more than 256 bits after the last, is skipped, as FFmpeg skips it (a length that cannot be the frame's). A frame cut by the end of the file ends the stream; data other than a frame or a trailing ID3v1 tag between frames rejects the file as malformed (`decode_error` 100), as in ADTS.

### Differences from FFmpeg

- FFmpeg 6.1 reads only the first sub-frame of a frame and then finds the rest of the frame too long, so it decodes nothing from a stream of two or more sub-frames per frame (numSubFrames above 0). LAMP decodes every sub-frame.
- FFmpeg reconfigures its decoder when the configuration's rate or channel configuration changes mid-stream. LAMP rejects any change in the AudioSpecificConfig as unsupported.

Rejected with `decode_error` 101: audioMuxVersionA 1, several programs or layers, fixed, CELP or HVXC frame lengths (frame length types 1–7), other object types, channel configuration 0 (a program config element), configurations the AAC decoder does not support (such as 960-sample frames), and a configuration change. Malformed (100): no StreamMuxConfig at all, a StreamMuxConfig running past its frame, an ascLen shorter than the configuration it covers, or a configuration of more than 48 bytes.

## Verification

`python3 tests/verify-latm.py` checks:

- 24 FFmpeg LATM streams copied from FFmpeg-encoded ADTS: mono at 8, 16 and 22.05 kHz, stereo at 32–96 kHz and 5.1 at 48 kHz, each with the StreamMuxConfig in every frame, every 20 frames (FFmpeg's default) and every 1,000. LAMP's decode equals its ADTS decode exactly, FFmpeg's equals FFmpeg's ADTS decode, and the stereo 48 kHz stream matches FFmpeg at 138 dB.
- Streams written by `tests/latm_vectors.py` from the stereo stream's frames:
  - version 1, with fill bits inside ascLen;
  - other data in version 1, and in version 0 with an escaped length;
  - the configuration CRC;
  - five frames before the first configuration;
  - frames whose lengths are too short or run past the frame, skipped;
  - payload lengths coded in two and three bytes (payloads of 255 bytes and more) in every stream;
  - two, three and four sub-frames per frame.

  Each equals the ADTS decode of the frames it carries. FFmpeg's decode agrees except for the sub-frames.
- HE-AAC streams written by `tests/sbr_vectors.py`:
  - stereo SBR with implicit signalling, object type 5, and the backward-compatible sync extension in version 1;
  - mono PS, implicit and with object type 29.

  Each equals its ADTS decode exactly, and FFmpeg agrees. `sbrPresentFlag` 0 plays the 24 kHz core, matching FFmpeg.
- Transport streams, each equal to the raw stream's decode:
  - FFmpeg's `-mpegts_flags latm` encode, which also matches FFmpeg at 138 dB;
  - three LOAS streams FFmpeg copied into transport streams;
  - three transport streams written by the test: sub-frames, and LOAS frames straddling PES packets;
  - the ADTS stream FFmpeg labels LATM.
- 75 seeks (`tests/seek-oracle.c`) in three LOAS files, a sub-frame stream and a transport stream equal continuous decoding.
- An ID3v2 tag before and an ID3v1 tag after the stream leave the decode unchanged. `--tags` reads the ID3v2 title and ignores the ID3v1 tag, as FFmpeg does.
- 13 rejections:
  - unsupported (101): audioMuxVersionA, two programs, two layers, fixed and CELP frame lengths, object types 23 (ER AAC LD) and 42 (USAC, an escaped type), a program config element, 960-sample frames, a configuration change;
  - malformed (100): an ascLen one bit short, data between frames, no configuration.

  A cancelled open stops cleanly, and an HE-AAC stream plays through the Linux null sink.

`tests/verify-robustness.py` also mutates a LOAS file and a LATM transport stream 500 times each.
