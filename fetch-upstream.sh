#!/usr/bin/env bash
# fetch-upstream.sh — Clone or update the upstream meshtastic-telegram-gateway repo.
# Usage: ./fetch-upstream.sh [TARGET_DIR]
#   TARGET_DIR: directory to clone into (default: ./upstream)

set -euo pipefail

UPSTREAM_URL="https://github.com/tb0hdan/meshtastic-telegram-gateway.git"
TARGET_DIR="${1:-./upstream}"

if [ -d "$TARGET_DIR/.git" ]; then
    echo "Upstream repo already exists at $TARGET_DIR — pulling latest (ff-only)..."
    if ! git -C "$TARGET_DIR" pull --ff-only; then
        echo "Error: git pull failed in $TARGET_DIR" >&2
        exit 1
    fi
    echo "Upstream updated successfully."
else
    echo "Cloning upstream repo into $TARGET_DIR (shallow, depth=1)..."
    if ! git clone --depth 1 "$UPSTREAM_URL" "$TARGET_DIR"; then
        echo "Error: git clone failed for $UPSTREAM_URL" >&2
        exit 1
    fi
    echo "Upstream cloned successfully."
fi
