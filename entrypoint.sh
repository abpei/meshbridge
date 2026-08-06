#!/usr/bin/env bash
# entrypoint.sh — Container entrypoint for MeshBridge.
# Ensures mesh.ini exists (from mounted volume or example), then execs the app.
set -euo pipefail

CONFIG="/app/mesh.ini"

if [ ! -f "$CONFIG" ]; then
    echo "[entrypoint] WARNING: $CONFIG not found — copying default config."
    cp /app/mesh.ini.example "$CONFIG"
fi

exec python mesh.py "$@"
