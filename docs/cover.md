# Cover art

LAMP 0.4.0-dev reads embedded pictures when a file opens (`src/cover.inc`, part of the tag reader). FFmpeg's demuxers expose such pictures as attached pictures; of these, LAMP keeps one: the first front cover, or else the first picture. `lamp-cli --cover file image` writes that picture to a new file (it never overwrites one) and prints its type and size:

```sh
$ ./build/lamp-cli --cover album.flac cover.jpg
image/jpeg 223974 bytes
```

The bytes are the embedded image as stored; LAMP neither decodes nor converts them. A file without a picture prints `No embedded cover art.` and exits with code 2.

The Windows player shows the picture above the title while a file plays (`src/win/ui_cover.inc`):

- When a file opens, the playback thread copies the picture, since the mapped file closes with playback.
- The window thread decodes it once through the Windows Imaging Component, scaling it to fit 1024 pixels a side, into premultiplied BGRA. A picture equal to the one shown, as after a seek, is not decoded again.
- The window thread then box-filters it in assembly to fit a square of up to 360 pixels, blends it into the window's pixel canvas over the background and centres it with the title between the header and the controls.
- Windows too small for a 48-pixel picture, and pictures WIC cannot decode, show the title alone.

| Format | Pictures read |
| --- | --- |
| MP3, MP1/MP2, ADTS AAC | ID3v2 `APIC` (2.3, 2.4) and `PIC` (2.2) frames in the ID3v2 tags at the start |
| WAVE, AIFF/AIFC | `APIC` frames in `id3 `/`ID3 ` chunks |
| Native FLAC | `PICTURE` blocks and `METADATA_BLOCK_PICTURE` comments |
| Ogg Vorbis, Opus, FLAC | `METADATA_BLOCK_PICTURE` comments |
| MP4/M4A/M4B/MOV | `covr` items |
| Matroska/WebM | Image attachments |
| WavPack | APEv2 binary items |

LAMP does not read pictures from CAF, AVI, FLV, AU, AC-3, MPEG-TS/PS, RIFX, RF64/BW64 or Wave64 files. FFmpeg reads no ID3v2 pictures before AC-3 data either. Separate `cover.jpg` files are not read.

## Reading rules

The rules follow FFmpeg's demuxers. Pictures may be JPEG, PNG, GIF, BMP, TIFF or WebP.

- ID3v2:
  - MIME types: `image/jpeg`, `image/jpg`, `image/png`, `image/gif`, `image/bmp`, `image/tiff` and `image/webp` in any case; ID3v2.2 uses `JPG` and `PNG`.
  - Picture type: 3 is the front cover. Types past the standard list count as "Other".
  - Frame layout: the description is read as FFmpeg reads text, and a frame needs at least one byte of picture data.
  - Encoding: unsynchronised tags and frames and data length indicators are handled. Compressed and encrypted frames are skipped.
  - Data with PNG's signature is PNG whatever the MIME type says.
- FLAC pictures (blocks and comments):
  - MIME types: the same list, compared exactly, so `IMAGE/PNG` and links (`-->`) are skipped.
  - Picture type: 3 is the front cover.
  - Data must fit in its block, and data with PNG's signature is PNG.
- `METADATA_BLOCK_PICTURE` comments:
  - The value is base64, decoded as `av_base64_decode` decodes it: digits up to an `=` or the end, with any other character rejecting the picture.
  - Pictures in such comments are not tags.
  - In native FLAC, only the first `VORBIS_COMMENT` block is read.
- MP4:
  - `covr` data boxes of type 13, 14 or 27 are pictures; other types are skipped.
  - Type: BMP when the data type says so; otherwise PNG when the data has PNG's signature and JPEG when it does not (as FFmpeg decides).
  - MP4 has no picture types, so the first picture is kept.
- Matroska:
  - An AttachedFile is a picture when it has a FileName, a FileMimeType starting with `image/gif`, `image/jpeg`, `image/png` or `image/tiff` (exact case) and nonempty FileData.
  - A FileName starting with `cover.` (any case) is the front cover.
  - Attachments elements are read where Chapters elements are read: before the first Cluster, or the one a SeekHead names (see [chapter notes](chapters.md)).
- APEv2 (WavPack only; FFmpeg reads no APEv2 tags in MP3):
  - A binary item is a file name, a NUL, then data.
  - It is a picture when the name ends in `.jpg`, `.jpeg`, `.png`, `.gif`, `.bmp`, `.tif`, `.tiff` or `.webp` (any case).
  - The item `Cover Art (Front)` is the front cover.

## Differences from FFmpeg 6.1

- FFmpeg exposes every picture. LAMP keeps one, preferring a front cover; players built on FFmpeg usually show the first picture.
- LAMP does not read APEv2 items named with other image extensions that FFmpeg knows (`.tga`, `.ppm`, `.jps` and others).
- LAMP does not read native FLAC pictures of 16 MiB or more whose block size was truncated (FFmpeg has a workaround for them).

## Verification

`python3 tests/verify-cover.py` ([report](../reports/cover-verification.json)) compares LAMP's picture with FFmpeg's matching attached picture, copied with `-c copy -f rawvideo`. Both the bytes and the type must be equal. It checks:

- Pictures FFmpeg writes in MP3 (ID3v2.4 and ID3v2.3), FLAC, M4A and AIFF, and as Matroska attachments: each file has a back cover first and a front cover second.
- ID3v2 frames written by the test:
  - MIME types in any case, `image/jpg`, an unknown type and no type;
  - PNG data under a JPEG type, a picture type past the list, two front covers, a BMP;
  - an empty picture, ID3v2.2 `PIC` frames (and a GIF one, which FFmpeg skips), a 220 KB picture;
  - unsynchronisation: a whole ID3v2.3 tag, and an ID3v2.4 frame with a data length indicator;
  - containers: before ADTS, in a WAVE id3 chunk, and before AC-3 (no picture).
- FLAC:
  - `PICTURE` blocks with case-sensitive MIME types, a link, an empty picture, PNG under a JPEG type, a type past the list and a block too short for its data;
  - `METADATA_BLOCK_PICTURE` comments in FLAC, Ogg Vorbis and Opus, those in Ogg spanning many pages.
- MP4 `covr` items of every data type, with and without matching signatures, and two `covr` items.
- Matroska attachments:
  - a font before the pictures, a MIME type with parameters, an upper-case MIME type;
  - Attachments after the clusters, named by the SeekHead or not.
- WavPack APEv2 items: front and back covers, other names and extensions, an item without a name. APEv2 pictures in MP3 are not read, as FFmpeg reads none.
- Files without pictures report none.
- 1,000 files with mutated pictures neither crash nor hang.
- The Windows `lamp-cli.exe --cover` writes the same bytes and prints the same line for every test file under Wine.

`python3 tools/build-windows.py --tests --preview-cover --preview-codec 3` builds `ui-preview.exe` with an ID3v2 front cover (`tests/ui-preview-cover.jpg`), which renders the player canvas to `lamp-ui-preview.bmp` through the same tag reader, hand-over, WIC decoding, filtering and blending. Under Wine it was also checked with a wide PNG with transparency and a 2000-pixel JPEG.
