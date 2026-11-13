#!/bin/sh
# Builds the analysis and image tools into build/tools/ (see CLAUDE.md → "Reverse-engineering tools").
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tools

# libLTO carries LLVM's C disassembler: Xcode has it in its toolchain, the command-line tools in usr/lib.
DEV="$(xcode-select -p)"
LTO="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/libLTO.dylib"
[ -f "$LTO" ] || LTO="$DEV/usr/lib/libLTO.dylib"

CFLAGS="-O1 -Wall -lobjc"
clang $CFLAGS tools/imgdump.c -o build/tools/imgdump
clang $CFLAGS tools/ivars.c -o build/tools/ivars
clang $CFLAGS -DDEFAULT_LIBLTO="\"$LTO\"" tools/objcdis.c -o build/tools/objcdis
swiftc -O tools/montage.swift -o build/tools/montage
swiftc -O tools/rowsample.swift -o build/tools/rowsample
swiftc -O tools/crop.swift -o build/tools/crop
swiftc -O tools/make-icon.swift -o build/tools/make-icon
echo "built build/tools/{imgdump,ivars,objcdis,montage,rowsample,crop,make-icon}"
