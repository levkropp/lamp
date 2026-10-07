# Chapters

LAMP 0.4.0-dev reads a file's chapter list when the file opens (`src/chapters.inc`, part of the tag reader). `lamp-cli --chapters file` (one file) prints one line per chapter: its start as `HH:MM:SS.mmm`, rounded down to the millisecond, then its title. Chapters are listed in the order FFmpeg's demuxers list them, which is not always time order:

```sh
$ ./build/lamp-cli --chapters audiobook.m4b
00:00:00.000 Opening Credits
00:01:12.480 Chapter 1
00:24:03.105 Chapter 2
```

A file without chapters prints nothing. During playback, `]` seeks to the next chapter and `[` seeks to the previous chapter in the file being heard, in both consoles and the Windows player. The Windows context menu also offers Previous chapter and Next chapter. Chapter seeks preserve pause.

Navigation uses chronological start times, rounding down to the millisecond, while `--chapters` retains the original list order. Duplicate times form one boundary. Previous restarts the current chapter after more than three seconds of it; within three seconds it goes to the preceding boundary. The file's beginning is an implicit boundary. Starts at or past the known audio duration are ignored. With no usable chapters or no next boundary, the heard position stays unchanged. Chapter navigation stays in the heard file, including with repeat enabled.

The console reopens the heard file before choosing its chapter, since decoder metadata may already describe a later queued file. It uses the normal exact start/seek path, including rate conversion. The Windows player snapshots up to 1024 nanosecond starts in each of its 64 heard-file entries, alongside the title and picture; the fixed tables reserve 512 KiB and copy only the starts present. Keys and menu commands use an owned snapshot and preserve the pause state through the playback restart. If dense decode-ahead evicts that metadata, the shared queue timeline identifies the heard file and a cancellable reopen on the playback worker restores its chapter table before selecting the target. No file parsing runs on the window thread. See [dense queue coverage and retention limits](queue.md#verification).

| Format | Chapters read |
| --- | --- |
| Ogg Vorbis, Opus, FLAC; native FLAC | `CHAPTERnnn=HH:MM:SS.mmm` comments, titled by `CHAPTERnnnNAME` comments |
| Native FLAC | `CUESHEET` tracks except the lead-out, at their offsets, titled by their ISRC |
| MP3, MP1/MP2, ADTS AAC | ID3v2.3/2.4 `CHAP` frames in the ID3v2 tags at the start |
| WAVE, AIFF/AIFC | `CHAP` frames in `id3 `/`ID3 ` chunks |
| Matroska/WebM | The ChapterAtoms of every edition |
| MP4/M4A/M4B/MOV | The Nero `chpl` box and QuickTime chapter text tracks |

CAF, AVI, FLV, AU, WavPack, AC-3, MPEG-TS/PS, RIFX, RF64/BW64 and Wave64 chapters are not read, and neither are separate `.cue` files.

## Reading rules

The rules follow FFmpeg's demuxers, so `lamp-cli --chapters` agrees with `ffprobe -show_chapters`:

- Each source numbers its chapters: by comment number, cue sheet track, `CHAP` frame order, ChapterUID, or `chpl` entry and text track sample index. A chapter whose number was already seen moves the earlier chapter to its start and replaces its title, or removes it, as `avpriv_new_chapter` does. So a FLAC cue sheet track replaces the comment chapter with the same number. An MP4 chapter text track replaces the `chpl` entries at its sample indexes; `chpl` entries past the track's last sample stay.
- Vorbis comments: a key of `CHAPTER`, up to three digits and nothing more (10 bytes at most) gives a start, read as `sscanf("%02d:%02d:%02d.%03d")` reads it. White space and a `+` are allowed. The last field counts milliseconds, so `.4` is 4 ms. A longer key ending in `NAME` titles the chapter with that number. Before that chapter exists, the comment stays an ordinary comment. Chapter comments are not tags.
- FLAC `CUESHEET`: each track's offset, in samples at the STREAMINFO rate. Index point offsets are not added. FFmpeg rejects the whole file when a cue sheet is too short, has no tracks or has a track without index points. LAMP still opens such a file and keeps the tracks before the fault.
- ID3v2 `CHAP` frames:
  - Where they are read: in the leading ID3v2 tags of MPEG audio and ADTS files, and in WAVE and AIFF ID3 chunks. FFmpeg reads no ID3v2 chapters before AC-3, WavPack or FLAC data, and LAMP follows it.
  - Timing: the start is in milliseconds. A frame whose end precedes its start is dropped.
  - Title: the first nonempty `TIT2` sub-frame. Without one, the element ID, read as Latin-1, is the title.
  - FFmpeg's sub-frame reading is reproduced:
    - sub-frames are read while more than a 10-byte header is left;
    - a text sub-frame is read only to the end of its first string (or a `TXXX` value), and the next header is read from there;
    - a sub-frame running past the frame drops the chapter.
  - `CTOC` frames are skipped.
- Matroska:
  - Which elements: every Chapters element before the first Cluster. After the first Cluster, only the Chapters element a SeekHead names, and only when none came before.
  - Which atoms: the ChapterAtoms at the top of each EditionEntry; nested atoms and the hidden, enabled and ordered flags are ignored. An atom needs a nonzero ChapterUID and a ChapterTimeStart later than the last accepted atom's start, unless that start was 0. An atom ending before its start is dropped, but its start still counts as the last start.
  - Title: the last ChapString of the atom's ChapterDisplays, whatever its language.
- MP4:
  - `chpl`: read first, from `moov/udta/chpl` (version 0 or 1, 100 ns units, titles up to 255 bytes).
  - Chapter text tracks: then come the tracks named by the last `tref/chap` box, in its order. Each sample is one chapter, timed in the track's `mdhd` timescale; edit lists are not applied.
  - Sample text: a 16-bit length, then UTF-8 text, or UTF-16 after a byte order mark. A sample whose length runs past the sample is skipped.
  - A track with a video handler (chapter images) gives no chapters.
- A title ends at its first NUL. LAMP keeps up to 1024 bytes, cut at a character boundary. `lamp-cli` prints control characters as spaces, and prints an empty title as no title. LAMP keeps up to 1024 chapters per file and 256 KiB of titles. Chapter end times and other chapter metadata are not kept.

## Differences from FFmpeg 6.1

- LAMP reads ID3v2.4 `CHAP` sub-frame sizes as synchsafe integers, as the standard specifies. FFmpeg reads plain integers, so it drops chapters with a sub-frame of 128 bytes or more, even from its own ID3v2.4 writer.
- LAMP opens FLAC files whose cue sheet FFmpeg rejects (see above).
- LAMP does not read chapter comments with negative numbers or fields (`CHAPTER-01`).
- For Ogg, LAMP reads only the comment packet of the first stream it decodes. FFmpeg reads every stream's comments.

## Verification

`python3 tests/verify-chapter-navigation.py` ([native report](../reports/chapter-navigation-verification.json), [Windows COFF/Wine report](../reports/chapter-navigation-wine-verification.json)) checks 24 boundary cases: chronological boundaries, duplicate and fractional starts, the three-second rule, missing/out-of-range chapters, unknown duration and 1024 starts ending at a protected page. Queue checks first decode ahead into a file with different chapters, then navigate the heard file and compare PCM with continuous decoding at 44.1 and 48 kHz: 112 exact seeks across MP3, MP4/ALAC, Matroska/ALAC, FLAC, Ogg/Vorbis, chaptered WAVE and WAVE without chapters. Console key playback and the Windows player's bracket keys, focused-control forwarding, menu commands and paused seeks have separate sink checks ([player report](../reports/chapter-player-verification.json)), including half a second of captured silence while a console chapter seek stays paused. `--wine-only` links the guarded oracle with shipping Windows objects and compares against the native references. The existing [25 navigation/resume checks](../reports/chapter-navigation-regression-verification.json) and [40 chapter-reader checks plus 1,100 mutations](../reports/chapter-reader-regression-verification.json) also pass. Native Windows remains unverified.

`python3 tests/verify-chapters.py` ([report](../reports/chapters-verification.json)) checks:

- Chapters FFmpeg writes, with non-ASCII, escaped and missing titles and starts that are not whole milliseconds, in 10 files: Matroska, WebM, M4A, M4B, QuickTime MOV, ID3v2.4 and ID3v2.3 MP3, ADTS, AIFF and Opus. Each equals ffprobe.
- Vorbis chapter comments written by the test in FLAC and Ogg Vorbis, in every form `ogm_chapter` reads or ignores: names before their chapter, any case, short fields, white space and `+`, extra text, moved chapters, keys that are too long or too short.
- FLAC cue sheets, alone and merged with comment chapters.
- ID3v2.3 and ID3v2.4 `CHAP` frames:
  - order and timing: out of order, ending before they start or never;
  - titles: without `TIT2`, with Latin-1 element IDs, with repeated, empty or undecodable `TIT2`;
  - sub-frame layout: UTF-16 and `TXXX` sub-frames before others, bytes after a first string, a sub-frame running past the frame;
  - containers: an unsynchronised tag, two tags in a row, before MPEG Layer II, in a WAVE id3 chunk, and before AC-3 (no chapters).
- Matroska:
  - atoms: two editions, zero and 64-bit UIDs, missing and empty starts, starts out of order, an end before the start, a repeated UID, two displays, a nested atom and starts at 0;
  - elements: a second Chapters element, and Chapters after the clusters, named by the SeekHead or not.
- MP4:
  - `chpl` alone and a chapter text track alone;
  - a `chpl` longer than the track;
  - a `tref/chap` naming a missing track first;
  - a video chapter track;
  - a sample whose length runs past it;
  - UTF-16BE and UTF-16LE titles.
- Files without chapters print none, every comparison equals ffprobe, and the documented differences match their expected values.
- 1,100 files with mutated chapter data neither crash nor hang.
- The Windows `lamp-cli.exe --chapters` prints the same lines (with CRLF) for every test file under Wine.
