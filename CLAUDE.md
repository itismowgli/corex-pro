# CLAUDE.md — CoreX Pro Development Guide

This file is the authoritative context document for AI assistants working on
CoreX Pro. Read this before touching any file in the repo. Update it when you
discover something important that is not documented here.

---

## Project Overview and Mission

CoreX Pro is a production-grade homelab orchestration system. Its single-sentence
mission: give any technically curious person a fully sovereign self-hosted
infrastructure with a single command, with no cloud dependency.

The philosophy is expressed in the tagline **"Brains on System. Muscle on SSD."**
The OS and Docker engine live on the fast local disk. All persistent data lives
on an external SSD. The separation makes the system easy to migrate, restore,
and reason about.

**Target user:** A developer, privacy-conscious individual, or technically
adventurous person who can follow instructions but does not want to spend weeks
learning nginx, SSL, Docker networking, or Linux hardening.

**Core design constraints:**
- One-command install: `curl -fsSL .../corex.sh | sudo bash`
- All services are user's choice — nothing forced except core infrastructure
- Adding a new service = drop one file in `lib/services/` (auto-discovered)
- Re-run on existing server = health-check + repair broken services only
- No live server required for testing (Docker-in-Docker + bats)

**Current version:** v2.2.0
**Current services:** 14 (Traefik, AdGuard, Portainer, Nextcloud, Immich,
Vaultwarden, Stalwart Mail, Coolify, n8n, Time Machine, Uptime Kuma,
Grafana+Prometheus, Ollama+OpenWebUI+Browserless, CrowdSec)

---

## Repository Layout

```
corex-pro/
├── corex.sh                  # CLI entry point. Routes to specialized scripts.
├── install-corex-master.sh   # Main installer. 1865 lines, 7 phases. (v1 monolith)
├── nuke-corex.sh             # Uninstall/rollback. 10 phases.
├── migrate-domain.sh         # Change domain across all services at once.
├── corex-manage.sh           # [v2] Post-install service manager.
├── CLAUDE.md                 # This file.
├── CHANGELOG.md              # Version history.
├── NUKE.md                   # Nuke script user documentation.
├── README.md                 # Public-facing docs and quickstart.
├── lib/                      # [v2] Modular library (sourced by installer)
│   ├── common.sh             # Colors, logging helpers
│   ├── state.sh              # Read/write /etc/corex/state.json
│   ├── wizard.sh             # Interactive config wizard (whiptail + fallback)
│   ├── preflight.sh          # Phase 0 extracted
│   ├── drive.sh              # Phase 1 extracted
│   ├── security.sh           # Phase 2 extracted
│   ├── docker.sh             # Phase 3 extracted
│   ├── directories.sh        # Phase 4, service-aware
│   ├── backup.sh             # Phase 6 extracted
│   ├── summary.sh            # Phase 7 extracted
│   └── services/             # One file per service (auto-discovered)
│       ├── traefik.sh
│       ├── adguard.sh
│       └── ...               # Drop new service files here
└── test/
    ├── Dockerfile.test       # Ubuntu 24.04 test container
    ├── run-tests.sh          # Test runner
    ├── unit/                 # bats unit tests (no root/Docker needed)
    └── smoke/                # Compose file generation tests
```

### Key paths on the installed server

| Path | Purpose |
|------|---------|
| `/mnt/corex-data/` | Root of the external SSD data partition |
| `/mnt/corex-data/docker-configs/<service>/` | docker-compose.yml per service |
| `/mnt/corex-data/service-data/<service>/` | Persistent app data (DBs, uploads) |
| `/mnt/corex-data/backups/restic-repo/` | Restic encrypted backup repo |
| `/mnt/timemachine/` | Dedicated Time Machine partition (legacy) |
| `/mnt/corex-data/timemachine-data/` | Time Machine data (current, shared pool) |
| `/root/corex-credentials.txt` | Auto-generated service passwords (chmod 600) |
| `/root/CoreX_Dashboard_Credentials.md` | Full dashboard and post-install guide |
| `/etc/corex/state.json` | [v2] Tracks installed services and configuration |
| `/usr/local/bin/corex-backup.sh` | Daily Restic backup script |
| `/usr/local/bin/corex-restore.sh` | Interactive restore script |
| `/var/log/corex-backup.log` | Backup log |
| `/etc/fail2ban/jail.local` | Fail2ban SSH jail config |
| `/etc/sysctl.d/99-corex.conf` | Kernel hardening parameters |

