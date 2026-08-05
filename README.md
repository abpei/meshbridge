# MeshBridge

Dockerized Meshtastic-to-Telegram message bridge. Wraps [tb0hdan/meshtastic-telegram-gateway](https://github.com/tb0hdan/meshtastic-telegram-gateway) in a container with TCP direct connection to a Meshtastic node.

## Architecture

```
Heltec V4 (WiFi, port 4403)
    ↕ TCP (Meshtastic protobuf)
MeshBridge (Docker container)
    ↕ Telegram Bot API
Telegram Group
```

## Quick Start

1. Copy `.env.example` to `.env` and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Edit `mesh.ini` with your node IP, Telegram token, and group ID.

3. Build and run:
   ```bash
   docker compose up -d
   ```

4. Check logs:
   ```bash
   docker compose logs -f
   ```

## Configuration

| File | Purpose |
|------|---------|
| `.env` | Secrets (Telegram token, node IP) |
| `mesh.ini` | Application config (bridge settings, features) |
| `docker-compose.yml` | Container orchestration |

## Meshtastic Node Setup

Your Heltec V4 must have:
- WiFi enabled
- MQTT uplink/downlink on the open channel
- TCP interface accessible on port 4403

## License

Apache 2.0
