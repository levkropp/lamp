# Recorded verification

These snapshots describe the assembly audio implementation at the 0.3 milestone. Codec/engine and offline benchmark reports were captured before the LAMP branding change; they retain their original measurements. Branding smoke and runtime reports cover the renamed executables and their resources.

Historical executable-size fields in CPU benchmark reports refer to the earlier unbranded binary, without the new icon resources. Neither the earlier CPU measurements nor stress runs establish an advantage over mpv/VLC or uninterrupted playback on other systems.

See [technical details](../docs/technical.md#verification) for test commands, numeric comparison tolerances, and limitations. Opus primitive reports do **not** demonstrate complete Opus audio decoding.

The new `opus-allocation`, `opus-vq` and `opus-band-transform` reports were captured during the next roadmap work. They cover CELT allocation, base PVQ/spreading/renormalization and Haar/Hadamard kernels, including entropy state and invalid-request checks. The complete eight-suite Opus component runner passed locally; hosted CI execution has not been verified.
