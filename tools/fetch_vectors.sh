#!/bin/sh
# Fetch the hardware-captured 386 real-mode instruction vectors
# (docs/verification.md, layer 1) into output/vectors/80386.
#
# About 580 MB. The data is in the public domain and the suite's
# software is MIT (see its LICENSE). It is fetched, never committed.
set -e
DEST="${1:-output/vectors/80386}"
REPO=https://github.com/SingleStepTests/80386

if [ -d "$DEST/.git" ]; then
    echo "already fetched: $DEST"
    exit 0
fi
mkdir -p "$(dirname "$DEST")"
git clone --depth 1 "$REPO" "$DEST"
ls "$DEST/v1_ex_real_mode" | wc -l
