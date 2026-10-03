# LAMP 0.3.0

The first public release of LAMP — Lev's Assembly Media Player includes an original two-tone lamp icon, embedded Windows resources, a GitHub Pages website, an mpv-relevant roadmap and a compatibility matrix.

The Windows x86-64 GUI is `bin/lamp.exe`; the console player is `bin/lamp-cli.exe`. Both retain handwritten assembly WAV, FLAC, MP3 and single-stream Ogg/Vorbis playback. Opus is still in development and is not playable. This is an early audio prototype.

The release contains sources, binaries, licenses/reference notices, verification snapshots, and a per-file SHA-256 manifest. Branding verification checks both PE architectures, expected Windows-only imports, icon sizes/version resources, PCM export for all four working formats, lossless WAV/FLAC agreement, existing-output protection, and Opus rejection.

The UI preview uses the actual assembly renderer with synthetic state. Desktop dialog/drop/DPI behavior needs further testing. See the README and technical details for precise codec limits and test scope.
