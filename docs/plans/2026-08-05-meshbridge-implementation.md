# MeshBridge Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task. Route each task to the `implementor` profile via kanban; the planner (this session) does not write code.

**Goal:** Produce a Dockerized Meshtastic↔Telegram bridge that wraps `tb0hdan/meshtastic-telegram-gateway` (upstream), connecting to a Meshtastic node over TCP and relaying messages bidirectionally to a Telegram group, with SQLite logging, healthchecks, CI, and docs.

**Architecture:** MeshBridge is a *thin wrapper* around upstream — it does **not** fork or reimplement the gateway. It vendors the upstream source at build time, layers a Dockerfile + docker-compose + config templates + an entrypoint shim on top, and configures upstream's existing features (TCP device, SQLite via Pony ORM, bidirectional relay, sender nicks) for containerized single-node deployment. New wrapper-level code is kept minimal: an entrypoint script, a healthcheck helper, and (only if verification shows gaps) a small chunking shim.

**Tech Stack:**
- Python 3.12-slim (upstream supports 3.10–3.14; 3.14 has open issues, 3.12 is the safest well-tested target for the `meshtastic` PyPI client)
- Docker / docker-compose (v2)
- SQLite via Pony ORM (`pony~=0.7.19`, already in upstream `requirements.txt`)
- Telegram Bot API via `python-telegram-bot==22.5` (upstream dep)
- Meshtastic Python client (`meshtastic`, upstream dep) in TCP mode

**Upstream facts (verified at planning time, 2026-08-05):**
- Entry point: `mesh.py run -c ./mesh.ini -b <basedir>` (defaults: `./mesh.ini` and cwd)
- TCP device: set `[Meshtastic].Device = tcp:<host-or-ip>` (e.g. `tcp:192.168.1.100`)
- DB path resolved as `os.path.join(args.basedir, config.Meshtastic.DatabaseFile)`
- Existing Pony ORM schema (`mtg/database/sqlite.py`): `FirmwareReleaseRecord`, `MeshtasticNodeRecord(nodeId PK, nodeName, lastHeard, hwModel)`, `MeshtasticLocationRecord`, `MeshtasticMessageRecord(datetime, message, node FK)`, `FilterRecord(connection, item, reason, active)`
- `make run` loops `while :; do ./mesh.py; sleep 3; done` — restarts on crash. In Docker we run `mesh.py` directly and rely on `restart: unless-stopped`.
- `main()` already calls `telegram_bot.shutdown()` and `thread_manager.shutdown_all()` on exit.
- Upstream CI: matrix 3.10–3.14, `pytest --cov mtg`, `make lint` (pylint + mypy).

**Repository layout (target):**
```
meshbridge/
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── mesh.ini                    # application config template (committed, .gitignored after user edits)
├── mesh.ini.example            # reference template (committed, never edited at runtime)
├── entrypoint.sh               # wrapper: generates mesh.ini from env, execs mesh.py
├── healthcheck.py              # liveness probe (process + DB writability)
├── requirements.txt            # pinned, mirrors upstream + wrapper healthcheck deps
├── upstream.version            # pinned upstream git ref / tag
├── scripts/
│   ├── fetch-upstream.sh       # clones/updates vendored upstream into upstream/
│   └── smoke-test.sh           # local smoke test harness
├── upstream/                   # vendored tb0hdan/meshtastic-telegram-gateway (gitignored, populated at build)
├── data/                       # persisted SQLite volume (gitignored)
├── docs/
│   └── plans/
│       └── 2026-08-05-meshbridge-implementation.md   # this file
├── .github/
│   └── workflows/
│       └── ci.yml
├── README.md
├── AGENTS.md
├── LICENSE
└── .gitignore
```

---

## Phase 1 — Foundation: Clone, Containerize, Smoke Test

**Phase 1 deliverables:** vendored upstream, working Dockerfile, docker-compose.yml, `.env.example`, `mesh.ini`/`mesh.ini.example` templates, `entrypoint.sh`, and a smoke test proving the container starts and the binary launches.

