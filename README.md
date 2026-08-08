# MeshBridge

Dockerized Meshtastic-to-Telegram message bridge. Wraps [tb0hdan/meshtastic-telegram-gateway](https://github.com/tb0hdan/meshtastic-telegram-gateway) in a container with direct TCP connection to a Meshtastic node.

## Architecture

```
Heltec V4 (WiFi, port 4403)
    ↕ TCP (Meshtastic protobuf, outbound from container)
MeshBridge (Docker container, bridge networking)
    ↕ Telegram Bot API (HTTPS, outbound from container)
Telegram Group
```

The container uses default Docker bridge networking. Outbound TCP to the node and HTTPS to Telegram work through Docker's NAT. No host network mode required.

## Prerequisites

- Docker Engine 24+ with docker-compose v2
- A Meshtastic node reachable over TCP (port 4403 default)
- WiFi enabled on the node with correct SSID/PSK
- A Telegram bot token from @BotFather
- Bot added to a Telegram group with **privacy mode disabled** (Bot Settings → Group Privacy → Turn off)

## Quick Start

1. Clone the repo and fetch upstream:
   ```bash
   git clone https://github.com/abpei/meshbridge.git
   cd meshbridge
   bash fetch-upstream.sh
   ```

2. Copy `.env.example` to `.env` and fill in your values:
   ```bash
   cp .env.example .env
   ```

3. Build and run:
   ```bash
   docker compose up -d --build
   ```

4. Check logs:
   ```bash
   docker compose logs -f
   ```

5. Verify the bot is working by sending a message in the Telegram group.

## Configuration

All configuration is via environment variables in `.env`. The entrypoint renders `mesh.ini` from these at container start.

### Required

| Variable | Example | Description |
|----------|---------|-------------|
| `MESHB_TELEGRAM_TOKEN` | `123456:ABC-DEF` | Bot token from @BotFather |
| `MESHB_TELEGRAM_ROOM` | `-1001234567890` | Telegram group ID (negative integer) |
| `MESHB_TELEGRAM_ADMIN` | `12345678` | Admin user ID (positive integer) |
| `MESHB_MESHTASTIC_DEVICE` | `tcp:192.168.1.100` | Node IP with `tcp:` prefix |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `MESHB_DEBUG` | `false` | Enable debug logging |
| `MESHB_WEBAPP_ENABLED` | `true` | Enable Flask web map interface |
| `MESHB_MQTT_ENABLED` | `false` | Enable MQTT bridging |
| `MESHB_MESHTASTIC_MAX_HOP_COUNT` | `5` | Max hop limit for TX |

## Meshtastic Node Setup

Your node must have:
- WiFi enabled with correct SSID/PSK
- TCP API accessible on port 4403 (default when WiFi is enabled)
- Node must be on the same LAN as the Docker host

Verify connectivity:
```bash
nc -zv <node-ip> 4403
```

## Telegram Bot Setup

1. Message @BotFather → `/newbot` → copy token
2. Add bot to your Telegram group
3. **Disable privacy mode:** @BotFather → `/mybots` → Bot Settings → Group Privacy → Turn off
4. Get group ID: forward a message from the group to @userinfobot
5. Get your user ID: message @userinfobot

## Web Interface

The upstream project includes a Flask web map interface showing node locations. Access at `http://<docker-host-ip>:5000/`.

Disable with `MESHB_WEBAPP_ENABLED=false` in `.env`.

## Known Limitations

- Telegram sender username is prepended to messages sent to the mesh (upstream behavior). A fork would be needed to strip it.
- The web interface may show errors for missing Google Maps API key (non-functional map markers).
- Privacy mode must be disabled on the Telegram bot for it to see group messages.

## Updating Upstream

```bash
bash fetch-upstream.sh
docker compose up -d --build
```

## License

Apache 2.0
