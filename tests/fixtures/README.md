# Small integration fixtures

Original synthetic 440 Hz sine, 0.25 seconds, 48 kHz stereo. The generated signal is dedicated to the public domain under CC0. No recorded music is included.

Created with FFmpeg 8.0.1 using:

```text
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.25 -ac 2 [encoder] tone.[extension]
```

Encoders: WAV pcm_s16le; FLAC flac; MP3 libmp3lame at 128k; Ogg/Vorbis libvorbis quality 4; Ogg/Opus libopus. These are integration fixtures, not a complete conformance suite.
