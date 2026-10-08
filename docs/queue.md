# Playing several files

The shared queue/playlist, explicit rate, start-position, track and keyboard navigation policies also apply to the native Mac CLI. Resume, per-entry tag announcements and the additional graphical queue controls below remain Windows/Linux features. See [Mac coverage](macos.md).

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

## Starting later, navigation and repeat

Options come before the files, and `--` ends them:

```sh
./build/lamp-cli --start 1:30 album/*.flac        # the first file from 1 min 30 s
./build/lamp-cli --repeat intro.mp3 loop.flac     # the list again and again
./build/lamp-cli --decode --start 12.5 in.opus out.f32
```

- `--start TIME` takes seconds, `M:S` or `H:M:S`, the seconds with an optional fraction (`90`, `1:30`, `0:01:30.250`). The first file of a playback, `--check` or `--decode` begins there; later files begin at their start. `--check` and `--decode` read from TIME exactly, as the decoder's seek (`queue_start`, a seek then the frames before TIME read and dropped) equals continuous decoding. A start past the first file's known end gives nothing of it.
- `--repeat` plays the list again from its first file after the last, gaplessly, until a key stops it. It applies to playback only.

During console playback (Linux, Windows and macOS):

| Key | Action |
| --- | --- |
| Space | Pause or resume |
| N or `>` | The next file (with repeat, the first after the last; without, the end) |
| P or `<` | The heard file from its start when more than 3 s of it played, else the previous file |
| Right / Left | 5 s forward / back in the heard file |
| Up / Down | 60 s forward / back in the heard file |
| `]` / `[` | Next / previous chapter in the heard file ([chapter rules](chapters.md)) |
| R | Repeat on or off (turned on after the last file was read, the list starts again when it ends) |
| Q, Ctrl+C | Stop |

## Resume

`--resume` (playback only) remembers where a list stopped:

- Q or Ctrl+C keeps the list's key, the file being heard and the position in it. The key is the absolute path of the list's first file (after playlist expansion).
- The next `--resume` run of the same list starts there, printing `Resuming at H:MM:SS.mmm`, in whichever of the list's files was heard.
- Playing to the end forgets the list. `--start` wins over a kept position (and Q still keeps the new one).
- The state is a UTF-8 text file of `milliseconds<TAB>key<TAB>heard file` lines, newest first, at most 256 (`src/resume.s`). It lives at `$XDG_STATE_HOME/lamp/resume` or `~/.local/state/lamp/resume` on Linux, and at `%LOCALAPPDATA%\LAMP\resume.txt` on Windows. Other lists' lines stay and malformed lines are dropped.
- It is rewritten through a temporary file and a rename, so an interrupted write leaves the old file. Failures to read or write it are silent.

The queue notes where each file starts in its output, to the frame, so a key acts on the file being heard rather than on one the decoder already reads ahead. A key stops the stream with a command; the CLI then reopens the queue at the target (`queue_navigate`, `queue_goto`) and starts a new stream, as the Windows player restarts for its seeks. Natural transitions stay gapless; a key's transition is a new stream. Seeks keep the session rate. In a resampled file the decoder seeks a filter half-width before the target and the resampler restarts there, so the output from the target on equals continuous decoding. `--rate` sets the session rate for every file, the first included (see [device notes](devices.md#rates-and-channels)).

The shared timeline retains 524,288 distinct file boundaries in 8 MiB of zero-initialized storage, twice the PCM ring's frame capacity. Normal queues write only the entries used. Empty opens at the same output frame replace the last boundary, so empty files cannot evict audible history. Lookup uses binary search over a chronological ring and 64-bit publication ordinals. A version sampled before and after lookup detects concurrent overwrite and retries, keeping a record’s start and index coherent. All three consoles use the same sampled position for the lookup and elapsed time. Windows relative seeks carry that paired file index into the restart; timeline clicks use the displayed file index. Seeks preserve pause. If an unusually large output backlog exceeds retained history, lookup reports an unknown file; relative navigation ignores that position and resume does not save it.

## The Windows player

`lamp.exe` plays a list the same way, as one gapless queue:

