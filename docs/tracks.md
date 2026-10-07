# Audio track selection

By default LAMP plays one audio track per file, chosen by the container's rules: Matroska's default track, else the first supported one; the first supported track of MP4, AVI, an Ogg link or a transport or program stream. `--track N` (with playback, `--check` and `--decode`, in `lamp-cli` and `lamp-cli.exe`) plays each file's Nth audio track instead, counting from 1 in the container's order. That is the order of FFmpeg's `-map 0:a:N-1` and of mpv's `--aid=N`. In a queue the same N applies to every file.

| Container | Audio tracks, in order |
| --- | --- |
| Matroska / WebM | TrackEntries of type audio, in the Tracks element, whether enabled or not. |
| MP4 / MOV | `trak` boxes with a `soun` handler, in `moov`, whether enabled or not. |
| Ogg | Each link's Vorbis, Opus, FLAC, Speex, CELT and OGM audio streams, in BOS order. Every link of a chain plays its own Nth stream. |
| MPEG transport streams | The first program's map: MPEG audio, ADTS and LATM AAC, AC-3/E-AC-3 conventional mantissas, Blu-ray LPCM and the audio LAMP does not decode (DTS, TrueHD), and private data streams without descriptors, in map order. |
| MPEG program streams | Audio stream ids 0xC0-0xDF and private stream 1's audio substreams (AC-3, DTS, LPCM, MLP, TrueHD), in the order their first packets appear (all 104 currently recognized IDs fit in a bounded 128-entry catalog). |
| AVI | `auds` stream lists, in `hdrl` order. |

Every other format holds one audio track: `--track 1` plays it, and any other N rejects the file. A track that does not exist, or one LAMP does not decode (WMA in Matroska or Speex in Ogg), rejects with `decode_error` 101. Within a queue, such a file is skipped like any file that cannot play. The Windows player chooses tracks through its Audio track context submenu; its per-entry policy is described below.

## Windows player

Open the context menu with a right click, Shift+F10 or the menu key, then choose **Audio track → Automatic** or **Track N**. Numbers match `--track N`. The menu shows at most the first 64 ordinals and marks the current choice. It uses the heard file's count, including unsupported tracks, rather than the file decoded ahead. Ogg exposes ordinals present in every link, using the minimum link count; Automatic retains the container's normal per-link choices.

A switch keeps the heard position in milliseconds and preserves pause. When the new track is shorter, the position is clamped to its last representable millisecond. The playback worker validates the requested track after the previous worker stops. If it cannot open, playback keeps the previous track, file and position; the status shows `TRACK UNAVAILABLE`. Parsing and validation stay off the window thread. A menu command is ignored if playback has crossed to another file or a new list has replaced its queue while that menu was open. The returned popup command is dispatched while its captured file index and list generation are held.

Choices belong to individual expanded queue entries. N/P, repeat, seeking and output reconnection retain them. Other entries keep Automatic, so a selected multitrack file does not cause a later single-track file to be skipped. Opening a new list resets all choices. Up to 65,536 entries have fixed storage: 256 KiB for choices and 512 KiB for atomic count/selected-ordinal pairs. The small catalog survives eviction of richer title/cover/chapter metadata. Each worker receives an immutable launch request, preventing a replacement seek/chapter/track request from changing its inputs.

Labels currently identify ordinal numbers; language, title and codec labels and persistent track preferences remain open. Native Windows hardware and screen-reader use remain unverified.

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
- Rejections (`decode_error` 101, through `tests/chain-oracle.c`): a track past the last in each of the six files, WMA in Matroska, and `--track 2` on WAV, MP3 and FLV files, which play with `--track 1`.

Conventional E-AC-3 on a second transport-stream audio track is checked against its isolated stream copy. Unsupported E-AC-3 tools or substreams still reject; see the [profile limits](eac3.md).

Two additional program stream fixtures place 64 synthetic unsupported private audio IDs before independently encoded MPEG Layer II or AC-3 payloads. One exposes ordinal 65; the other exercises all 104 IDs recognized by the parser. Automatic, ordinals 65/73/104, unsupported ordinal 64 and missing ordinals are checked. Selected PCM equals the isolated raw streams. The [negative control](../reports/track-program-stream-negative-control.json) records ordinal 65 rejecting with error 101 in the earlier 64-entry implementation.

The same suite also checks 60 native catalog cases: successful opens publish the count and selected audio ordinal; failed opens clear both, and reopening restores them. Counts include disabled MP4 sound tracks and unsupported codecs. Unequal Ogg links publish the minimum count while retaining the first link's automatic selected ordinal. `--wine-only` repeats those cases with shipping Windows COFF objects, compares ordinals 65 and 104 byte for byte with the native raw-stream PCM, and tests the real Win32 menu, checked labels and 64-item cap, deferred paused handoff, shorter-track clamping, unsupported-track rollback, menu/file and list-generation pairing, immutable worker requests and cancellation, exact two-file queue PCM, repeat and new-list reset ([report](../reports/track-catalog-wine-verification.json)).

`python3 tests/verify-player.py --only track_switching,track_queue` captures the Wine player's sink for eight scenarios: real keyboard popup selection of Track 2, paused switches at five seconds and return to Automatic in Matroska, MP4, AVI, Ogg and MPEG TS/PS; per-entry choices through N/P with a subsequent single-track file; and an unsupported WMA switch retaining the previous PCM and pause. Fixtures use 48 kHz audio, and comparisons use the corresponding native decoder output. The full player regression also checks the prior list, device, DPI, modes, accessibility, chapter and dense-queue behavior ([report](../reports/track-player-regression-verification.json)). A focused mutation regression covers 1,100 files across eleven changed demuxer/container paths ([report](../reports/track-demux-robustness-verification.json)); the recorded Windows subset covers 110 mutations under Wine ([report](../reports/track-demux-robustness-wine-verification.json)).
