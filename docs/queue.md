# Playing several files

`lamp-cli` accepts several files and plays, checks or exports them as one gapless stream:

```sh
./build/lamp-cli side-a/*.flac
./build/lamp-cli --check intro.mp3 album.flac
./build/lamp-cli --decode one.opus two.m4a three.wav joined.f32
```

The queue (`src/queue.s`) sits between the playback engines and the decoder. `queue_read` reads the current file and, when it ends, opens the next one within the same call, so the PCM ring never drains between files and the last sample of one file is followed directly by the first of the next. Each file decodes exactly as it would alone: trims, edit lists and pre-skip apply per file, and the output is the concatenation of the files' own decodes.

The first file that opens sets the session rate, which the audio stream (or the exported PCM) uses. A later file at another rate passes through LAMP's windowed-sinc resampler (the one chained Ogg links use; see [Ogg notes](ogg.md)), yielding ceil(N × session rate / file rate) frames for N frames of its own. A chained Ogg file whose links change rate already uses that resampler, so it plays only when the session runs at the chain's rate and is skipped otherwise.

Files that do not open are skipped with a message (`Skipped (unsupported, malformed, or inaccessible): path`). A file whose decoding fails, or that ends before its declared length, contributes the audio decoded before the failure and the queue continues. When anything was skipped, the run ends with `decode_error` 6 and exit code 2, unless the last file failed: then its own error is kept. If no file opens, `lamp-cli` reports the usual open error.

During playback the first file's tags are printed before it starts and each later file's tags when the queue moves to it. The status line reports the session rate and the total frames; codec, channel and bit fields describe the last file. Seeking (the Windows player) applies within the current file of a queue without rate conversion. `--tags` takes one file.

## Playlists

M3U, M3U8 and PLS playlists on the command line are replaced by their entries (`src/playlist.s`), recognized by the extension `.m3u`, `.m3u8` or `.pls` in any case:

- M3U/M3U8: one entry per line; lines starting with `#` (`#EXTM3U`, `#EXTINF` and others) and empty lines are skipped.
- PLS: `FileN=` lines (any case), in file order; titles, lengths and other lines are skipped.
- Text is UTF-8 with an optional byte order mark and LF or CRLF line ends; a line that is not valid UTF-8 is read as Latin-1, as older `.m3u` files often are.
- Relative entries resolve against the playlist's directory. `file://` URIs (with or without `localhost`) are percent-decoded; other URLs are not supported and are skipped with the usual message, as are entries that do not exist.
- Playlists inside playlists expand too, to a depth of four, so a playlist that names itself ends.
- A playlist that cannot be read is skipped like a file that does not open. Up to 65,536 entries and 4 MiB of paths are kept; longer playlists are cut.

The Windows player still opens one file at a time; drag-and-drop queues, repeat and track navigation remain on the [roadmap](../ROADMAP.md).

## Verification

`python3 tests/verify-queue.py` ([report](../reports/queue-verification.json)) checks:

- Eight formats at one rate (FLAC, 24-bit and 8-bit WAV, MP3, AAC, WavPack, Vorbis, ALAC) decode to the exact concatenation of their own decodes; `--check` counts the same frames.
- Opus at 48 kHz, MP3 at 22.05 kHz, FLAC at 96 kHz, WAV at 8 kHz and Vorbis at 32 kHz resample to a 44.1 kHz session exactly as `tests/resample-oracle.c` resamples their own decodes, and 44.1 and 8 kHz files to a 48 kHz session.
- A 48 kHz chained Ogg file resamples to 44.1 kHz; a chain whose links change rate plays at its own rate and is skipped at another.
- Two files that do not open are skipped (exit 2); a truncated FLAC file in the middle contributes its partial decode; the last file keeps its own error; nothing opening fails as a single file does.
- A PLS playlist with an absolute path, a percent-encoded `file://localhost` URI, a nested M3U8 (byte order mark, CRLF, `#EXTINF` and comments, a UTF-8 name with a space, an absolute path, a missing entry and a URL) and a Latin-1 M3U decodes as its expanded list; a playlist naming itself expands four times; an unreadable playlist is skipped.

`python3 tests/verify-playback.py` plays a four-file queue (a 0.3 s first file shorter than the prebuffer, a resampled 44.1 kHz MP3, Opus and WAV) through the private null sink: the captured stream equals the `--decode` output bit for bit, with no gap between files.