- **Building the list:**
  - Files and folders named on its command line, dropped on the window, or chosen in the open dialog (O; several at once) replace the list. It plays from its first file.
  - M3U, M3U8 and PLS playlists in the list expand as above.
  - A folder adds its audio files (the open dialog's types, without playlists) and those of its folders, up to eight folders deep. Names are in natural order, as Explorer sorts them (`StrCmpLogicalW`: `2` before `10`), with files and folders together.
  - Hidden and system entries are left out. Files named directly are kept whatever their type; they are skipped at playback when they do not open.
  - A directly built list holds up to 32,768 files; playlist expansion can produce up to 65,536 entries within its path arena.
- **Controls:**
  - With more than one file, previous and next buttons sit beside play/pause.
  - The status strip shows `REPEAT` and the number of the file heard (`2 / 5`).
  - The window's title becomes `Artist – Title - LAMP`, or the file name.

| Key | Action |
| --- | --- |
| Space, media play/pause | Pause or resume; with nothing playing, the list again from its first file |
| N, media next | The next file (with repeat, the first after the last; without, nothing after the last) |
| P, media previous | The heard file from its start when more than 3 s of it played, else the previous file |
| Right / Left, a click on the timeline | 5 s forward / back, or the clicked point, in the heard file |
| Home | The heard file from its start |
| `]` / `[` | Next / previous chapter, keeping pause ([chapter rules](chapters.md)) |
| Up / Down, M | Volume, mute |
| R | Repeat on or off |
| O | Open files |
| L | Show or close the queue window |
| Right click, Shift+F10, menu key | The context menu: Open files, Queue, window modes, Repeat, Remember playback position, Previous/Next chapter, Audio track and Output (see [device notes](devices.md)) |
| Q | Close |

The **Queue** window lists the expanded entries in playback order, with their filename, state and full path. L in the player or Queue in its context menu opens it; Esc in the queue closes it. Up/Down, Home/End and Page Up/Down move the selection. Typing finds a filename by its Unicode prefix. Enter or a double click starts that entry from its beginning while retaining pause and its audio-track choice; Space pauses or resumes playback. Duplicate filenames remain separate entries. Opening the view selects the heard entry, and subsequent playback updates its state without moving a selection you are browsing.

The view uses a native virtual list control, reading only requested row text from the existing expanded paths. It does not parse files or add a playback timer. Replacing a list clears its selection and rows before old path storage is released, then shows the new expanded list. Selections from an old generation or while replacement is pending are ignored. The queue has its own DPI-scaled font and columns, and closes with the player. Reordering, removing and saving entries remain future work.

The Windows player's **Remember playback position** context-menu item is off by default. Its choice survives ordinary exits in `%LOCALAPPDATA%\LAMP\player-resume.txt`. When enabled, closing the window or replacing its list saves the heard file and millisecond position, including while paused. The UI captures that pair before stopping the worker and writes it after the worker joins, while the old expanded paths still belong to that list. New command-line, dropped and opened lists consult the same `resume.txt` records as the Windows console's `--resume`; the key is the first expanded file, so opening an M3U8 or its equivalent file list finds the same record. Local paths become absolute when accepted, keeping playback and saved keys stable if a later Open dialog changes the process directory; URL spellings stay intact.

Natural completion forgets only that list's record. Space after completion explicitly replays from the first file; next/previous, seek, chapter and output/track changes use their requested targets. A remembered filename absent from the new list starts it from the first file; duplicate filenames resume their first matching queue entry. Turning the setting off leaves saved records available for future opt-in or console playback. The setting stores file and time; track/output/volume/window preferences remain session choices. Missing or malformed settings default to off, and state I/O failures are silent. Windows state reads and writes are bounded to 16 MiB; larger files are ignored and a later save can replace them with a bounded record. Large saved times saturate during frame conversion and the worker clamps the seek to the file's end. Resume currently accepts absolute Windows paths of at most 4,095 UTF-16 units even though other GUI path operations have a higher bound.

Files open before they are heard, so the window keeps what it shows per file:

- As each file opens, the playback thread (for the first file) or the decoding thread (for later ones) notes it in a ring of 64 entries (`src/win/ui_queue.inc`): where it starts in the output, its length, codec, title, picture and chapter starts.
- The window shows the entry whose start the heard position has reached: the title, picture, time, timeline and codec.
- A timer set for the next entry's start changes them on time, even while the controls are hidden.

The producer prepares metadata before publishing an entry. A [Windows SRW lock](https://learn.microsoft.com/en-us/windows/win32/sync/slim-reader-writer--srw--locks) protects the bounded publication/copy and cover-pointer transfer; the UI reads its own snapshot, so a concurrent overwrite cannot mix fields from different files. Allocation, parsing, picture copying and window calls stay outside the lock. Snapshot ordinals are also 64-bit.

When many short files evict the heard file's metadata from the 64 entries, the shared timeline still identifies its index and start. The window shows its filename and clears unavailable tag title, duration, codec and cover metadata. A short timer follows subsequent heard boundaries while that fallback is active. Chapter commands reopen the identified file on the playback worker, after the previous worker has stopped, then select its chapter and restart with pause preserved. The metadata limit stays bounded even for long queues.

The [Audio track submenu](tracks.md#windows-player) keeps a choice per expanded queue entry, preserves paused position and validates changes on the worker. Each worker receives its own launch snapshot; replacement UI requests cannot change the index, time or pending chapter/track operation it is processing.

Navigation starts a new playback thread at the target file and position (`engine_play_list`), as seeks always did. Natural transitions stay gapless. When the endpoint is lost after playback started, the window reopens the heard file at the heard position, as the console does (see [device notes](devices.md)).

## Verification

The [queue-window callback report](../reports/queue-view-verification.json) records 83 checks using the shipping UI source: protected Unicode text buffers, exact/prefix filename search, stale and pending selections, pause/track preservation, a native 65,536-row virtual list, replacement, reopen and Escape through the main message loop. Run `python3 tests/verify-queue-view.py` under Wine on a display.

The [queue-window player report](../reports/queue-view-player-verification.json) checks the shipping executable through its native controls and captured audio: empty/open/close lifecycle, Unicode prefix search, duplicate filenames, Enter and double-click selection while paused, Space playback, live Open-dialog replacement, heard-file selection after a natural transition, preserved browsing selection, the last of 65,536 expanded entries and 144 DPI. The 22-check [surrounding player regression](../reports/queue-view-player-regression-verification.json) covers existing list, navigation, output, mode, focus, chapter, track and resume behavior. The Xvfb image was inspected; this Wine installation lacks some CJK/emoji font glyphs even though row text round-trips exactly. Native Windows, screen-reader interaction and mixed-monitor moves remain unverified.

The [GUI resume regression report](../reports/gui-resume-player-verification.json) records 22 Wine checks, including eight focused resume cases. `python3 tests/verify-player.py --only resume` exercises opt-in through the real popup, exact paused saves in a Unicode second file, equivalent playlist reopening, replacement through an Open dialog in another directory, oversized saved times, completion/replay, missing filenames, persistent disable, malformed preferences and oversized state. The broader run includes absolute local-path normalization, URL preservation, list/folder playback, output switching, modes, accessibility, chapters, dense queues, per-file track selection and ASF metadata/artwork.

The shared Windows storage refactor also passes all 24 [console navigation/resume checks](../reports/gui-resume-navigation-wine-verification.json). Eight [native timeline checks](../reports/gui-resume-queue-verification.json) and nine [Windows timeline checks](../reports/gui-resume-queue-wine-verification.json) pass; the Windows snapshot oracle adds six resume-capture cases and 1,068 independent frame-conversion boundary/random cases. Resume capture must use the actual heard pair even when a different seek target is pending, and must ignore disabled, inactive, unopened, invalid or expired positions. Windows checks use Wine 8 on Xvfb and a private PulseAudio sink; native Windows behavior remains unverified.

The [negative control](../reports/queue-dense-negative-control.json) reproduced file 5 reported at frame 0 after file 68 decoded ahead, with no decode error.

`python3 tests/verify-queue-timeline.py` ([native report](../reports/queue-timeline-verification.json), [Windows COFF/Wine report](../reports/queue-timeline-wine-verification.json)) checks dense queues of 100 forty-millisecond files at 44.1, 48 and 96 kHz, all played at 48 kHz. After 131,072 frames decode ahead into file 68, 3,279 position queries and 18 restarted PCM comparisons verify the heard file, boundary starts, N/P, seek and chapter navigation; the output ends at a protected page. A further 1,000 empty opens retain only two audible boundaries and preserve all later-file announcements. Repeating one-frame files crosses the list 40 times with 4,096 exact heard queries. Another 10,007 queries seed the complete retained window and ordinals beyond 2^32, including expired-history rejection, through test-only aliases of the shipping source. A two-thread case then performs 4,095 real overwrites of seeded wrapped history while querying the retiring window, followed by 8,192 exact retention checks. One-frame files at 48 and 192 kHz verify that their known submillisecond duration excludes later chapter starts; each still produces one output frame at 48 kHz. The [negative control](../reports/queue-submillisecond-negative-control.json) records the earlier 10 ms seek past a known one-frame file.

The Wine run additionally checks 2,000 concurrent Windows snapshot publications, coherent fields, exclusive cover ownership, 130 seeded 64-bit snapshot queries, four paired-index/pause seek cases, and a one-frame resampled Windows snapshot/chapter case. `python3 tests/verify-player.py --only dense_queue` plays a 101-file list whose first metadata snapshot is evicted, checks the correct paused filename, seeks to three chapter targets without playing while paused, then requires exact resumed first-file PCM ([player regression report](../reports/queue-player-regression-verification.json)). The chapter player scenario also checks paused Home/Right/Left seeks at 0/5/0 seconds before restoring the chapter target. Native Windows hardware remains unverified.

`python3 tests/verify-queue.py` ([report](../reports/queue-verification.json)) checks:

- Eight formats at one rate (FLAC, 24-bit and 8-bit WAV, MP3, AAC, WavPack, Vorbis, ALAC) decode to the exact concatenation of their own decodes; `--check` counts the same frames.
- Opus at 48 kHz, MP3 at 22.05 kHz, FLAC at 96 kHz, WAV at 8 kHz and Vorbis at 32 kHz resample to a 44.1 kHz session exactly as `tests/resample-oracle.c` resamples their own decodes, and 44.1 and 8 kHz files to a 48 kHz session.
- A 48 kHz chained Ogg file resamples to 44.1 kHz; a chain whose links change rate plays at its own rate and is skipped at another.
- Two files that do not open are skipped (exit 2); a truncated FLAC file in the middle contributes its partial decode; the last file keeps its own error; nothing opening fails as a single file does.
- A PLS playlist with an absolute path, a percent-encoded `file://localhost` URI, a nested M3U8 (byte order mark, CRLF, `#EXTINF` and comments, a UTF-8 name with a space, an absolute path, a missing entry and a URL) and a Latin-1 M3U decodes as its expanded list; a playlist naming itself expands four times; an unreadable playlist is skipped.

`python3 tests/verify-navigation.py` ([report](../reports/navigation-verification.json)) checks:

- `--start`: `--decode` of ten formats (FLAC, MP3, Vorbis, Opus, AAC without noise substitution, WAV, WavPack, ALAC, AC-3, MP2) from five start times equals the whole decode without the frames before the start, sample for sample. Opus is exact once its decoder state converges, within half a second. AC-3 matches within its dither, at 50 dB or more.
- `--check --start` counts the same frames, and in a queue only the first file starts late.
- Nine malformed times and misplaced options print the usage.
- Keys through the null sink, on a pseudo-terminal:
  - `--start 2.5`;
  - N, and N on the last file;
  - P to the previous file, and P restarting a file after 3 s;
  - Right then Down;
  - `--repeat`, R, and R twice.

  The captured audio is cut into runs of the files' own decodes, which must follow the expected files, starts and ends.
- `--resume`:
  - Q keeps a file and, in a list, a later file; the next run starts at the kept position.
  - Playing to the end forgets the list. `--start` wins.
  - Two lists are kept newest first.
  - Rewriting a crafted state file of 300 lines and three malformed ones keeps 256 well-formed lines with the new line first.
  - With `--check` it prints the usage.
- `--wine` runs the same checks with the Windows `lamp-cli.exe` ([report](../reports/navigation-wine-verification.json)):
  - Its decodes equal the Linux build's.
  - Its playback goes through Wine's PulseAudio driver, which drops audio here. The order of files, the jumps and the restarts must still match.

`python3 tests/verify-player.py` ([report](../reports/player-verification.json)) runs `lamp.exe` under Wine on a virtual X display (Xvfb), with the private null sink:

- **List building:** `ui-list.exe` runs the player's own list code. It checks:
  - a folder's natural order, its inner folders and the entries left out;
  - files and folders named on the command line or dropped (an HDROP built by the test);
  - the open dialog's results, for one file and for several.
- **Playback:** `ui-driver.exe` sends the window keys, media commands and clicks, and reads its title. The captured audio is matched against each file's decode by order and position, as Wine's driver drops audio. It checks:
  - three files playing gaplessly, the title following each file as it is heard;
  - N, P twice, the media "next" command, the next button, Right, N on the last file, then R and N;
  - a folder and an M3U playlist playing in list order;
  - a stream killed by the server reopening where it was heard;
  - the Output menu moving playback to another endpoint and back;
  - at 144 DPI, a window 1.5 times as large whose scaled next button works.

`python3 tests/verify-playback.py` plays a four-file queue (a 0.3 s first file shorter than the prebuffer, a resampled 44.1 kHz MP3, Opus and WAV) through the private null sink: the captured stream equals the `--decode` output bit for bit, with no gap between files.