---

## Architecture Decisions

### Why heredocs for docker-compose files?

The docker-compose files are generated at runtime via bash heredocs because
they embed variables (SERVER_IP, DOMAIN, passwords). This avoids maintaining
separate template files and keeps the installer self-contained.

**Convention:** When adding a service, write its docker-compose content as a
heredoc inside the service's `_deploy()` function in `lib/services/<name>.sh`.

### Why Cloudflare Tunnel and not port forwarding?

Cloudflare Tunnel requires zero router configuration. The tunnel is established
from inside the Docker network outbound to Cloudflare. Works on any internet
connection — apartment, office, hotel — without touching router settings.

**Critical implication:** In CF Dashboard "Public Hostnames" config, use Docker
container names as the service URL, not "localhost". The cloudflared container
is on proxy-net alongside other containers. `n8n:5678` resolves via Docker DNS.

### Why Traefik v3 when Cloudflare Tunnel handles external access?

They are complementary:
- Cloudflare Tunnel: encrypted path from internet to server
- Traefik: internal routing, LAN HTTPS, auto-discovery via Docker labels

Local clients (with AdGuard DNS rewrites pointing `*.domain → SERVER_IP`) hit
Traefik directly at HTTPS without going through Cloudflare. Traefik also handles
HTTP→HTTPS redirects and Let's Encrypt certificate issuance.

### Why three Docker networks?

| Network | Members | Reason |
|---------|---------|--------|
| `proxy-net` | Traefik, Cloudflared, all web services | Web-facing; reachable from Traefik and tunnel |
| `monitoring-net` | Prometheus, Grafana, Node Exporter, cAdvisor | Metrics isolated; Prometheus not web-accessible |
| `ai-net` | Ollama, Open WebUI, Browserless | AI sandboxed from web services; extra isolation for code execution |

Services needing web access AND metrics (Grafana, Open WebUI) are on BOTH their
specialized network AND proxy-net. This is intentional.

### Why `set -e`, `set -u`, `set -o pipefail`?

Defense against silent failures. Non-negotiable in install scripts. If a command
is expected to fail, use `|| true` explicitly. Do not remove these flags.

**Exception:** `corex.sh` and `nuke-corex.sh` use `set -uo pipefail` (no `-e`)
because they have intentional fallthrough patterns (checking container status,
etc.). Do NOT add `set -e` to these files.

### Why plugin-style service modules (v2)?

Adding a new self-hosted service should require no changes to core scripts.
The wizard, doctor, and manage commands auto-discover services by reading all
files in `lib/services/`. Drop a new file → it appears everywhere automatically.

---

## Service Dependency Map

```
Traefik         <- no dependencies; must deploy first
AdGuard         <- no dependencies
Portainer       <- Docker socket access only
Cloudflared     <- requires CLOUDFLARE_TUNNEL_TOKEN; skipped if not set

Nextcloud       <- depends on nextcloud-db (MariaDB) + nextcloud-redis
Immich          <- depends on immich-db (PostgreSQL) + immich-redis + immich-ml

Vaultwarden     <- standalone (SQLite internal)
Stalwart Mail   <- standalone; requires domain
n8n             <- standalone (SQLite internal)
Coolify         <- standalone; MANUAL install only (port conflict)

Uptime Kuma     <- standalone
Grafana         <- depends on Prometheus for metrics (but runs independently)
Prometheus      <- depends on Node Exporter, cAdvisor for scrape targets
CrowdSec        <- depends on /var/log access (host bind mount)

Ollama          <- standalone (model downloads on first use)
Open WebUI      <- depends on Ollama (OLLAMA_BASE_URL env var)
Browserless     <- standalone; shares WEBUI_SECRET_KEY for auth token

Time Machine    <- host networking; depends on avahi-daemon on host
```

