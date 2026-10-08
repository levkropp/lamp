# macOS build tools

`build-mac.py` builds native ARM64 Mach-O executables and an AppKit bundle. The shared GNU Intel assembly decoders in `src/*.s` remain authoritative; generated AArch64 sources and objects stay under `build/macos`.

- `masm.py`: retained normalizer for the historical MASM source format; the current build reads GNU sources directly.
- `arm64.py`: **unchanged** MIT Rhun translator, pinned to `4d11f81019617e6e3a3922c81f5dedc3025d7884` at <https://github.com/vshvedov/rhun>. Preserve this file when updating LAMP-specific behavior.
- `arm64_lamp.py`: original subclass with the additional instructions/addressing/flags/floating-point behavior required by LAMP.
- `package-mac.py`: app/CLI ZIP, signature/version validation and SHA-256 manifest.

The same Rhun revision supplies unchanged `src/mac/mac.inc` and the adapted string/division routines in `src/mac/runtime.s`. Copyright (c) 2026 Vlad Shvedov; the complete MIT license is in `THIRD_PARTY_NOTICES` and copied into every app/package. LAMP's native platform, Apple ABI, Core Audio, AppKit and CLI files are original assembly.

When updating the translator, record the upstream revision and provenance, keep extensions separate, and rerun the native translation semantics, PCM/layout/Opus and affected format suites. Unsupported translation should fail the build. Reference C and test portability adapters are never linked into the player.

See [the Mac guide](../docs/macos.md) for build/test commands and platform limits. The optional CI template is `docs/workflows/macos.yml`; the repository's other workflow templates follow the same opt-in convention.