### Dependencies & risks
- **Docker** installed locally for building/testing.
- **Upstream ref** must be pinned (tag or commit SHA) so builds are reproducible. Risk: upstream `master` moves; pin to a release tag if one exists, else a known-good SHA.
- **Python 3.14 risk**: current scaffolding Dockerfile uses `python:3.14-slim`; upstream has open issues on 3.13/3.14. **Pin to `python:3.12-slim`** until upstream stabilizes.
- **Bridge networking** (default Docker) is sufficient. The container only makes outbound connections: TCP to the node (port 4403) and HTTPS to api.telegram.org. Both work through Docker's NAT bridge. No `network_mode: host` needed. The node must be reachable from the Docker host's LAN (e.g. `192.168.x.x`).
- **Build context**: vendoring upstream means the Dockerfile either clones at build time (needs git in the image, network at build) or copies a pre-fetched `upstream/` dir. Prefer pre-fetch via `scripts/fetch-upstream.sh` + `COPY upstream/` so builds are hermetic and CI can restrict network.

### File-by-file specification

#### `Dockerfile` (contents sketch — not final code)
```
FROM python:3.12-slim

# Runtime deps for meshtastic/reverse-geocoder/native bits
RUN apt-get update && apt-get install -y --no-install-recommends \
        libopenblas0 libopenblas-dev gcc git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy vendored upstream (pre-fetched by scripts/fetch-upstream.sh)
COPY upstream/ /app/

# Copy wrapper files
COPY requirements.txt entrypoint.sh healthcheck.py mesh.ini.example /app/
RUN pip install --no-cache-dir -r requirements.txt \
    && chmod +x /app/entrypoint.sh

# Persistent data dir (mounted as volume)
RUN mkdir -p /app/data
VOLUME ["/app/data"]

# Healthcheck: wrapper script checks mesh.py process + SQLite DB writability
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python /app/healthcheck.py || exit 1

# Entrypoint renders mesh.ini from env vars then execs mesh.py run
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
```
Notes: do NOT use upstream `start.sh` (it spawns detached `screen` sessions — wrong for Docker). Do NOT use the `make run` restart loop inside the container; let Docker's `restart: unless-stopped` handle restarts so healthchecks and `stop` signals work cleanly.

#### `docker-compose.yml` (structure sketch)
```yaml
services:
  meshbridge:
    build: .
    image: meshbridge:latest
    container_name: meshbridge
    restart: unless-stopped
    # Bridge mode: container reaches node via outbound NAT, no host network needed.
    # Only expose webapp port if [WebApp].Enabled = true in mesh.ini.
    # ports:
    #   - "5000:5000"
    env_file:
      - .env
    volumes:
      - ./mesh.ini:/app/mesh.ini:ro     # rendered by entrypoint.sh from env OR committed
      - ./data:/app/data                # SQLite persistence
    environment:
      - TZ=${TZ:-UTC}
    stop_grace_period: 30s              # give ThreadManager.shutdown_all() time
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```
Notes: `stop_grace_period: 30s` matters because upstream's `telegram_bot.shutdown()` + `thread_manager.shutdown_all()` may take time. The `logging` block implements log rotation (Phase 3 requirement) and can be introduced here to avoid a later edit.

Two config strategies — pick ONE and document it in README (recommended: **env-driven**, since AGENTS.md/`.env.example` already imply it):
- **Env-driven (recommended):** `entrypoint.sh` reads `.env` vars and writes `/app/mesh.ini` at container start from `mesh.ini.example` via envsubst-like substitution. The volume mount of `mesh.ini` then becomes optional. Keeps secrets out of the git-tracked mesh.ini.
- **File-driven:** user edits `mesh.ini` directly; mount it read-only. Simpler but commits secrets-threatening config if not careful.

