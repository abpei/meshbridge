#!/usr/bin/env bash
# entrypoint.sh — Container entrypoint for MeshBridge.
# Reads MESHB_* environment variables, merges with existing mesh.ini, then execs the app.
set -euo pipefail

CONFIG="${MESHB_CONFIG_PATH:-/app/upstream/mesh.ini}"

# ── Ensure data directory exists ──────────────────────────────────────
# The database file needs a writable directory. The Dockerfile creates
# /app/data, but if the path is overridden via MESHB_MESHTASTIC_DATABASE_FILE
# we must create its parent directory too.
DB_FILE="${MESHB_MESHTASTIC_DATABASE_FILE:-/app/data/meshtastic.sqlite}"
DB_DIR="$(dirname "$DB_FILE")"
if [ ! -d "$DB_DIR" ]; then
    echo "[entrypoint] Creating database directory: $DB_DIR"
    mkdir -p "$DB_DIR" || {
        echo "[entrypoint] WARNING: Could not create $DB_DIR, falling back to /app/data"
        DB_DIR="/app/data"
        mkdir -p "$DB_DIR"
        export MESHB_MESHTASTIC_DATABASE_FILE="$DB_DIR/meshtastic.sqlite"
    }
fi

# ── Mock device support ─────────────────────────────────────────────
# When MESHB_MOCK_DEVICE=1, start a mock Meshtastic TCP server in the
# background so the bridge can start without a real device (useful for
# smoke tests and CI). The mock always listens on port 4403 (the
# default Meshtastic TCP port).
if [ "${MESHB_MOCK_DEVICE:-0}" = "1" ]; then
    echo "[entrypoint] Starting mock Meshtastic server on port 4403"
    python3 /app/upstream/mock-meshtastic.py --port 4403 &
    MOCK_PID=$!
    # Wait briefly for the mock server to be ready
    sleep 1
    # Point the device at the local mock (always override for mock mode)
    # Note: Meshtastic TCPInterface uses DEFAULT_TCP_PORT (4403) automatically,
    # so the device path is just tcp:HOST without a port.
    export MESHB_MESHTASTIC_DEVICE="tcp:127.0.0.1"
    echo "[entrypoint] Set MESHB_MESHTASTIC_DEVICE=${MESHB_MESHTASTIC_DEVICE}"
fi

# Render mesh.ini: merge existing config with MESHB_* environment variables.
# Mapping convention: MESHB_<SECTION>_<KEY>  →  [Section] Key = value
# Single-word keys (DEFAULT section): MESHB_DEBUG → [DEFAULT] Debug = ...
python3 - <<'PYEOF'
import configparser
import os
from collections import OrderedDict


def get_env(name, default=None):
    """Return env var value or default (None = omit key)."""
    val = os.environ.get(name)
    if val is None:
        return default
    return val


