# Audio track selection

By default LAMP plays one audio track per file, chosen by the container's rules: Matroska's default track, else the first supported one; the first supported track of MP4, AVI, an Ogg link or a transport or program stream. `--track N` (with playback, `--check` and `--decode`, in `lamp-cli` and `lamp-cli.exe`) plays each file's Nth audio track instead, counting from 1 in the container's order. That is the order of FFmpeg's `-map 0:a:N-1` and of mpv's `--aid=N`. In a queue the same N applies to every file.

| Container | Audio tracks, in order |
| --- | --- |
| Matroska / WebM | TrackEntries of type audio, in the Tracks element, whether enabled or not. |
| MP4 / MOV | `trak` boxes with a `soun` handler, in `moov`, whether enabled or not. |
| Ogg | Each link's Vorbis, Opus, FLAC, Speex, CELT and OGM audio streams, in BOS order. Every link of a chain plays its own Nth stream. |
| MPEG transport streams | The first program's map: MPEG audio, ADTS and LATM AAC, AC-3, Blu-ray LPCM and the audio LAMP does not decode (E-AC-3, DTS, TrueHD), and private data streams without descriptors, in map order. |
| MPEG program streams | Audio stream ids 0xC0-0xDF and private stream 1's audio substreams (AC-3, DTS, LPCM, MLP, TrueHD), in the order their first packets appear. |
| AVI | `auds` stream lists, in `hdrl` order. |

Every other format holds one audio track: `--track 1` plays it, and any other N rejects the file. A track that does not exist, or one LAMP does not decode (WMA in Matroska, E-AC-3 in a transport stream, Speex in Ogg), rejects with `decode_error` 101. Within a queue, such a file is skipped like any file that cannot play. The Windows player window has no track control yet.

## Verification

`python3 tests/verify-tracks.py` ([report](../reports/tracks-verification.json)) checks:

- FFmpeg writes files with two or three audio tracks of different codecs, some with video:
  - Matroska with Opus, FLAC and AAC, the second marked default;
  - MP4 with AAC, ALAC and AAC;
  - a transport stream with MPEG Layer II, AC-3 and AAC;
  - a VOB with Layer II and AC-3;
  - AVI with PCM and MP3;
  - Ogg with Vorbis, Opus and FLAC multiplexed.

  For each track, LAMP's decode with `--track N` equals its decode of FFmpeg's copy of that track alone (`-map 0:a:N-1 -c copy`) in the same container, and FFmpeg's decodes of the two agree. Without `--track`, the choice is unchanged: track 2 (the default) in the Matroska file, track 1 elsewhere.
- A chain of two Ogg links, each with Opus and Vorbis, plays each link's Vorbis stream with `--track 2`.
- In an Ogg file of Speex and Opus, Speex counts as track 1 and rejects when chosen. The Opus stream, whose header is on the file's second page, plays by default and as track 2.
- `--track 3` in a queue of the Matroska and MP4 files plays track 3 of each.
- Rejections (`decode_error` 101, through `tests/chain-oracle.c`): a track past the last in each of the six files, WMA in Matroska, E-AC-3 in a transport stream, and `--track 2` on WAV, MP3 and FLV files, which play with `--track 1`.