#### `.env.example` (keys — extends current scaffolding)
```
# --- Telegram ---
TELEGRAM_TOKEN=AA:BB:CC               # from @BotFather
TELEGRAM_GROUP_ID=-1001234567890      # gateway room (negative int)
TELEGRAM_ADMIN_ID=12345678             # admin user (positive int)
TELEGRAM_ROOM_LINK=https://t.me/yourgroup   # optional, for /map etc.

# --- Meshtastic node ---
MESHTASTIC_HOST=192.168.1.100         # node IP on LAN
MESHTASTIC_ADMIN=!deadbeef             # admin node id (hex with !)
MESHTASTIC_MAX_HOP=5                   # hop limit forTX
MESHTASTIC_WELCOME=false               # WelcomeMessageEnabled
MESHTASTIC_FIFO=false                  # FIFOEnabled

# --- Runtime ---
TZ=UTC
MESHBRIDGE_DEBUG=false                 # sets [DEFAULT].Debug
```
Note: current `.env.example` is a subset; augment with WELCOME/FIFO/DEBUG/TZ. Keep keys in uppercase; `entrypoint.sh` maps them to `mesh.ini` sections.

#### `mesh.ini.example` (template keys — mirrors upstream, stripped to bridge-relevant subset)
```ini
[DEFAULT]
Debug = false

[Telegram]
Admin = 12345678
Room = -1001234567890
RoomLink = https://t.me/yourgroup
NotificationsEnabled = false
Token = AA:BB:CC
MapLinkEnabled = false
BotInRooms = true

[WebApp]
Port = 5000
Enabled = false            # leave off unless map is desired (heavier deps)

[Meshtastic]
Admin = !deadbeef
Device = tcp:192.168.1.100   # << TCP mode
DatabaseFile = data/meshtastic.sqlite
FIFOEnabled = false
WelcomeMessageEnabled = false
MaxHopCount = 5

[APRS]
Enabled = false

[MQTT]
Enabled = false
Topic = msh
Channel = LongFast
Host = mqtt.eclipseprojects.io
Port = 1883
User =
Password =
```
Decision rationale: disable WebApp/APRS/MQTT by default for the minimal bridge; they are upstream features MeshBridge doesn't need. Document how to enable in README. The current `mesh.ini` already mirrors this — rename the committed reference to `mesh.ini.example` and gitignore the runtime `mesh.ini`.

#### `entrypoint.sh` (responsibilities, not final code)
1. If `/app/mesh.ini` is not mounted or is empty, render it from `/app/mesh.ini.example` by substituting `${TELEGRAM_TOKEN}`, `${TELEGRAM_GROUP_ID}`, `${TELEGRAM_ADMIN_ID}`, `${MESHTASTIC_HOST}` (`tcp:${MESHTASTIC_HOST}`), `${MESHTASTIC_ADMIN}`, `${MESHBRIDGE_DEBUG}`, etc.
2. `mkdir -p /app/data` (ensure volume target exists).
3. `exec python mesh.py run -c /app/mesh.ini -b /app` — `exec` so mesh.py becomes PID 1 and receives SIGTERM directly.

#### `upstream.version`
Single line: the pinned git ref, e.g. `v1.1.12` or a 40-char SHA. `scripts/fetch-upstream.sh` reads this.

#### `scripts/fetch-upstream.sh`
```sh
#!/usr/bin/env bash
set -euo pipefail
REF="$(cat upstream.version)"
rm -rf upstream
git clone --depth 1 --branch "$REF" https://github.com/tb0hdan/meshtastic-telegram-gateway.git upstream
# strip upstream .git to keep build context lean
rm -rf upstream/.git
```
Run locally before `docker build` (and in CI) so the `upstream/` dir is populated and the build is hermetic.

#### `requirements.txt`
Start from upstream's `requirements.txt` verbatim (pin to the pinned ref's version). The wrapper adds no runtime deps beyond stdlib (healthcheck uses `sqlite3`, `os`, `sys` — all stdlib). Drop dev-only pins (`pylint`, `pytest`, `pytest-cov`, `pytest-asyncio`, `mypy`) into a separate `requirements-dev.txt` if desired, but keep them for parity with upstream tests in CI.

