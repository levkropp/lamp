#!/bin/sh
# Native macOS ARM64 build. Windows remains build.ps1.
set -eu
cd "$(dirname "$0")"
exec python3 tools/build-mac.py "$@"