### Network membership

| Service | proxy-net | monitoring-net | ai-net |
|---------|:---------:|:-------------:|:------:|
| Traefik | YES | - | - |
| Cloudflared | YES | - | - |
| AdGuard | YES | - | - |
| Portainer | YES | - | - |
| Nextcloud | YES | - | - |
| Immich | YES | - | - |
| Vaultwarden | YES | - | - |
| n8n | YES | - | - |
| Stalwart | YES | - | - |
| Uptime Kuma | YES | YES | - |
| Grafana | YES | YES | - |
| Prometheus | - | YES | - |
| Node Exporter | - | YES | - |
| cAdvisor | - | YES | - |
| CrowdSec | YES | - | - |
| Ollama | YES | - | YES |
| Open WebUI | YES | - | YES |
| Browserless | - | - | YES |
| Time Machine | host networking | - | - |

---

## Traefik Label Pattern

Every web-facing service needs these labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<name>.rule=Host(`<subdomain>.${DOMAIN}`)"
  - "traefik.http.routers.<name>.entrypoints=websecure"
  - "traefik.http.routers.<name>.tls.certresolver=myresolver"
  - "traefik.http.services.<name>.loadbalancer.server.port=<CONTAINER_PORT>"
```

**Critical:** `loadbalancer.server.port` is the CONTAINER'S internal port, not
the host-mapped port. Example: Grafana maps `3002:3000` on host, but Traefik
label must say port `3000`.

For services using HTTPS internally (Portainer on 9443), add:
```yaml
  - "traefik.http.services.portainer.loadbalancer.server.scheme=https"
```

The router name `<name>` must be unique across all services.

---

## Storage Architecture

```
Local Disk (OS drive)
├── Ubuntu 24.04 OS
└── /var/lib/docker/     <- Docker engine, image layers, build cache

External SSD
├── Partition 1 (TM_SIZE, default 500GB)
│   └── /mnt/timemachine   <- Legacy dedicated TM partition
└── Partition 2 (remainder)
    └── /mnt/corex-data
        ├── docker-configs/           <- Generated docker-compose.yml files
        │   ├── traefik/
        │   │   ├── docker-compose.yml
        │   │   ├── traefik.yml
        │   │   └── acme.json         <- Let's Encrypt certs (chmod 600!)
        │   ├── nextcloud/docker-compose.yml
        │   └── ... (one dir per service)
        ├── service-data/             <- All persistent state
        │   ├── nextcloud-db/         <- MariaDB data files
        │   ├── nextcloud-html/       <- Nextcloud PHP files (uid 33)
        │   ├── immich-db/            <- PostgreSQL data
        │   ├── immich-upload/        <- Uploaded photos
        │   ├── vaultwarden/          <- SQLite vault DB
        │   ├── stalwart-data/        <- Email data
        │   ├── n8n/                  <- Workflow DB
        │   ├── ollama/               <- Downloaded LLM models (large!)
        │   ├── open-webui/           <- Chat history
        │   ├── adguard-work/         <- AdGuard runtime data
        │   ├── adguard-conf/         <- AdGuard config (AdGuardHome.yaml)
        │   ├── uptime-kuma/
        │   ├── grafana/              <- Dashboards (uid 472)
        │   ├── prometheus/           <- Time-series DB (uid 65534)
        │   ├── portainer/
        │   ├── crowdsec-db/
        │   └── crowdsec-config/
        ├── timemachine-data/         <- Time Machine SMB share (current)
        └── backups/
            └── restic-repo/          <- Encrypted Restic repository
