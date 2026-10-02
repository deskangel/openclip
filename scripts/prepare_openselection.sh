#!/bin/bash
# Bootstrap the separate OpenSelection checkout from a published commit plus the
# checked-in integration patch. Existing local checkouts remain developer overrides.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DEST="${1:-$TASK_ROOT/openselection}"
TASK_REV="8113154e06f27f0447f5dd8ebbd2d3dd794330a6"
if [ -f "$TASK_DEST/Package.swift" ]; then
    exit 0
fi
if [ -e "$TASK_DEST" ]; then
    printf 'OpenSelection destination exists but has no Package.swift: %s\n' "$TASK_DEST" >&2
    exit 1
fi
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/openclip-openselection.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
git clone --quiet --no-checkout https://github.com/ganeshmshetty/OpenSelection.git "$TASK_TEMP/package"
git -C "$TASK_TEMP/package" checkout --quiet --detach "$TASK_REV"
git -C "$TASK_TEMP/package" apply --check "$TASK_ROOT/scripts/dependencies/OpenSelection.patch"
git -C "$TASK_TEMP/package" apply "$TASK_ROOT/scripts/dependencies/OpenSelection.patch"
mkdir -p "$(dirname "$TASK_DEST")"
mv "$TASK_TEMP/package" "$TASK_DEST"