def write_ini(path):
    # Read existing config if present, otherwise start fresh
    existing = configparser.RawConfigParser()
    if os.path.exists(path):
        existing.read(path)

    # Build output using OrderedDict to preserve key order
    # All keys stored lowercase; output uses the display name from env mapping
    sections = OrderedDict()

    # ── [DEFAULT] ────────────────────────────────────────────────────────
    # Always write [DEFAULT] with at least Debug=false so configparser
    # has a valid section header (bare keys cause MissingSectionHeaderError).
    d = OrderedDict()
    # Start with existing values (lowercase keys)
    if "DEFAULT" in existing:
        for key, val in existing["DEFAULT"].items():
            d[key] = val
    # Always set these defaults (can be overridden by env vars below)
    d.setdefault("debug", "false")
    d.setdefault("sentryenabled", "false")
    # Override with environment variables (env vars always win)
    env_defaults = {
        "MESHB_DEBUG": "debug",
        "MESHB_SENTRY_DSN": "sentrydsn",
        "MESHB_SENTRY_ENABLED": "sentryenabled",
        "MESHB_OPENWEATHER_KEY": "openweatherkey",
    }
    for env_name, key in env_defaults.items():
        v = get_env(env_name)
        if v is not None:
            d[key] = v
    sections["DEFAULT"] = d

    # ── Section definitions ──────────────────────────────────────────────
    section_defs = {
        "Telegram": {
            "MESHB_TELEGRAM_ADMIN": "Admin",
            "MESHB_TELEGRAM_ROOM": "Room",
            "MESHB_TELEGRAM_ROOM_LINK": "RoomLink",
            "MESHB_TELEGRAM_NOTIFICATIONS_ENABLED": "NotificationsEnabled",
            "MESHB_TELEGRAM_NOTIFICATIONS_ROOM": "NotificationsRoom",
            "MESHB_TELEGRAM_TOKEN": "Token",
            "MESHB_TELEGRAM_MAP_LINK_ENABLED": "MapLinkEnabled",
            "MESHB_TELEGRAM_MAP_LINK": "MapLink",
            "MESHB_TELEGRAM_NODE_INCLUDE_SELF": "NodeIncludeSelf",
            "MESHB_TELEGRAM_BOT_IN_ROOMS": "BotInRooms",
        },
        "WebApp": {
            "MESHB_WEBAPP_PORT": "Port",
            "MESHB_WEBAPP_REDRAW_MARKERS_EVERY": "RedrawMarkersEvery",
            "MESHB_WEBAPP_API_KEY": "APIKey",
            "MESHB_WEBAPP_ENABLED": "Enabled",
            "MESHB_WEBAPP_CENTER_LATITUDE": "Center_Latitude",
            "MESHB_WEBAPP_CENTER_LONGITUDE": "Center_Longitude",
            "MESHB_WEBAPP_LAST_HEARD_DEFAULT": "LastHeardDefault",
            "MESHB_WEBAPP_AIR_RAID_ENABLED": "AirRaidEnabled",
            "MESHB_WEBAPP_AIR_RAID_PRIVATE": "AirRaidPrivate",
            "MESHB_WEBAPP_EXTERNAL_URL": "ExternalURL",
            "MESHB_WEBAPP_SHORTENER_SERVICE": "ShortenerService",
            "MESHB_WEBAPP_TLY_TOKEN": "TLYToken",
            "MESHB_WEBAPP_PLSST": "PLSST",
        },
        "Meshtastic": {
            "MESHB_MESHTASTIC_ADMIN": "Admin",
            "MESHB_MESHTASTIC_DEVICE": "Device",
            "MESHB_MESHTASTIC_DATABASE_FILE": "DatabaseFile",
            "MESHB_MESHTASTIC_FIFO_PATH": "FIFOPath",
            "MESHB_MESHTASTIC_FIFO_CMD_PATH": "FIFOCmdPath",
            "MESHB_MESHTASTIC_NODE_LOG_ENABLED": "NodeLogEnabled",
            "MESHB_MESHTASTIC_NODE_LOG_FILE": "NodeLogFile",
            "MESHB_MESHTASTIC_FIFO_ENABLED": "FIFOEnabled",
            "MESHB_MESHTASTIC_WELCOME_MESSAGE": "WelcomeMessage",
            "MESHB_MESHTASTIC_WELCOME_MESSAGE_ENABLED": "WelcomeMessageEnabled",
            "MESHB_MESHTASTIC_MAX_HOP_COUNT": "MaxHopCount",
        },
        "APRS": {
            "MESHB_APRS_ENABLED": "Enabled",
            "MESHB_APRS_TO_MESHTASTIC": "ToMeshtastic",
            "MESHB_APRS_FROM_MESHTASTIC": "FromMeshtastic",
            "MESHB_APRS_CALL_SIGN": "CallSign",
            "MESHB_APRS_PASSWORD": "Password",
        },
        "MQTT": {
            "MESHB_MQTT_ENABLED": "Enabled",
            "MESHB_MQTT_TOPIC": "Topic",
            "MESHB_MQTT_CHANNEL": "Channel",
            "MESHB_MQTT_HOST": "Host",
            "MESHB_MQTT_PORT": "Port",
            "MESHB_MQTT_USER": "User",
            "MESHB_MQTT_PASSWORD": "Password",
        },
    }

    for section_name, env_map in section_defs.items():
        s = OrderedDict()
        # Start with existing values (lowercase keys)
        if section_name in existing:
            for key, val in existing[section_name].items():
                s[key] = val
        # Override with environment variables (env vars always win)
        for env_name, display_name in env_map.items():
            v = get_env(env_name)
            if v is not None:
                s[display_name.lower()] = v
        if s:
            sections[section_name] = s

    # ── Write INI ────────────────────────────────────────────────────────
    # Use display names for output (preserving original casing)
    display_names = {
        "DEFAULT": {
            "debug": "Debug", "sentrydsn": "SentryDSN", "sentryenabled": "SentryEnabled",
            "openweatherkey": "OpenWeatherKey",
        },
    }
    for section_name, env_map in section_defs.items():
        display_names[section_name] = {v.lower(): v for v in env_map.values()}

    lines = ["# Generated by entrypoint.sh from MESHB_* environment variables",
             "# Do not edit manually — changes will be overwritten on restart.", ""]
    for section_name, items in sections.items():
        lines.append(f"[{section_name}]")
        section_display = display_names.get(section_name, {})
        for key, val in items.items():
            display_key = section_display.get(key, key)
            lines.append(f"{display_key} = {val}")
        lines.append("")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    n_keys = sum(len(v) for v in sections.values())
    n_sections = len(sections)
    print(f"[entrypoint] Rendered {path} ({n_sections} sections, {n_keys} keys)")


write_ini(os.environ.get("MESHB_CONFIG_PATH", "/app/upstream/mesh.ini"))
PYEOF

# Validate critical config values before starting
python3 - <<'VALIDATE'
import configparser
import os
import sys

config_path = os.environ.get("MESHB_CONFIG_PATH", "/app/upstream/mesh.ini")
config = configparser.ConfigParser()
config.read(config_path)

errors = []

# Check Telegram token
try:
    token = config["Telegram"]["Token"]
    if not token or token == "AA:BB:CC":
        errors.append("Telegram Token is not configured (still default)")
except KeyError:
    errors.append("Telegram section or Token is missing")

# Check Meshtastic device
try:
    device = config["Meshtastic"]["Device"]
    if not device:
        errors.append("Meshtastic Device is not configured")
except KeyError:
    errors.append("Meshtastic section or Device is missing")

# Check database file path is accessible
try:
    db_file = config["Meshtastic"]["DatabaseFile"]
    db_dir = os.path.dirname(db_file) if os.path.dirname(db_file) else "."
    if not os.path.isdir(db_dir):
        os.makedirs(db_dir, exist_ok=True)
        print(f"[entrypoint] Created database directory: {db_dir}")
except KeyError:
    errors.append("Meshtastic DatabaseFile is missing")

if errors:
    print("[entrypoint] Configuration warnings:")
    for err in errors:
        print(f"  - {err}")
    print("[entrypoint] Continuing with warnings (some features may not work)")
else:
    print("[entrypoint] Configuration validated OK")
VALIDATE

# WORKDIR is already /app/upstream in the Dockerfile
exec python3 mesh.py "$@"