```

### File ownership requirements (critical)

Violating these causes "permission denied" on container startup:

| Directory | UID:GID | Service |
|-----------|---------|---------|
| `nextcloud-html/` | 33:33 | www-data (Nextcloud PHP) |
| `grafana/` | 472:472 | Grafana default |
| `prometheus/` | 65534:65534 | nobody/nogroup |
| Everything else | 1000:1000 | Standard user |

---

## Bash Coding Conventions

### Shebang and strict mode

```bash
#!/bin/bash
set -e
set -u
set -o pipefail
```

Exception: `corex.sh` and `nuke-corex.sh` use `set -uo pipefail` only.

### Logging functions (from installer — copy into each new script)

```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step()    { echo -e "${CYAN}${BOLD}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
```

Do NOT use raw `echo` for status output. Do NOT import log functions between
scripts — each script defines its own identical set.

### Variable naming

- `SCREAMING_SNAKE_CASE` for all variables
- Configuration vars at top of script in a clearly marked block
- Local function variables: `local VAR_NAME`

### Heredoc markers convention

Use unique end markers per heredoc to prevent nesting confusion:
- `DCEOF` — docker-compose files
- `TEOF` — Traefik config
- `PEOF` — Prometheus config
- `CREDEOF` — credential files
- `DOCSEOF` — documentation files
- Use `'ENDMARKER'` (single-quoted) to suppress variable substitution

### Error handling pattern

```bash
some_command || log_error "Description of what failed"      # Fatal
some_command || log_warning "Non-fatal, continuing..."       # Non-fatal
some_command 2>/dev/null || true                            # Silently ignore
```

Avoid verbose `if ! command; then log_error; fi` — use `|| log_error` instead.

### Idempotency pattern

```bash
docker network create proxy-net 2>/dev/null || true  # Safe to re-run
docker compose up -d                                  # Naturally idempotent
```

All install operations must be safe to re-run on an existing setup.

---

## Common Pitfalls and Gotchas

### 1. AdGuard port detection

AdGuard changes its internal port after the setup wizard: before wizard = 3000,
after wizard = 80. The install script detects this by reading
`adguard-conf/AdGuardHome.yaml`. Always read the config file, never hardcode.

### 2. Portainer over HTTPS to Traefik

Portainer listens on 9443 with HTTPS internally. Traefik must be told to use
HTTPS: add `traefik.http.services.portainer.loadbalancer.server.scheme=https`.
Without this, Traefik sends HTTP to an HTTPS endpoint → bad handshake.

### 3. Stalwart admin password

Stalwart generates its own admin password on first boot and prints it to stdout.
The installer waits ~20 seconds, then reads it from `docker logs`. If this fails,
credential file gets a placeholder. To recover: `docker logs stalwart | grep password`.

### 4. Nextcloud behind proxy (3 required env vars)

These MUST be set or Nextcloud generates broken URLs and redirect loops:
- `OVERWRITEPROTOCOL: https`
- `OVERWRITEHOST: nextcloud.${DOMAIN}`
- `TRUSTED_PROXIES: 172.16.0.0/12`

### 5. n8n webhook URLs (2 required env vars)

```yaml
N8N_PROTOCOL: https
WEBHOOK_URL: https://n8n.${DOMAIN}
```
Missing either causes n8n to generate `http://` webhook URLs that break behind HTTPS.

### 6. Time Machine host networking

Time Machine uses `network_mode: host` because SMB (445) and mDNS/Bonjour (5353)
require host network access. It is NOT on proxy-net. Traefik cannot route to it.
Access is always via direct LAN IP: `smb://SERVER_IP/CoreX_Backup`.

### 7. resolv.conf is locked

The installer runs `chattr +i /etc/resolv.conf` to prevent systemd-resolved from
overwriting DNS configuration. To modify DNS: `chattr -i /etc/resolv.conf` first.

### 8. Prometheus uid 65534 ownership

Prometheus runs as UID 65534 (nobody). Data directory MUST be owned by 65534:65534
or Prometheus fails with "permission denied on tsdb". If you recreate the directory
manually, chown it: `chown 65534:65534 /mnt/corex-data/service-data/prometheus/`.

### 9. Credential file loading on re-runs (CRITICAL)

Phase 0 checks for `/root/corex-credentials.txt`. If it exists, passwords are
LOADED from it — not regenerated. This prevents new passwords from locking you
out of existing databases. Never delete the credential file before a re-run.

### 10. OpenClaw setup (not auto-installed)

OpenClaw is an AI agent tool that connects to Ollama for local model access.
It requires manual setup after the AI stack is running.

**Setup steps:**
```bash
# 1. Create dedicated user (NEVER run as root)
sudo adduser --system --home /home/openclaw --shell /bin/bash openclaw
sudo usermod -aG docker openclaw
sudo mkdir -p /home/openclaw/.openclaw
sudo chown -R openclaw:nogroup /home/openclaw

# 2. Install globally as root
sudo npm install -g openclaw@latest

# 3. Find Ollama URL (Ollama runs in Docker)
docker ps | grep ollama   # Check for port mapping 11434->11434
# If mapped: use http://127.0.0.1:11434
# If not mapped: docker inspect ollama --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# 4. Switch to openclaw user and configure
sudo -u openclaw -i
openclaw onboard
# During onboarding: skip cloud providers, choose Ollama/local

# 5. Write config
cat > ~/.openclaw/openclaw.json << 'CONFIGEOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/qwen3-coder"
      }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://127.0.0.1:11434",
        "apiKey": "ollama-local"
      }
    }
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback"
  }
}
CONFIGEOF

# 6. Start gateway
openclaw gateway --force
# Save the token URL shown

# 7. Install as systemd service (as root)
exit
cat > /etc/systemd/system/openclaw.service << 'EOF'
[Unit]
Description=OpenClaw AI Assistant Gateway
After=network.target docker.service

[Service]
Type=simple
User=openclaw
Group=nogroup
Environment=HOME=/home/openclaw
ExecStart=/usr/local/bin/openclaw gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable openclaw && systemctl start openclaw
```

**Troubleshooting OpenClaw:**
- Cannot reach Ollama → check `openclaw.json` `baseUrl` matches actual Ollama port/IP
- Model not found → pull it: `docker exec -it ollama ollama pull qwen3-coder`
- `openclaw onboard` fails → skip it, write config manually (step 5 above)
- Gateway not starting → check `systemctl status openclaw` and `journalctl -u openclaw`
- LAN access → change `"bind": "loopback"` to `"bind": "0.0.0.0"` in config

**Recommended models for OpenClaw + Ollama:**
- `qwen3-coder` — best tool calling support
- `glm-4.7-flash` — lighter, faster
- Avoid models >14B on Ryzen 7 with integrated GPU (too slow)

---

## What NOT to Do

These are firm constraints. Violating them breaks existing installations.

1. **DO NOT change mount paths** `/mnt/timemachine` or `/mnt/corex-data`.
   Hardcoded in `nuke-corex.sh` and `migrate-domain.sh`.

2. **DO NOT rename `/root/corex-credentials.txt`** or change its format.
   `phase0_precheck()` uses exact `grep` patterns to load fields. If you add
   a new credential, add it with a new unique label and update both save
   (phase7) and load (phase0) blocks.

3. **DO NOT add `set -e` to `corex.sh` or `nuke-corex.sh`**. These scripts
   have intentional fallthrough patterns where commands may fail.

4. **DO NOT auto-deploy Coolify**. It installs its own Traefik on ports 80/443,
   conflicting with CoreX Traefik. Always generate a manual install helper script.

5. **DO NOT add `network_mode: host` to any service other than Time Machine**.
   Host networking bypasses Docker network isolation.

6. **DO NOT commit real credentials, tokens, or IP addresses**. Config block in
   `install-corex-master.sh` must always have placeholder values.

7. **DO NOT change the Restic password** after initial setup. It invalidates the
   existing repository and all backups.

8. **DO NOT use `docker volume prune`** — it destroys ALL unnamed volumes
   including potentially active service data. Always be explicit: `docker volume rm <name>`.

---

## How to Test Changes Safely

Production is live and cannot be used for testing. Use these strategies:

### 1. Syntax validation (fastest, no setup)
```bash
bash -n install-corex-master.sh        # Parse-only, no execution
bash -n corex.sh
shellcheck install-corex-master.sh     # Static analysis (apt install shellcheck)
```

### 2. Unit tests with bats (no root/Docker needed)
```bash
bats test/unit/      # Pure bash function tests
```

### 3. Compose smoke tests (validates heredoc generation)
```bash
docker build -f test/Dockerfile.test -t corex-test .
docker run corex-test bats test/smoke/
```
Each test: sets env vars, sources service module, calls `_deploy()` with docker
mocked, validates generated `docker-compose.yml` has correct values and passes
`docker compose config` validation.

### 4. Full integration test (Docker-in-Docker)
```bash
docker run --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e COREX_NON_INTERACTIVE=1 \
  -e TEST_DOMAIN=test.example.com \
  -e TEST_IP=192.168.1.100 \
  corex-test bash install-corex-master.sh
```

### 5. Compose validation on live server (read-only, safe)
```bash
cd /mnt/corex-data/docker-configs/<service>
docker compose config   # Validates and prints resolved compose file
```

### 6. Dry-run mode
`nuke-corex.sh --dry-run` and `migrate-domain.sh --dry-run` show changes
without applying them. Add `--dry-run` to `install-corex-master.sh` as well
(planned for v2).

---

## Interactive UI Design Principles

When adding interactive prompts:

1. **Show what and why.** Before every `read` or whiptail box, print a clear
   description of what the question is asking and why it matters.
   ```bash
   # BAD:  read -p "Domain: " DOMAIN
   # GOOD: Show multi-line explanation, then ask with example
   ```

2. **Show defaults.** Format: `[default: 192.168.1.100]`. Users press Enter to
   accept. Never leave a field blank without explaining what happens.

3. **Validate immediately.** If input is invalid, explain why and re-ask.
   Never proceed with bad input and fail later.

4. **Confirm destructive actions.** Any deletion or format requires explicit
   confirmation. Catastrophic actions (formatting a drive) require typing a
   specific word like "DESTROY".

5. **Detect terminal before using interactive prompts.**
   ```bash
   if [[ ! -t 0 ]]; then
       log_warning "Non-interactive mode detected. Set env vars and re-run."
       exit 1
   fi
   ```

6. **Use `whiptail` for complex UIs** (checkbox lists, menus). It is pre-installed
   on Ubuntu. Fall back to plain `read` if unavailable:
   ```bash
   command -v whiptail &>/dev/null || USE_PLAIN_UI=true
   ```

---

## Plugin-Style Extensibility (v2)

### Service module contract

Every `lib/services/<name>.sh` must export:

```bash
# Metadata (auto-discovered by wizard)
SERVICE_NAME="gitea"
SERVICE_LABEL="Gitea — Self-hosted Git (replaces GitHub)"
SERVICE_CATEGORY="productivity"    # core|storage|security|productivity|ai|monitoring|communication|backup
SERVICE_REQUIRED=false             # true = always installed, not user-selectable
SERVICE_NEEDS_DOMAIN=true          # false = works in local-only mode too
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=512
SERVICE_DISK_GB=5
SERVICE_DESCRIPTION="Run your own Git server. Push code, manage repos, CI/CD — fully private."

# Functions (auto-called by installer and manage commands)
gitea_dirs()        { ... }    # Create dirs with correct ownership
gitea_firewall()    { ... }    # Add UFW rules if needed
gitea_deploy()      { ... }    # Write compose heredoc + docker compose up -d
gitea_destroy()     { ... }    # docker compose down + optional rm -rf data
gitea_status()      { ... }    # Return: HEALTHY | UNHEALTHY | MISSING
gitea_repair()      { ... }    # docker compose up -d --force-recreate (no data loss)
gitea_credentials() { ... }    # Print credential lines for summary doc
```

Drop this file in `lib/services/` — it automatically appears in wizard,
`corex-manage list`, `corex doctor`, and `corex-manage update`.

### Auto-discovery mechanism

```bash
# wizard.sh iterates all service modules dynamically
for svc_file in "${SCRIPT_DIR}/lib/services/"*.sh; do
    source "$svc_file"
    AVAILABLE_SERVICES+=("$SERVICE_NAME" "$SERVICE_LABEL" "$SERVICE_CATEGORY")
done
```

No hardcoded service lists anywhere in core scripts.

---

## Adding a New Service (Checklist)

Follow this checklist when adding a service to the project:

1. Create `lib/services/<name>.sh` with all metadata vars and all 7 functions
2. Write a smoke test in `test/smoke/` before implementing (TDD)
3. Implement `_dirs()` — create directories with correct ownership
4. Implement `_firewall()` — add UFW rules if needed
5. Implement `_deploy()` — write compose heredoc + `docker compose up -d` + `state_service_installed`
6. Implement `_status()` and `_repair()` for doctor command support
7. Implement `_credentials()` for the summary doc
8. Run smoke test to validate compose generation
9. Update this `CLAUDE.md` — add service to dependency map and network table
10. Update `CHANGELOG.md` with the new service under the next version

**Do NOT update any other core files.** Auto-discovery handles the rest.

---

## State File Structure (v2)

`/etc/corex/state.json` tracks installation state for `corex-manage` and `corex doctor`:

```json
{
  "version": "2.0.0",
  "installed_at": "2026-02-21T12:00:00Z",
  "mode": "with-domain",
  "domain": "example.com",
  "server_ip": "192.168.1.100",
  "email": "admin@example.com",
  "timezone": "UTC",
  "ssh_port": "2222",
  "cloudflare_tunnel_configured": true,
  "email_server_configured": false,
  "services": {
    "traefik":     { "installed": true,  "enabled": true, "installed_at": "2026-02-21T12:00:00Z" },
    "stalwart":    { "installed": false, "enabled": false, "installed_at": null }
  }
}
```

Key functions in `lib/state.sh`:
- `state_init` — create fresh state file
- `state_get "field"` — read a value
- `state_set "field" "value"` — write a value
- `state_service_installed "name"` — mark service installed
- `state_service_is_installed "name"` — returns 0 if installed
- `state_list_installed` — list all installed service names

---

## Version History Notes

- **v0.1.0** (2026-02-09): Proof of concept
- **v1.0.0** (2026-02-10): Initial release. Monolithic single-file installer. 14 services + Restic backups.
- **v1.1.0** (2026-02-11): Fixed Time Machine env var (PASSWORD not TM_PASSWORD), moved TM data to shared pool, added `corex.sh` CLI, `nuke-corex.sh`, `migrate-domain.sh`, curl-pipe detection, BASH_SOURCE detection.
- **v2.0.0** (2026-02-21): Modular lib/ structure, wizard, state.json, corex-manage, corex doctor, plugin extensibility. 1,865-line monolith replaced by ~200-line orchestrator + lib/ modules.
- **v2.0.1** (2026-02-22): Fixed `corex doctor` on v1 installs — auto-migrates state from `docker ps` when `state.json` is missing.
- **v2.1.0** (2026-03-01): Added `corex manage lan-setup` — automates AdGuard DNS wildcard rewrite via REST API; prints router/device DNS instructions. Eliminates the manual post-install AdGuard step.
- **v2.1.1** (2026-03-02): Fixed `lan-setup` HTTP 400 — v1 migration regex captured YAML quotes around email field, storing domain with embedded quotes in state.json. Fixed at root (migration strips quotes) and defensively in `_load_config()` via `tr -d '"'`.
- **v2.2.0** (2026-03-06): Network performance tuning + security hardening. Added `corex manage network-tune` command. Kernel params expanded from 14 to 50+ (BBR, 64MB TCP buffers, TCP Fast Open, MTU probing). Time Machine rebuilt with high-performance SMB3 (multichannel, 8MB chunks, async I/O, sendfile). SSH hardened with modern ciphers only (ChaCha20/AES-GCM, curve25519 KEX). Fail2ban upgraded to 3-jail system (standard + aggressive + recidive for 30-day repeat-offender bans).