### Smoke test steps (Phase 1 acceptance)
Run from repo root:
1. `bash scripts/fetch-upstream.sh` → assert `upstream/mesh.py` exists.
2. `cp .env.example .env` and fill dummy values (fake token, a non-routable node IP like `192.0.2.1`).
3. `docker compose build` → succeeds.
4. `docker compose run --rm meshbridge python mesh.py --help` → exits 0, prints `usage: mesh.py`. Proves the binary and deps are installed.
5. `docker compose up -d` → container starts.
6. `docker compose logs meshbridge` → expect a startup log line from `setup_logger('mesh', ...)` and a connection attempt to the node IP (it will fail/retry against `192.0.2.1` — that's fine: proves TCP mode is wired and the process is alive, not wedged).
7. `docker inspect --format='{{.State.Health.Status}}' meshbridge` → `starting` then `healthy` (container is running, DB file created at `/app/data/meshtastic.sqlite`).
8. `docker compose down` → container stops within `stop_grace_period`.

Phase 1 acceptance = steps 1–8 pass. Real node connectivity is verified in Phase 2 against the actual Heltec V4.

---

## Phase 2 — Core Features: Bidirectional Relay, Sender ID, Chunking, SQLite, Healthcheck

**Phase 2 deliverables:** verified bidirectional relay, sender ID displayed in both directions, long-message chunking, SQLite logging persisted and queryable, and a working healthcheck.

**Critical framing:** most of these features **already exist upstream**. Phase 2 is primarily *configure, verify, and patch only the gaps*. Do not reimplement Pony ORM, the relay bots, or nick pass-through.

### 2.1 Bidirectional relay — verify, don't rebuild
- Upstream classes: `mtg.bot.telegram.TelegramBot` (Telegram→Meshtastic) and `mtg.bot.meshtastic.MeshtasticBot` (Meshtastic→Telegram), wired in `mesh.py main()`.
- `MeshtasticBot.subscribe()` registers packet handlers; `TelegramBot.run()` is the blocking main loop.
- **Task:** with a real node + Telegram group, send a message from Telegram → confirm it appears on the Meshtastic node's channel; send from a Meshtastic node → confirm it appears in the Telegram group. Capture the exact upstream log lines as evidence.
- **Gap handling (only if a direction fails):** file an issue/patch in the *wrapper* (not upstream) via an `external/plugins/` shim using upstream's `ExternalBase` plugin hook (documented in upstream README). Do not monkey-patch core classes.

### 2.2 Sender ID exposure — verify and format
- Upstream README: "Nicks (Your Name field for Meshtastic) are passed through in both directions." So sender ID is already surfaced.
- **Task:** verify the exact format:
  - Meshtastic→Telegram: does the message arrive as `<longName>: <text>` or `<shortName>: <text>`? Inspect `mtg/bot/meshtastic.py`. If the format is unhelpful (e.g. raw hex node id `!deadbeef` with no name), add an `external/plugins/` shim (`sender_formatter.py`) that re-formats using `MeshtasticNodeRecord.nodeName` from the DB.
  - Telegram→Meshtastic: confirm the Telegram user's display name is prepended to the Meshtastic text. If not, patch via the same external-plugin hook.
- **Config key:** none new needed — upstream uses `[Telegram].Admin` / `[Meshtastic].Admin` for privilege, and `nodeName` from the node DB for display. Document the expected format in README.

### 2.3 Message chunking — verify, shim where needed
Two directions, two different limits:
- **Telegram → Meshtastic:** Telegram messages can be up to 4096 chars. Meshtastic text payloads are fragment-aligned by the `meshtastic` Python client (it auto-fragments long text across mesh packets). **Verify** by sending a 1000-char Telegram message and confirming it arrives as multiple Meshtastic packets reassembled on the receiving node. If the upstream doesn't split (sends one oversized packet that drops), add a wrapper helper that splits text at a safe boundary (e.g. 200 chars, splitting on whitespace) and calls `meshtastic_connection.send_text` per chunk. Pseudocode for the shim:
  ```
  def chunked_send(text, conn, max=200):
      for piece in split_on_whitespace(text, max):
          conn.send_text(piece)
  ```
  Wire it via an `external/plugins/` shim or a small monkey-patch in `entrypoint.sh`-imported module — prefer the plugin hook.
- **Meshtastic → Telegram:** multiple incoming Meshtastic packets may form one logical message or arrive as a burst. Confirm upstream's `TelegramBot` batches them into a single Telegram message ≤4096 chars, and that long bursts are truncated with an ellipsis rather than dropping silently.
- **No new config key** unless verification shows the 4096 / mesh-packet limits are mishandled; then add `[Meshtastic].MaxChunkLen` (default 200) to `mesh.ini.example` and read it in the shim.

### 2.4 SQLite logging — configure and verify persistence
- **Already implemented upstream** via Pony ORM (`mtg/database/sqlite.py`), tables enumerated in the "Upstream facts" section above. `MeshtasticDB.store_message()` writes `MeshtasticMessageRecord(datetime, message, node)`.
- **Task:** ensure the DB path resolves inside the mounted volume so it persists across container restarts.
  - Upstream resolves: `os.path.join(args.basedir, config.Meshtastic.DatabaseFile)`.
  - `entrypoint.sh` passes `-b /app`, and `mesh.ini` sets `DatabaseFile = data/meshtastic.sqlite` → file at `/app/data/meshtastic.sqlite`.
  - `docker-compose.yml` mounts `./data:/app/data` → persisted on host.
- **Verify:** after a relay, `sqlite3 ./data/meshtastic.sqlite "SELECT datetime, message FROM MeshtasticMessageRecord ORDER BY datetime DESC LIMIT 5;"` returns the relayed messages.
- **Schema is upstream's** — no new tables. If a MeshBridge-specific query surface is desired later, add a read-only view; do not modify the Pony schema.
- **Library choice:** Pony ORM (`pony~=0.7.19`) is already pinned in upstream `requirements.txt`; keep it. Do not introduce a second SQLite library.

### 2.5 Healthcheck — wrapper-level, two tiers
The upstream webapp (`[WebApp]`, Flask) is disabled by default for the minimal bridge. Two-tier healthcheck:

**Tier 1 (always on, default):** `healthcheck.py` (wrapper, stdlib-only):
```python
# pseudocode
import os, sys, sqlite3, psutil  # or fall back to /proc
# 1. mesh.py process alive
if not process_running("mesh.py"): sys.exit(1)
# 2. DB writable
try:
    conn = sqlite3.connect("/app/data/meshtastic.sqlite")
    conn.execute("SELECT 1"); conn.close()
except Exception: sys.exit(1)
sys.exit(0)
```
If `psutil` is undesirable, check `/proc` for the mesh.py PID or `pgrep -f "python.*mesh.py"` via `subprocess`. Prefer stdlib + `subprocess.run(["pgrep","-f","python.*mesh.py"])`.

**Tier 2 (opt-in):** if the user enables `[WebApp].Enabled = true` and exposes port 5000, switch the Docker HEALTHCHECK to `curl -fsS http://localhost:5000/ || exit 1` for a real HTTP liveness signal. Document the tradeoff (heavier image, Flask + map deps) in README.

`Dockerfile` HEALTHCHECK is set in Phase 1; Phase 2 finalizes `healthcheck.py` logic.

### Phase 2 acceptance
- [ ] Message round-trips both directions with sender name visible.
- [ ] A >256-char Telegram message arrives on the node (split if necessary) and an ellipsided version appears in Telegram for long inbound bursts.
- [ ] `sqlite3 ./data/meshtastic.sqlite` shows recent rows in `MeshtasticMessageRecord` and the file survives `docker compose down && up`.
- [ ] `docker inspect` Health `healthy` while running; `unhealthy` if mesh.py is killed.
- [ ] No new Pony schema; no core upstream file edits.

---

## Phase 3 — Polish: CI, README, Graceful Shutdown, Log Rotation

### 3.1 GitHub Actions CI (`.github/workflows/ci.yml`)
**Triggers:** `push` and `pull_request` to `main` (mirror upstream's `on: [push]` plus PR).
**Concurrency:** `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }` to drop superseded runs.

**Jobs:**
1. **lint** (ubuntu-latest, no matrix)
   - `actions/checkout@v4`
   - `hadolint Dockerfile` (Dockerfile linter)
   - `shellcheck entrypoint.sh scripts/*.sh`
   - `python -m py_compile healthcheck.py` (syntax)
2. **build** (ubuntu-latest)
   - checkout
   - `bash scripts/fetch-upstream.sh` (uses `upstream.version`)
   - `docker build -t meshbridge:ci .`
   - `docker save meshbridge:ci -o /tmp/image.tar` (artifact for downstream jobs)
3. **smoke** (depends on build)
   - restore image
   - `docker run --rm meshbridge:ci python mesh.py --help` → assert exit 0 and stdout contains `usage: mesh.py`
   - `docker run --rm -e TELEGRAM_TOKEN=dummy -e TELEGRAM_GROUP_ID=-1 -e TELEGRAM_ADMIN_ID=1 -e MESHTASTIC_HOST=192.0.2.1 -e MESHTASTIC_ADMIN=!dead meshbridge:ci sh -c 'python /app/healthcheck.py || true; pgrep -f "mesh.py" || true'` (cannot keep a long-running bot alive in CI against a blackhole IP; assert the entrypoint renders config + launches without import errors)
   - Optional: run upstream's own `pytest --cov mtg` inside the image against the vendored `upstream/mtg` tests, to catch wrapper-induced regressions. Gate behind a `RUN_TESTS` matrix flag to keep fast jobs fast.
4. **(optional) upstream-sync** — a weekly `schedule` job that opens an issue when a new upstream tag is published, prompting a `upstream.version` bump. Out of scope for v1; note as future work.

**Matrix:** no Python matrix needed for the wrapper (we only ship a container). If job 3 runs upstream pytest, use a single `python:3.12-slim` container.

**Secrets:** none required for CI (uses dummy values). Do not inject a real `TELEGRAM_TOKEN`.

### 3.2 README — required sections
Rewrite the current minimal `README.md` into:
1. **Title + one-line pitch** (keep current).
2. **Architecture diagram** (keep the ASCII diagram; add volume + healthcheck + entrypoint).
3. **Prerequisites** — Docker Engine 24+, docker-compose v2, a Meshtastic node reachable over TCP (port 4403 default), a Telegram bot token.
4. **Quick Start** — `cp .env.example .env`, edit, `bash scripts/fetch-upstream.sh`, `docker compose up -d`, `docker compose logs -f`. (One-time upstream fetch step is new vs current README.)
5. **Configuration** — table of `.env` keys (from `.env.example`) with descriptions; note that `mesh.ini` is rendered from env by `entrypoint.sh` (or, if file-driven strategy is chosen, document editing `mesh.ini` directly and the key reference from `mesh.ini.example`).
6. **Meshtastic node setup** — keep current section; add requirement that the node's TCP API is enabled and reachable from the Docker host.
7. **Healthcheck** — explain Tier 1 (process + DB) and Tier 2 (webapp + curl); how to read `docker inspect` health.
8. **Logs & log rotation** — point to the compose `logging` block; note `max-size`/`max-file`.
9. **Operational commands** — `docker compose logs`, `down`, `restart`; how to inspect SQLite (`sqlite3 ./data/meshtastic.sqlite`).
10. **Updating upstream** — edit `upstream.version`, re-run `fetch-upstream.sh`, rebuild.
11. **Troubleshooting** — node unreachable (TCP timeout logs), token rejected (Telegram 401), DB locked (concurrent writer — shouldn't happen with single container).
12. **License** — Apache 2.0 (matches upstream).

### 3.3 Graceful shutdown
- **Already partially upstream:** `main()` calls `telegram_bot.shutdown()` and `thread_manager.shutdown_all()` on exit.
- **Wrapper responsibilities:**
  - `entrypoint.sh` `exec`s mesh.py so it is PID 1 and receives SIGTERM directly from Docker. (If an init shim like `tini` is preferred for signal reaping, add `RUN apt-get install -y tini` and `ENTRYPOINT ["/usr/bin/tini","--","/app/entrypoint.sh"]` — recommended because Python as PID 1 doesn't forward signals to child threads well.)
  - `docker-compose.yml`: `stop_grace_period: 30s` (already in the Phase 1 sketch) gives `ThreadManager` time.
  - **Verify:** `docker compose stop meshbridge` should produce a clean `Exiting...` log line (from `logger.info('Exiting...')`) within the grace period, not a `SIGKILL` after 10s. If `thread_manager.shutdown_all()` hangs, document the workaround (lower `stop_grace_period`) and file an upstream issue.
  - **Signal handling:** if upstream doesn't install a SIGTERM handler (verify in `mtg/mesh.py` and `mtg/utils/thread_manager.py`), the natural `KeyboardInterrupt`/`SystemExit` path should still fire on SIGTERM because `telegram_bot.run()` (python-telegram-bot's `run_polling`/`run_webhook`) installs its own handlers. Confirm; if not, add a small `signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))` in the entrypoint shim module imported before `mesh.py main`. Prefer `tini` to avoid the Python-PID-1 signal gotcha entirely.

### 3.4 Log rotation
- Implemented by the compose `logging` block (Phase 1 sketch): `json-file` driver with `max-size: 10m`, `max-file: 3`. Captures stdout/stderr of `mesh.py`.
- Upstream's `start.sh` writes `logfile.out`/`logfile.err` via `screen` — **not used in Docker**; we run `mesh.py` directly so its stdout/stderr are captured by the Docker logging driver. Confirm no stray file-based logging is configured in `mesh.ini` (e.g. `NodeLogEnabled = false`).
- Document in README (section 8) how to adjust rotation values and how to switch to `journald`/`syslog`/`fluentd` drivers.

### Phase 3 acceptance
- [ ] CI `.github/workflows/ci.yml` runs lint + build + smoke on push/PR; smoke job asserts `mesh.py --help` exits 0.
- [ ] README rewritten with all 12 sections; quick start works from cold clone.
- [ ] `docker compose stop` produces clean `Exiting...` within `stop_grace_period` (no SIGKILL).
- [ ] Logs rotate at 10m×3; verified by `docker inspect` showing the `json-file` options.

---

## Cross-cutting notes

- **No edits to upstream source.** All wrapper behavior lives in `entrypoint.sh`, `healthcheck.py`, optional `external/plugins/` shims, and config. Upstream is vendored read-only.
- **Reproducibility:** `upstream.version` pins the ref; `requirements.txt` is copied from that ref at fetch time. Bump both together.
- **Secrets:** `.env` is gitignored; never commit a populated `mesh.ini`. `mesh.ini.example` carries only placeholder values.
- **Scope guard:** WebApp map, APRS, MQTT, OpenAI bot, Sentry APM, Slack — all upstream features left disabled by default. MeshBridge's scope is the bidirectional text relay + SQLite + healthcheck + ops. Enabling extras is a README pointer, not a plan task.

## Suggested task ordering for the implementor
1. Pin `upstream.version`, add `scripts/fetch-upstream.sh`, fetch upstream locally. (Phase 1)
2. Fix Dockerfile base to `python:3.12-slim`, add apt deps + tini + HEALTHCHECK stub. (Phase 1)
3. Rename `mesh.ini` → `mesh.ini.example`, gitignore runtime `mesh.ini`. (Phase 1)
4. Write `entrypoint.sh` (env→mesh.ini render + exec). (Phase 1)
5. Update `docker-compose.yml` (env_file, stop_grace_period, logging). (Phase 1)
6. Run Phase 1 smoke steps 1–8. (Phase 1 gate)
7. Wire real node + Telegram group; verify bidirectional relay; capture evidence. (Phase 2.1–2.2)
8. Verify/inject chunking shim if needed. (Phase 2.3)
9. Verify SQLite persistence across restarts. (Phase 2.4)
10. Finalize `healthcheck.py`. (Phase 2.5)
11. Add `.github/workflows/ci.yml`. (Phase 3.1)
12. Rewrite README. (Phase 3.2)
13. Add `tini` + verify graceful shutdown. (Phase 3.3)
14. Confirm log rotation. (Phase 3.4)

Each numbered item is one kanban task routed to `implementor`; the planner (this session) does not write code.