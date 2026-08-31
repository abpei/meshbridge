# MeshBridge

Dockerized Meshtastic-to-Telegram message bridge. Wraps [tb0hdan/meshtastic-telegram-gateway](https://github.com/tb0hdan/meshtastic-telegram-gateway) in a container with direct TCP connection to a Meshtastic node.

## Quick Start (GHCR)

```bash
# Login to GitHub Container Registry
echo $GITHUB_TOKEN | docker login ghcr.io -u <your-username> --password-stdin

# Create .env with minimum config (see below)
cp .env.example .env
# Edit .env with your values

# Run
docker compose up -d
```

## Architecture

```
Heltec V4 (WiFi, port 4403)
    ↕ TCP (Meshtastic protobuf, outbound from container)
MeshBridge (Docker container, bridge networking)
    ↕ Telegram Bot API (HTTPS, outbound from container)
Telegram Group
```

## Minimum Configuration

Only 4 variables are strictly required to start. Everything else has defaults.

| Variable | Example | Description |
|----------|---------|-------------|
| `MESHB_TELEGRAM_TOKEN` | `123456:ABC-DEF` | Bot token from @BotFather |
| `MESHB_TELEGRAM_ROOM` | `-1001234567890` | Telegram group ID (negative integer) |
| `MESHB_TELEGRAM_ADMIN` | `12345678` | Your Telegram user ID (positive integer) |
| `MESHB_MESHTASTIC_DEVICE` | `tcp:192.168.1.100` | Node IP with `tcp:` prefix |

### Numeric fields must have values (never empty)

The upstream reads all config sections unconditionally. Even with features disabled, numeric fields like `MESHB_MQTT_PORT` and `MESHB_TELEGRAM_NOTIFICATIONS_ROOM` must contain valid values. Empty strings cause `ValueError: invalid literal for int()`.

Set these even if unused:
```
MESHB_MQTT_PORT=1883
MESHB_TELEGRAM_NOTIFICATIONS_ROOM=-1001234567890
```

## All Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| **Telegram** | | |
| `MESHB_TELEGRAM_TOKEN` | *(required)* | Bot token from @BotFather |
| `MESHB_TELEGRAM_ROOM` | *(required)* | Gateway group ID (negative integer) |
| `MESHB_TELEGRAM_ADMIN` | *(required)* | Admin user ID (positive integer) |
| `MESHB_TELEGRAM_BOT_IN_ROOMS` | `true` | Bot responds in group rooms |
| `MESHB_TELEGRAM_NOTIFICATIONS_ENABLED` | `false` | Notify on new mesh nodes |
| `MESHB_TELEGRAM_NOTIFICATIONS_ROOM` | *(required if notifications enabled)* | Notification group ID |
| **Meshtastic** | | |
| `MESHB_MESHTASTIC_DEVICE` | *(required)* | `tcp:<ip>` or `/dev/ttyACM0` |
| `MESHB_MESHTASTIC_ADMIN` | `!deadbeef` | Admin node ID (hex with !) |
| `MESHB_MESHTASTIC_DATABASE_FILE` | `/app/data/meshtastic.sqlite` | SQLite path (use absolute) |
| `MESHB_MESHTASTIC_MAX_HOP_COUNT` | `5` | Max hop limit |
| `MESHB_MESHTASTIC_FIFO_ENABLED` | `false` | FIFO message routing |
| `MESHB_MESHTASTIC_WELCOME_MESSAGE_ENABLED` | `false` | Welcome new nodes |
| `MESHB_MESHTASTIC_WELCOME_MESSAGE` | `Welcome to our community` | Welcome text |
| **Runtime** | | |
| `TZ` | `UTC` | Container timezone |
| `MESHB_DEBUG` | `false` | Debug logging |
| **WebApp** | | |
| `MESHB_WEBAPP_ENABLED` | `true` | Flask web map interface |
| `MESHB_WEBAPP_PORT` | `5000` | Web UI port |
| `MESHB_WEBAPP_CENTER_LATITUDE` | `46.2382` | Map center lat |
| `MESHB_WEBAPP_CENTER_LONGITUDE` | `-63.1311` | Map center lon |
| `MESHB_WEBAPP_LAST_HEARD_DEFAULT` | `3600` | Node visibility (seconds) |
| `MESHB_WEBAPP_EXTERNAL_URL` | `http://localhost:5000` | Public URL for map |
| **MQTT** | | |
| `MESHB_MQTT_ENABLED` | `false` | Enable MQTT bridging |
| `MESHB_MQTT_PORT` | `1883` | MQTT port (must be numeric) |
| `MESHB_MQTT_HOST` | `mqtt.eclipseprojects.io` | MQTT broker |
| `MESHB_MQTT_TOPIC` | `msh` | MQTT topic root |
| `MESHB_MQTT_CHANNEL` | `LongFast` | Meshtastic channel |
| **APRS** | | |
| `MESHB_APRS_ENABLED` | `false` | Enable APRS-IS |
| **Sentry** | | |
| `MESHB_SENTRY_ENABLED` | `false` | Error tracking |

## Prerequisites

- Docker Engine 24+ with docker-compose v2
- A Meshtastic node with WiFi enabled and TCP API on port 4403
- A Telegram bot token from @BotFather
- Bot added to a Telegram group with **privacy mode disabled**

## Meshtastic Node Setup

Your node must have:
- WiFi enabled with correct SSID/PSK
- TCP API accessible on port 4403 (default when WiFi is enabled)
- Node on the same LAN as the Docker host

Verify:
```bash
nc -zv <node-ip> 4403
```

## Telegram Bot Setup

1. Message @BotFather → `/newbot` → copy token
2. Add bot to your Telegram group
3. **Disable privacy mode:** @BotFather → `/mybots` → Bot Settings → Group Privacy → Turn off
4. Get group ID: forward a message from the group to @userinfobot
5. Get your user ID: message @userinfobot

## Features

- Bidirectional message relay between Telegram group and Meshtastic mesh
- Packet metadata on received messages: `[4/5 hops, SNR: 6.0 dB, RSSI: -72 dBm]`
- New node discovery notifications
- SQLite message logging
- Flask web map interface (optional)

## Building from Source

```bash
git clone https://github.com/abpei/meshbridge.git
cd meshbridge
bash fetch-upstream.sh
docker compose up -d --build
```

## Updating

```bash
bash fetch-upstream.sh
docker compose up -d --build
```

## License

Apache 2.0 — see [LICENSE](LICENSE).

Forked from [tb0hdan/meshtastic-telegram-gateway](https://github.com/tb0hdan/meshtastic-telegram-gateway) with modifications. See [abpei/meshtastic-telegram-gateway](https://github.com/abpei/meshtastic-telegram-gateway) for the patched upstream.
