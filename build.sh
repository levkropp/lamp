#!/bin/sh
# Builds the static Linux x86-64 lamp-cli with GNU as and ld; no C library.
# usage: ./build.sh [release] [output-directory]
# Windows binaries: python3 tools/build-windows.py (LLVM; any host).
set -e
cd "$(dirname "$0")"
if [ "$(uname -s)" = Darwin ]; then
    exec python3 tools/build-mac.py "$@"
fi
mode=debug
[ "$1" = release ] && { mode=release; shift; }
out=${1:-build}
mkdir -p "$out/obj"
ASFLAGS="--64 -I src -I src/linux"
[ "$mode" = release ] || ASFLAGS="$ASFLAGS -g"
objs=""
for s in $(ls src/*.s src/linux/*.s | LC_ALL=C sort); do
    o="$out/obj/$(echo "$s" | sed 's|^src/||; s|/|_|g; s|\.s$|.o|')"
    stale=
    [ -f "$o" ] || stale=1
    [ -z "$stale" ] && [ "$s" -nt "$o" ] && stale=1
    # Includes are shared; rebuild when any changed after this object.
    [ -z "$stale" ] && [ -n "$(find src -name '*.inc' -newer "$o" -print -quit)" ] && stale=1
    if [ -n "$stale" ]; then
        as $ASFLAGS -o "$o" "$s"
    fi
    objs="$objs $o"
done
LDFLAGS="-static -nostdlib --no-dynamic-linker -z noexecstack"
[ "$mode" = release ] && LDFLAGS="$LDFLAGS -s"
relink=
[ -f "$out/lamp-cli" ] || relink=1
for o in $objs; do [ "$o" -nt "$out/lamp-cli" ] && relink=1; done
if [ -n "$relink" ]; then
    # Link beside the target and rename, so a running test never sees a partial binary.
    ld $LDFLAGS -o "$out/lamp-cli.tmp" $objs
    mv -f "$out/lamp-cli.tmp" "$out/lamp-cli"
fi
echo "$out/lamp-cli"
