#!/bin/sh
set -eu
PATCH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH_DIR="$PATCH_ROOT/Contents/mods/RemoveLimits/common/OptionalSavePatch"
PATCH_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/removelimits-build.XXXXXX")
trap 'rm -f "$PATCH_BUILD/SaveBufferPatch.class"; rmdir "$PATCH_BUILD"' EXIT HUP INT TERM
javac --release 11 -encoding UTF-8 -d "$PATCH_BUILD" "$PATCH_DIR/SaveBufferPatch.java"
jar --create --file "$PATCH_DIR/SaveBufferPatch.jar" --main-class SaveBufferPatch --date=2026-01-01T00:00:00Z -C "$PATCH_BUILD" .
