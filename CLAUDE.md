# CLAUDE.md: CoreX Pro Development Guide

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
- All services are user's choice, nothing forced except core infrastructure
- Adding a new service = drop one file in `lib/services/` (auto-discovered)
- Re-run on existing server = health-check + repair broken services only
- No live server required for testing (Docker-in-Docker + bats)

**Current version:** v3.19.0
**Current service modules:** 17 (Traefik, AdGuard, Portainer, Nextcloud,
Immich, Vaultwarden, Stalwart Mail, Coolify, n8n, Cal.com, Time Machine,
Uptime Kuma + Grafana + Prometheus (monitoring), Ollama + OpenWebUI +
Browserless (ai), CrowdSec, Cloudflared, Dashboard, UPS)

Note the count is service *modules* in `lib/services/`, not containers, a
single module can deploy several containers (`monitoring` and `ai` each deploy
three), so a full install runs considerably more than 16 containers.

---

## Writing Rules (apply to every commit, document, and release)

These are not style preferences. Follow them on anything that leaves this
machine.

### 1. Run the humanizer skill before you write, commit, or publish

Every piece of prose gets the `humanizer` skill applied **before** it is
written to a file, committed, pushed, tagged, or published. That covers
`README.md`, `CLAUDE.md`, `CHANGELOG.md`, commit messages, release notes, PR
descriptions, and any new documentation.

The rules that get broken most often here:

| Rule | What it means for this repo |
|---|---|
| No em or en dashes | Use a comma, colon, period, or parentheses in prose. Existing `SERVICE_LABEL` strings and dashboard UI labels keep their dashes, so the two stay consistent |
| No curly quotes | Straight `"` only |
| Sentence case headings | `## Outbound email`, not `## Outbound Email` |
| No emoji in headings or lists | Anywhere |
| No bold mini-heading lists | Write the sentence instead |
| Say what is, not what was | Code comments describe current behaviour. Version history belongs in `CHANGELOG.md`. The exception is a comment recording a trap that will otherwise be reintroduced, which this repo uses deliberately |

Check before committing:

```bash
grep -rn $'\u2014\|\u2013' README.md CLAUDE.md CHANGELOG.md   # em and en dashes
grep -rn $'\u201c\|\u201d' README.md CLAUDE.md CHANGELOG.md   # curly quotes
```

### 2. No AI attribution anywhere, ever

Nothing in this repository, its git history, or its releases may reference
Claude, Claude Code, Anthropic, or any AI assistant. Specifically:

- No `Co-Authored-By` trailer
- No "Generated with" line
- No AI mention in a commit message, tag message, release note, PR body, or
  code comment
- No AI name in `git config user.name` or `user.email` for any commit

Verify before pushing. Match attribution patterns, not the word itself, or
every mention of the `CLAUDE.md` filename counts as a hit:

```bash
git log --format='%an <%ae>%n%s%n%b' -30 \
  | grep -inE '^co-authored-by:|generated with \[|assisted by|claude (code|opus|sonnet)|anthropic'
# must print nothing
```

`Co-Authored-By` is anchored to the start of a line and followed by a colon so
that prose describing this rule does not register as a violation.

A commit that already carries attribution has to be amended or rebased out
before it is pushed.

---

### 3. Releases: tag and title are exactly `vX.Y.Z`

Every version gets a git tag, a GitHub release, and a `CHANGELOG.md` section,
and the release body is that section verbatim. The changelog stays the single
source of truth; nothing is written twice.

Titles had drifted through three styles at once, `CoreX Pro v3.1.0 - Resilience`,
`v3.4.0 - credentials, Stalwart visibility`, and a bare `2.0.0`, which makes the
release list unreadable. The title is now the tag and nothing else.

```bash
python3 tools/release-notes.py v3.12.0 > /tmp/notes.md
git tag -a v3.12.0 -m "v3.12.0 - short summary"
git push origin v3.12.0
gh release create v3.12.0 --repo itismowgli/corex-pro \
  --title v3.12.0 --notes-file /tmp/notes.md --latest
```

`tools/release-notes.py` refuses to print notes containing em dashes, an IP
address, an email address, a bot token or a credential, because a release body
cannot be quietly fixed later: it is what people receive in notifications.

Two things to watch. **Pass `--latest` explicitly**, since `gh release create`
awards the badge to whatever was created most recently, so backfilling an old
version silently moves "Latest" onto it. And a release's sort key is the
tagged **commit** date, not the publish time, so a backfilled release lands in
its correct historical position on the page.

`v0.1.0` and `v1.0.0` have no tag and cannot get one: they predate the first
commit in this repository. They exist only as changelog history.

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
│   ├── thermal.sh            # Thermal guardian — sheds load before TjMax (#17)
│   ├── watchdog.sh           # Resource alerting via Kuma push monitors (#29)
│   ├── kuma.sh               # Seeds Kuma HTTP checks from SERVICE_MONITORS
│   ├── agent.sh              # Privileged action agent + Telegram bot (#30)
│   ├── selfheal.sh           # Boot self-repair: dpkg + unclean shutdown (#16)
│   └── services/             # One file per service (auto-discovered)
│       ├── traefik.sh
│       ├── adguard.sh
│       └── ...               # Drop new service files here
├── tools/
│   └── release-notes.py     # Extracts a CHANGELOG section as a release body
├── agent/                    # Action agent and Telegram bot (Python, stdlib only)
│   ├── corex-agent.py        # Privileged action server on a unix socket
│   ├── corex-telegram.py     # Long-polling control bot, runs as corex-bot
│   ├── corex-agentctl.py     # CLI client, used by corex manage agent test
│   ├── corex-usersctl.py     # Dashboard accounts, behind corex manage dashboard-user
│   ├── corex_users.py        # Dashboard user store: hashing, reset mail, access log
│   ├── corex_metrics.py      # Host vitals, disks, series, Kuma states, as data
│   └── corex_common.py       # Shared helpers, installed to /usr/local/lib/corex
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
| `/etc/corex/watchdog.conf` | Watchdog thresholds and Kuma push tokens (0640) |
| `/etc/corex/agent.conf` | Action agent config (0640 root:corex-agent) |
| `/etc/corex/agent.token` | Agent bearer token (0640 root:corex-agent) |
| `/etc/corex/dashboard-users.json` | Dashboard accounts, PBKDF2 hashes, passkeys (0600 root) |
| `/var/log/corex-dashboard-auth.log` | Append-only dashboard access log (0640 root) |
| `/etc/corex/telegram.conf` | Bot token and authorised chat id (0640 root:corex-bot) |
| `/run/corex/agent.sock` | Agent socket (0660 root:corex-agent) |
| `/usr/local/bin/corex-watchdog.sh` | Resource watchdog, run every 60s by timer |
| `/var/log/corex-watchdog.log` | Watchdog findings (DOWN beats and push failures) |
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
connection (apartment, office, hotel) without touching router settings.

**Critical implication:** In CF Dashboard "Public Hostnames" config, use Docker
container names as the service URL, not "localhost". The cloudflared container
is on proxy-net alongside other containers. `n8n:5678` resolves via Docker DNS.

### Why Traefik v3.6 when Cloudflare Tunnel handles external access?

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
Cal.com         <- depends on calcom-db (PostgreSQL 16) + calcom-helper, which
                   supplies the cron Vercel would run and turns booking
                   webhooks into Telegram messages; prebuilt image, never
                   built; needs a domain, and an SMTP relay to send anything
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
| Cal.com (web, helper, db) | YES | - | - |
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
        │   │   ├── traefik.yml       <- Static config (entrypoints, providers)
        │   │   ├── dynamic.yml       <- Dynamic config (default wildcard cert)
        │   │   ├── acme.json         <- Let's Encrypt certs (chmod 600!)
        │   │   └── certs/            <- Self-signed CA + wildcard cert
        │   │       ├── ca.crt        <- CoreX Pro CA (distribute to clients)
        │   │       ├── ca.key        <- CA private key (chmod 600!)
        │   │       ├── wildcard.crt  <- *.DOMAIN wildcard certificate
        │   │       └── wildcard.key  <- Wildcard private key (chmod 600!)
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

### Logging functions (from installer: copy into each new script)

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
scripts, each script defines its own identical set.

### Variable naming

- `SCREAMING_SNAKE_CASE` for all variables
- Configuration vars at top of script in a clearly marked block
- Local function variables: `local VAR_NAME`

### Heredoc markers convention

Use unique end markers per heredoc to prevent nesting confusion:
- `DCEOF`: docker-compose files
- `TEOF`: Traefik config
- `PEOF`: Prometheus config
- `CREDEOF`: credential files
- `DOCSEOF`: documentation files
- Use `'ENDMARKER'` (single-quoted) to suppress variable substitution
- An unquoted heredoc still runs command substitution, so a backtick in a YAML
  comment inside one is executed. A comment reading ``# no `build:` block``
  produced `line 205: build:: command not found` and bash blamed the line the
  redirect was on, not the line the backtick was on. Escape them (`` \` ``) or
  write the word plainly

### Error handling pattern

```bash
some_command || log_error "Description of what failed"      # Fatal
some_command || log_warning "Non-fatal, continuing..."       # Non-fatal
some_command 2>/dev/null || true                            # Silently ignore
```

Avoid verbose `if ! command; then log_error; fi`, use `|| log_error` instead.

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

### 3. Stalwart admin password: pin it, never scrape the log

`STALWART_ADMIN_USER` / `STALWART_ADMIN_SECRET` are **not read** by current
Stalwart images. CoreX set them for a long time, which looked correct and did
nothing: Stalwart fell back to **bootstrap mode**, generated its own random
temporary password, and printed it to the container log exactly once.

The result in the field was a mail server nobody could ever log into, the
credentials file had no Stalwart entry at all, and the only copy of the
password was a log line. The service appeared healthy the whole time.

The supported variable is `STALWART_RECOVERY_ADMIN`, in `user:password` form,
and Stalwart's own bootstrap message points at it:

```yaml
STALWART_RECOVERY_ADMIN: "admin:${STALWART_ADMIN_PASS}"
```

The password is also persisted to `${DOCKER_ROOT}/stalwart/.admin-password`
(0600), because it must stay **stable across re-runs**, the previous code
regenerated it whenever `STALWART_ADMIN_PASS` was unset, which is every
`corex manage repair stalwart`, silently changing the admin password to a
value nothing recorded.

To recover a lost password: read that file, or set
`STALWART_RECOVERY_ADMIN` to a known value and recreate the container. As a
last resort the bootstrap password may still be in `docker logs stalwart`.

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
LOADED from it, not regenerated. This prevents new passwords from locking you
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
- `qwen3-coder`: best tool calling support
- `glm-4.7-flash`: lighter, faster
- Avoid models >14B on Ryzen 7 with integrated GPU (too slow)

### 11. LAN fast-path requires solving 5 browser bypass layers

AdGuard DNS rewrite (A-record → LAN IP) is necessary but NOT sufficient.
Modern browsers have 4 additional paths that bypass the DNS rewrite:

1. **SVCB/HTTPS (Type 65) DNS records**, Cloudflare publishes these with
   embedded IPv4/IPv6 address hints. Browsers query them and connect directly
   to Cloudflare, ignoring A-record rewrites. Fix: AdGuard filtering rules
   `||domain^$dnstype=SVCB` and `||domain^$dnstype=HTTPS`.

2. **Chrome QUIC/HTTP3 Alt-Svc caching**, Chrome caches QUIC connections to
   Cloudflare via the Alt-Svc HTTP header for up to 30 days. Even after DNS
   changes, Chrome reuses cached connections. Fix: Chrome policy
   `QuicAllowed=false`.

3. **Chrome built-in DNS client**, bypasses the system DNS resolver entirely.
   Fix: Chrome policy `BuiltInDnsClientEnabled=false`.

4. **IPv6 bypass**, AAAA records point to Cloudflare IPv6 edge servers.
   Browsers prefer IPv6, so even with correct IPv4 rewrite, they connect via
   IPv6 to Cloudflare. Fix: disable IPv6 on the LAN interface.

All 5 layers are addressed by `corex manage lan-setup` (Steps 1-6).

### 12. Nextcloud max_chunk_size for Cloudflare compatibility

Nextcloud desktop/web client uploads files in chunks. Default chunk size is
100MB (104857600 bytes), but Cloudflare free plan rejects request bodies >100MB
with HTTP 413. The before-starting hook sets it to 10MB via `occ config:app:set
files max_chunk_size --value 10485760`. This works on all Cloudflare plans and
has minimal overhead for LAN transfers (chunks are parallelized).

### 13. Traefik self-signed CA and wildcard cert

Traefik auto-generates a CoreX Pro CA + `*.DOMAIN` wildcard cert on deploy.
The wildcard cert is served as the default TLS certificate via the file
provider (`dynamic.yml`). LAN clients that trust the CA get valid HTTPS
without Let's Encrypt. The CA cert is at
`${DOCKER_ROOT}/traefik/certs/ca.crt`. Certs are regenerated if the domain
changes (detected by checking the SAN in the existing cert).

### 14. Secondary DNS servers defeat the LAN fast-path

Setting a secondary DNS (like 1.1.1.1 or 8.8.8.8) alongside AdGuard causes
DNS race conditions. Some queries hit the fallback server, which returns
Cloudflare IPs instead of the LAN IP. The `lan-setup` command warns against
this in Steps 1 and 2.

### 15. UFW must allow 10.0.0.0/8, not just 172.16.0.0/12

Docker's default address pool is `172.16.0.0/12`, but Docker **Swarm**, which
Coolify uses, allocates overlay networks from `10.0.0.0/8`. A UFW config that
only allows `172.16.0.0/12` silently drops every overlay packet and kernel-logs
each one, producing a `[UFW BLOCK]` entry every 10-60 seconds:

```
[UFW BLOCK] IN=br-<hash> SRC=10.0.1.5 DST=10.0.0.1 PROTO=TCP DPT=23517
```

This is self-inflicted noise, not an attack, and it buries genuine security
events. `lib/security.sh` now allows both ranges. Note that `ufw allow in on
br-+` is **not** a valid workaround, ufw validates interface names against
`[a-zA-Z0-9.:_-]+` and rejects the `+` wildcard outright.

### 16. Unclean shutdowns leave no journal evidence: use the blackbox log

When the machine loses power or hard-hangs, journald never flushes, so the
journal simply stops mid-line with no `systemd-shutdown` or `Reached target
Shutdown` marker. Diagnosing that class of failure from the journal alone is
impossible. Two things make it tractable:

- **Detecting it:** count clean-shutdown markers in the previous boot. Zero
  means power loss or hard hang, not a reboot:
  ```bash
  journalctl -b -1 | grep -cE "systemd-shutdown|Reached target Shutdown|Powering off"
  ```
  Also note that `last -x` showing every boot as "still running" is the same
  signal, no boot ever recorded a clean shutdown.
- **Diagnosing it:** `/mnt/corex-data/blackbox.log`, written every 20s by
  `corex-blackbox.timer`, survives unclean shutdown because it is a plain
  append to the SSD. The last line before the gap gives temperature, load,
  memory, swap and CPU throttle count at the moment of death, which
  distinguishes thermal shutdown from PSU failure from OOM.

**Do not clear logs on a crashing system before archiving them.** The journal
is the only crash evidence; `corex manage cleanup` vacuums it. Archive
`journalctl -b -1` first.

### 17. Mini servers thermal-trip: shed load, never let TjMax decide

CoreX targets small-form-factor hardware, which frequently means a mobile CPU
(Ryzen HX, Intel NUC) in a chassis with marginal cooling. Under sustained
container load these reach TjMax and fire **THERMTRIP**: an instant,
hardware-level power cut. This is the worst possible failure mode because:

- The kernel logs **nothing**, no critical-temp warning, no panic. The journal
  simply stops mid-line, so it looks exactly like someone pulled the plug.
  Diagnosing it without `lm-sensors` installed is close to impossible.
- Nothing is flushed, so you risk both database corruption *and* a broken dpkg
  database if it lands mid-`apt`.

A real measurement from the field: a Ryzen 9 5900HX sat at **Tctl 95.6°C** three
minutes after boot with 38 containers running, and tripped after ~5 minutes.
With the four heaviest containers stopped it still read **91.1°C**, so the
cooling was independently inadequate, not merely overloaded.

**Three rules follow:**

1. **`lm-sensors` and `smartmontools` are mandatory**, not optional. Without
   them the most common hardware failure is invisible. Check with
   `corex manage health`.
2. **Shed load before the hardware decides.** `lib/thermal.sh` installs a
   guardian that stops containers progressively as temperature climbs and
   restarts them when it falls. Pausing Ollama beats an unplanned power cut.
3. **`SERVICE_CATEGORY` is load-bearing.** The guardian derives shed order from
   it, so choosing the wrong category for a new service means it gets shed at
   the wrong time. Order: containers CoreX did not deploy (no resource limits,
   usually the culprit) → `ai` → `monitoring`/`productivity`/`storage`/`backup`.
   Never shed: `core`, `security`, `communication`.

Thresholds live in `/etc/corex/thermal.conf`; set `THERMAL_ENABLED=false` to
disable. Shed containers are tracked in `/var/lib/corex/thermal-shed.list`.

### 18. "Security-only" unattended-upgrades still upgrades the kernel

Ubuntu ships kernel updates through the `-security` origin, so restricting
`Unattended-Upgrade::Allowed-Origins` to `-security` does **not** stop
unattended kernel upgrades. This is how a CoreX box ended up with `systemd` and
`libc-bin` unpacked-but-unconfigured: unattended-upgrades began a kernel
upgrade, CPU load rose, the box thermal-tripped mid-transaction, and every
subsequent boot retried and re-broke it.

`lib/security.sh` therefore sets an explicit `Package-Blacklist` for
`linux-*`, `libc6`, `libc-bin`, `systemd` and `udev`. Those still get upgraded,
but only through `corex manage os-upgrade`, which refuses to start when the CPU
is above 85°C, when dpkg is already dirty, or when uptime is under 15 minutes.

`Remove-Unused-Kernel-Packages` is also set to `false`, removing a kernel is
itself a dpkg transaction, and a known-good fallback kernel is worth the disk.

Detect the damage with `corex manage health`; `lib/selfheal.sh` repairs it
automatically on the next boot via `dpkg --configure -a`.

### 19. Do not track moving major-version image tags

`nextcloud:stable` follows **major** versions. A routine `corex manage update`
pulled Nextcloud 33 -> 34 unattended, and 34 **removed `gosu`** from the image , 
which broke the `before-starting` hook completely. Every `occ` call failed with
`gosu: command not found`, the retry loop then blocked container startup for
~4 minutes per restart, Traefik served 502 throughout, and no configuration was
applied at all.

Nextcloud also does not support skipping major versions, so an instance left
two majors behind cannot upgrade itself and needs manual recovery.

Pin majors and bump them deliberately, the way `traefik:v3.6` and
`mariadb:10.11` already are. `nextcloud` is now pinned to `:34`.

Still tracking moving targets, and worth pinning for the same reason:
`ghcr.io/immich-app/immich-server:release`, `ghcr.io/open-webui/open-webui:main`.

**Corollary, never assume a binary exists in an upstream image.** Probe for it:

```bash
if command -v gosu >/dev/null 2>&1; then ...
elif command -v setpriv >/dev/null 2>&1; then ...
```

`setpriv`, `runuser` and `su` are all present in `nextcloud:34`. And fail fast
when privilege-dropping is impossible rather than retrying 30s per call, a
retry loop around an unsatisfiable command turns a warning into an outage.

### 28. An entrypoint default TLS domain does not override a router's resolver

`entryPoints.websecure.http.tls.domains` was set to request one
`DOMAIN` + `*.DOMAIN` certificate for every route, so that individual
subdomains would stop appearing in the Certificate Transparency logs.

It does not take effect. Every CoreX service sets
`traefik.http.routers.<name>.tls.certresolver=myresolver` on its own router,
and a router's own TLS configuration wins over the entrypoint default. Measured
after deploying it: `acme.json` held 13 certificates, all per hostname, none
carrying a SAN, and a hostname added afterwards (a new subdomain) still got
its own certificate rather than being covered by a wildcard.

So the block is inert unless each router also declares the domains:

```
traefik.http.routers.<name>.tls.domains[0].main=DOMAIN
traefik.http.routers.<name>.tls.domains[0].sans=*.DOMAIN
```

That is a label on all eleven routers, and it changes certificate issuance for
every service at once, so it wants doing deliberately rather than as a side
effect. Until then per-hostname issuance continues and every hostname is
listed at crt.sh.

Two things reduce how much that matters. Cloudflare terminates TLS at the edge
for anything published through the tunnel, so external visitors never see
Traefik's certificate; it is the LAN fast-path that uses it. And the CT
exposure is a disclosure of names, not of access.

### 27. The tunnel bypasses Traefik, so Traefik cannot protect external traffic

Cloudflare Public Hostnames point at container names and ports
(`http://n8n:5678`), which means cloudflared talks to the application
directly. Traefik is only in the path for LAN requests. Everything Traefik
adds is therefore absent from exactly the traffic that comes from the
internet.

Measured after attaching a `noindex` middleware to the `websecure` entrypoint.
On the LAN all ten hostnames returned the full directive set. From outside:

| Hostname | External `X-Robots-Tag` |
|---|---|
| `nextcloud` | full set, from its own configuration |
| `vault` | `noindex, nofollow`, Vaultwarden's own |
| `mail` | absent entirely |

So the header was set on the one path search engines never use. The same
applies to HSTS, the CalDAV redirect, and any middleware added later.

**Point the tunnel at Traefik instead of at containers.** One wildcard Public
Hostname replaces every per-service entry:

| Hostname | Service | Additional settings |
|---|---|---|
| `*.DOMAIN` | `https://traefik:443` | No TLS Verify on |

Traefik then routes by Host header, exactly as it does on the LAN. Three
things follow: middlewares apply to external traffic, a container port change
can no longer break the tunnel (which is what a per-service entry pins), and
a new service needs no Cloudflare work at all.

No TLS Verify is required because Traefik presents a certificate for the
public hostname while cloudflared connects to the name `traefik`, so
verification would fail on a name mismatch. The hop is inside the Docker
network.

### 26. A moving tag can stop moving, which is worse than moving too fast

Gotcha #19 is about `:release` and `:stable` carrying a major upgrade in
unannounced. The opposite happens too, and it is quieter: upstream starts a new
release line under a new tag and leaves the old tag frozen.

Two images on a working install:

| Image | `:latest` last built | Current line |
|---|---|---|
| `louislam/uptime-kuma` | 2025-10-20 | 2.x, as `:2` / `:2.5.3` |
| `browserless/chrome` | 2024-02-16 | moved to `ghcr.io/browserless/chromium` v2 |

Uptime Kuma therefore sat ten months behind and Browserless ran a
two-and-a-half-year-old browser engine, while `corex manage update --all`
reported success every time. `docker pull` is not lying when it says "Image is
up to date": the tag really does resolve to that image. Nothing below the tag
can detect this, which is the argument for pinning a version rather than
tracking a name.

Check with the registry, not the daemon:

```bash
curl -s https://hub.docker.com/v2/repositories/<repo>/tags/latest \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["last_updated"])'
```

**Two update bugs kept it invisible**, both since fixed, both worth
recognising elsewhere in the codebase:

- The digest shortcut read `config --images | head -1`, one image out of a
  stack. `monitoring` ships five and `ai` ships three, so a single current
  image returned early and skipped the rest, always deciding on the same one
  (`node-exporter`, which rarely changes). It also compared a `RepoDigest`
  against a per-platform entry from `docker manifest inspect`, which are
  different digests by construction.
- `docker compose pull` ran without its exit code being checked, and success
  was logged either way, so a rate limit or an expired tag looked exactly like
  an update.

### 20. Nextcloud gets stuck in maintenance mode, serving HTTP 503

`occ upgrade` finishes by printing **"Maintenance mode is kept active"** and
leaves the flag set. An upgrade interrupted by a crash does the same. While it
is set:

- Nextcloud serves **HTTP 503** to every request (Traefik included), so the
  service is fully down.
- Every `occ config:*` command fails with *"Nextcloud is in maintenance mode,
  only AppAPI commands are loaded"*.

That second point is the trap: a configuration run during maintenance mode
fails on every single setting. If those calls are written as
`occ ... >/dev/null 2>&1 || true`, the run looks **identical to success** while
applying nothing at all. Check the flag before applying settings, and count
failures rather than swallowing them:

```bash
occ config:system:get maintenance      # true => clear it first
occ status | grep needsDbUpgrade       # false => safe to clear
occ maintenance:mode --off
```

Order matters: finish any pending schema upgrade first, then clear maintenance
mode, then apply settings. `_nextcloud_apply_occ` does exactly this.

**Related, pulling an image puts the DB behind the code.** After any Nextcloud
image update, `needsDbUpgrade: true` until `occ upgrade` runs, and occ refuses
most commands meanwhile. `corex manage update` does not run it, so a plain
image update leaves the instance in a degraded, quietly-limited state.

### 21. TLS-ALPN-01 cannot work behind a residential ISP: use DNS-01

CoreX's premise is "no router configuration" via Cloudflare Tunnel, but Traefik
was configured with `tlsChallenge: {}` (TLS-ALPN-01), which **requires Let's
Encrypt to reach port 443 from the internet**. Most residential ISPs block
80/443 inbound, and CGNAT makes it impossible regardless. Measured on a real
line: both 80 and 443 blocked inbound, so ACME could never succeed.

The failure is confusing rather than obvious:

1. No certificate is ever issued, so `acme.json` stays empty.
2. Traefik falls back to its built-in `CN=TRAEFIK DEFAULT CERT` placeholder and
   every browser shows `ERR_CERT_AUTHORITY_INVALID`.
3. Retries burn Let's Encrypt's limit of **5 failed authorizations per hostname
   per hour**, after which it returns `429 rateLimited`, which reads like a
   completely different problem.

**DNS-01 needs no inbound connectivity**: Traefik proves domain control by
writing a TXT record through the Cloudflare API. It also supports wildcards.
Set `CLOUDFLARE_DNS_API_TOKEN` (Cloudflare → My Profile → API Tokens → "Edit
zone DNS" template, scoped to the zone) and `_traefik_write_configs` selects
`dnsChallenge` automatically; the token reaches Traefik as `CF_DNS_API_TOKEN`.

**The token has to be persisted, or repair undoes all of this.** It used to
live only in the environment of whoever ran the command, and repair
regenerates `traefik.yml` unconditionally (gotcha #22), so a repair without
`CLOUDFLARE_DNS_API_TOKEN` exported rewrote the resolver back to
`tlsChallenge` and restored the wildcard `defaultCertificate`. Certificates
already in `acme.json` carry on being served, so nothing looks wrong until a
**new** hostname is added: that one alone gets the self-signed CoreX CA and a
browser warning. `_traefik_cf_token` now resolves from the environment, then
`${DOCKER_ROOT}/traefik/.cf-dns-token` (0600), then the running compose file,
persisting forward each time, the same way `_cloudflared_token` does.

### 22. Generated config files must be regenerated on repair, not "if missing"

`traefik.yml` was written only by deploy, and `dynamic.yml` only when absent,
so neither ever changed on an existing install. A months-old `dynamic.yml` was
found still pointing `defaultCertificate` at `/certs/${DOMAIN}.crt` from an
earlier naming scheme. That file no longer existed, so Traefik silently ignored
the store and served its placeholder cert, the CoreX CA wildcard was never
presented at all, despite being generated correctly.

The same trap as gotcha #19 for compose files. **Anything CoreX generates is
not user data, regenerate it unconditionally on repair.** Guard with
`if [[ ! -f ... ]]` only for genuine user state.

Diagnose with:

```bash
echo | openssl s_client -connect SERVER_IP:443 -servername sub.DOMAIN 2>/dev/null \
  | openssl x509 -noout -issuer
# "CN=TRAEFIK DEFAULT CERT" => the default cert store is not loading
```

### 25. Thermal recovery must be reachable, and must be gradual

Two faults in the guardian, both silent, both observed on the same machine.

**An absolute recover threshold can sit below the machine's idle floor.**
Recovery only ran when the temperature reached `THERMAL_RECOVER_C` (72C). The
box idles at 79C to 84C, so the guardian shed 24 containers and then waited
for a temperature the hardware never reaches. Half the services were down
indefinitely, with nothing in any log to say why, because from the guardian's
point of view it was still too hot. Recovery now also runs in the `normal`
band, meaning anything below `THERMAL_WARN_C`, with the gap to
`THERMAL_SHED_C` and `THERMAL_CONFIRM_SAMPLES` supplying the hysteresis.

**Restoring the whole shed list at once re-triggers the shed.** Measured while
bringing containers back by hand, three at a time:

| Started | Tctl |
|---|---|
| nextcloud-db, nextcloud-redis | 92.9C |
| nextcloud, nextcloud-cron, nextcloud-whiteboard | 96.2C |
| immich-db, immich-redis | 96.2C |

From 79C to 96.2C in under two minutes, one degree below
`THERMAL_EMERGENCY_C`. `restore` now restarts at most
`THERMAL_RESTORE_BATCH` containers per cycle (six in the `recover` band), so
each step is followed by a fresh sample.

The wider point is that those numbers are a cooling verdict, not a tuning
problem. A machine that reaches 96C from starting five containers cannot host
the workload, and no amount of shedding logic changes that.

### 23. Stalwart bans the reverse proxy, not the scanner

Stalwart auto-bans an IP that probes scanner paths. Behind a proxy it sees the
**proxy's container IP**, so one bot request is enough to kill external access
entirely:

```
Banned due to scan (security.scan-ban) remoteIp=172.18.0.11 path="//wp-content/.env"
```

`172.18.0.11` was cloudflared. Every subsequent tunnel request was refused with
`EOF`, Cloudflare returned 502, and the failure looked like a routing problem:
the ingress rule was correct, the container was `Up (healthy)`, and the **LAN
path kept working** because Traefik had a different container IP
(`172.18.0.5`). Diagnosing it from the tunnel side is impossible, only
`docker logs stalwart` names the cause.

Two settings fix it properly, and both need a configured store, so they can
only be applied **after** initial setup:

| Setting | Value | Why |
|---|---|---|
| `proxyTrustedNetworks` | `172.16.0.0/12` | trust the Docker network as a proxy |
| `useXForwarded` | `true` | ban the real client, not the proxy |

Do not try to set these through environment variables, `stalwart-cli` is not
in the image and the settings live in the store, not in env (the same trap as
gotcha #3). Restarting the container clears the in-memory ban list, which is
the only interim remedy; `corex manage repair stalwart` does that and says so.

**Also: a running Stalwart container proves nothing.** It reported `HEALTHY`
throughout the outage above. `stalwart_status` now returns `UNHEALTHY` when a
proxy IP is banned or when the server is still in bootstrap mode
(`server.bootstrap-mode` in the log, no config file was ever written, so
nothing persists and mail cannot flow).

### 24. state.json must never hold a credential

`state.json` is mode 0644 and bind-mounted read-only into the dashboard
container, so anything in it is readable by a web-facing service. It held
`cloudflare_tunnel_token` for several releases.

The mode is not optional: the dashboard runs as `nobody`, and at 0600 it read
nothing and rendered **"No services installed" on a box running 36
containers**, because `loadState` discarded the read error. Two rules follow:

- `state_set` refuses secret-looking keys (`token`, `secret`, `password`,
  `key`, `credential`) rather than trusting callers. Secrets go in a 0600
  dotfile beside the service, the way `.admin-password` and `.tunnel-token` do.
- Every write site re-applies 0644. `mv` from `mktemp` preserves 0600, so a
  single `state_set` silently re-broke the dashboard.

Related trap: `cloudflared_deploy` ran `docker rm -f cloudflared` **before**
checking for a token, so a repair on a box whose `state.json` had been rebuilt
destroyed the live tunnel and returned only a warning. Resolve credentials
before touching a running container, and never tear one down on a path that
can fail.

### 29. A config mounted at a path the image does not read is worse than none

`CUSTOM_SMB_CONF=true` in `mbentley/timemachine` means "the operator supplies
the whole of `/etc/samba/smb.conf`". The image then generates nothing and exits
1 if that exact path is not mounted. CoreX set the flag while bind-mounting a
partial overlay at `/etc/samba/smb-performance.conf`, which the image never
reads:

```
ERROR: CUSTOM_SMB_CONF=true but you did not bind mount a config to /etc/samba/smb.conf; exiting.
```

The container crash-looped 60 times over several hours. Three things made that
invisible:

- `restart: unless-stopped` kept restarting it, so `docker ps` showed it
  briefly `Up 12 seconds` on almost every look, which reads as healthy.
- Time Machine uses host networking and has no HTTP endpoint, so no Uptime
  Kuma monitor covered it.
- The SMB3 tuning the overlay was meant to apply had never once been in
  effect, so there was no performance regression to notice either. It looked
  like it had always worked.

Two rules follow. **An "overlay" only exists if the image documents an include
mechanism**; Samba has none, so a custom `smb.conf` has to reproduce the
image's own `[global]` block in full, including the `fruit:` settings without
which macOS does not offer the share as a backup target. And **validate
generated config against the image that will load it**, rather than assuming:

```bash
docker run --rm -v ./smb.conf:/etc/samba/smb.conf:ro \
  --entrypoint sh <image> -c "testparm -s /etc/samba/smb.conf"
```

That check also caught `socket options = ... SO_RCVBUF=2097152`, which Samba
warns about by name: setting it disables Linux TCP buffer autotuning and pins
the window, overriding the 64MB buffers `corex manage network-tune` sets.

**The general form: a restart loop on a service with no HTTP monitor is
silent.** `corex manage watchdog` exists for this class of fault. It reports a
container that is stopped while its restart policy says otherwise, one whose
restart count is climbing, and one that was OOM-killed, none of which changes
an HTTP response.

Note that both of those states are sticky and must be read as transitions, not
levels. Docker keeps the last health verdict on a stopped container forever, so
checking `Health.Status` unconditionally reported ten deliberately-stopped
Coolify containers as `unhealthy`; and `State.OOMKilled` stays true until the
container is recreated, so alerting on the flag itself alerts forever.

### 30. One privileged process beats sprinkling privilege around

The dashboard's action buttons never worked. The container runs as `nobody` and
`corex-manage.sh` calls `check_root`, so every click returned:

```
[FAIL] Run as root: sudo bash corex.sh
```

The two obvious fixes are both worse than the bug. Running a web-facing
container as root hands the host to whatever gets into it, and passwordless
sudo is the same thing with extra steps. Letting the dashboard call
`docker stop` directly is tempting, since it already has the socket, but it
breaks a different invariant: a bare `docker stop` leaves the restart policy at
`unless-stopped`, so Docker restores the container at the next boot, the
thermal guardian may restore it sooner, and the resource watchdog reports it as
a fault because nothing recorded that the stop was deliberate. `corex manage
disable` sets `restart=no` and writes `state.json`. There has to be one meaning
of "stopped".

So `lib/agent.sh` installs exactly one privileged process with a fixed list of
actions, and everything else is an unprivileged client of it:

| Component | Privilege |
|---|---|
| `corex-agent` | root, one unix socket, whitelisted actions only |
| group `corex-agent` | owns the socket at 0660; **this** is the boundary |
| `corex-bot` | its own user, whose entire privilege is that group |
| dashboard | joins the group, still runs as `nobody` |

The bearer token in each request is not the security boundary, the socket
permissions are. The token exists so that getting those permissions wrong is
not immediately fatal. Verified in that order: a user outside the group gets
`PermissionError` on connect, before any token is read.

`remove`, `replace`, `add`, `migrate` and `nuke` are absent from the whitelist
deliberately. Everything reachable is reversible, so a stolen Telegram account
cannot destroy data. Service names are validated against the modules in
`lib/services/`, never interpolated into a shell, so `traefik;rm -rf /` and
`$(id)` both come back as `unknown service`.

**Do not use `RuntimeDirectory=` for a socket a container mounts.** systemd
deletes and recreates that directory on every restart, which leaves the
container holding a bind mount of a deleted inode: the socket vanishes from the
container's view and every button fails until the container itself is
recreated. Measured by deleting `/run/corex` by hand, which reproduces it
exactly:

```
agent unreachable: dial unix /run/corex/agent.sock: connect: no such file or directory
```

Use `tmpfiles.d`, which adjusts an existing directory in place, mount the
directory rather than the socket file, and have the agent set the directory's
mode itself on every start so a cold boot does not depend on whether Docker or
systemd got there first. `corex manage agent test` checks the path from inside
the container for this reason, and names the fix.

Two smaller traps from the same work. `agent setup` used
`systemctl enable --now`, which leaves an already-running unit alone, so it
installed new code and carried on executing the old one, which is gotcha #22
again in a different costume. And a macOS `tar` had left an AppleDouble
sidecar, `lib/services/._dashboard.sh`, which matches the service-module glob
and is binary, so service discovery died on a `UnicodeDecodeError` before the
agent could start. Any code that globs a directory written by other machines
wants `errors="replace"` and a `._*` skip.

### 31. Compiling from source is the hottest thing this project does

Every service should use a published image. When one has to be built locally,
that build, not any steady-state workload, is the peak thermal load on the
machine, and this class of hardware trips at TjMax with no warning (gotcha
#17).

Measured on a Ryzen 9 5900HX mini server while building a Next.js application
from source:

| Moment | Tctl |
|---|---|
| before the build | 64C |
| mid-compile | 88C |
| exporting layers | 96.4C |

The guardian fired `CRITICAL 95C` and shed twelve containers, taking down all
of Nextcloud, all of Immich, n8n, Uptime Kuma and Time Machine. It recovered
them on its own two at a time once the build stopped, which is the system
working, but the outage was self-inflicted.

Three rules follow.

**A pre-flight temperature check is not enough on its own.** Refusing to start
above 85C is worth having, but the machine was at 64C when this began. The
build is what produced the heat, so the guardian is the real backstop and
`nice -n 19` is what lets it win.

**Two services sharing an image must not both declare a build.** Compose does
not treat that as one piece of work: BuildKit schedules both graphs at once and
compiles the same thing twice, simultaneously, which is what doubled the load
above. Give exactly one service the `build:` block, let the others reference
the image by name, and build it explicitly rather than letting
`docker compose build` walk everything:

```bash
docker compose -f "$compose" build my-db my-app
```

**Constrain the build if it cannot be avoided.** BuildKit does not accept CPU
limits, but the legacy builder does:

```bash
DOCKER_BUILDKIT=0 docker build --cpuset-cpus=0-3 ...
```

### 32. When a container will not say why it died, read its bundle

A compiled JavaScript application often validates its configuration far more
strictly than its documentation describes, and the failure arrives as a restart
loop rather than a message. The requirements are in the bundle:

```bash
docker run --rm --entrypoint node <image> -e "
  const s=require('fs').readFileSync('/app/dist/worker.mjs','utf8');
  const i=s.indexOf('SOME_ENV_NAME'); console.log(s.slice(i-200,i+600));"
```

Doing that on one service turned up five requirements absent from its README:
mandatory providers, exact numeric ranges for database pool settings enforced
by regex, an immutable build identifier that had to match the image, a header
the reverse proxy was expected to inject, and a TLS parameter order checked
with a shell glob. Each produced a crash loop, none produced an explanation.

Two design rules follow. **One database, two clients, two URLs.** Prisma pool
settings are not libpq settings, so a migration container running `psql`
rejected the application's own connection string outright with
`invalid URI query parameter: "pool_timeout"`.

**And a service with an unmet prerequisite must be parked, not started.** Left
running it restarts every few seconds, which the resource watchdog correctly
reports once a minute. Stop its containers, set `restart=no`, mark the service
disabled, and print exactly what is missing.

### 33. An app built for a platform leaves out what the platform supplied

Cal.com runs on Vercel upstream, so two things a booking tool needs come from
the platform rather than from the application. A plain `docker compose up`
has neither, and nothing reports their absence.

**Cron.** `apps/web/vercel.json` lists the schedules. The endpoints exist in
the image and answer correctly; nothing calls them. Without them scheduled
webhook triggers never fire, reminder mail for unconfirmed bookings is never
sent, and the watch subscription on a connected Google calendar expires and
stops delivering changes. Two details make this harder than adding a timer.
The routes disagree about which verb they export, so a caller has to try POST
and fall back to GET on 405, and they authenticate against two different
variables: most compare `authorization` to `CRON_API_KEY` bare, while the
tasker routes want `Bearer ${CRON_SECRET}`. The wrong one gives 401 per tick
and no other symptom.

**A notification anyone will see.** Cal.com sends webhooks; it does not send
messages. Its webhooks are per account and are created through its own UI, so
a fresh instance has none, and the first account only exists after someone
signs up. `calcom-helper` covers both jobs in one small container, and
`_calcom_register_hook` writes the webhook row once an account exists, which
is why the deploy prints "create your account, then repair".

Two smaller traps from the same work.

**A build argument is not proof that a rebuild is needed.**
`NEXT_PUBLIC_WEBAPP_URL` is a build argument, and every self-hosting guide
therefore says the image must be rebuilt for a custom domain. The Dockerfile
records the same value again as `BUILT_NEXT_PUBLIC_WEBAPP_URL`, and
`scripts/start.sh` compares the two on boot and rewrites the compiled assets
when they differ. Read the entrypoint before deciding to compile: gotcha #31
is what compiling costs on this hardware.

**Signup has to be open exactly once.** Cal.com's signup form is open by
default, which on a published hostname lets strangers create accounts, and
closing it before the first account exists locks the owner out.
`NEXT_PUBLIC_DISABLE_SIGNUP` therefore follows the account count: open at
zero, closed above it, applied on the next deploy or repair. Note where the
check lives. The variable is inlined into the client bundle at build time, so
a runtime value never reaches the page and the form may still render; the
signup API reads `process.env` and answers 403, so the refusal is real even
though the form looks available.

### 34. A warning can be the branch that keeps the behaviour correct

Cal.com logs "Match of WEBAPP_URL with ALLOWED_HOSTNAMES failed" at WARN on
every page render when `ALLOWED_HOSTNAMES` is empty, which on a busy page is
dozens of lines. Setting it to the domain silences the warning and 404s every
booking page on the instance.

`getOrgSlug` in `packages/features/ee/organizations/lib/orgDomains.ts` looks
for an entry in that list which the current hostname is a subdomain of. With
the bare domain in the list, `cal.DOMAIN` matches it, the remainder is `cal`, and
the instance decides it is serving an organization called `cal`. Every profile
lookup then happens inside that organization, so `/username` answers 404 with
"The username is still available" while the account is present in the
database, the account is an ADMIN, and onboarding is complete. The log line
was the branch that returned null and made it a plain instance.

The general shape: a warning emitted on a fallback path is documentation of
that path, not a defect. Before silencing one, find the branch it is reporting
and check what changes when the condition it complains about is satisfied. Log
volume is a rotation problem, and `/etc/logrotate.d/corex` already exists for
exactly that.

### 35. A CDN in a sovereign dashboard, and the hash that disabled every button

The dashboard loaded Tailwind from `cdn.tailwindcss.com` and htmx from
`unpkg.com`, with an `integrity` attribute on the htmx tag. That attribute was
63 characters long. A sha384 digest in base64 is 64, and the value did not
match the file either:

```
declared: sha384-SKnHeRIKhoCJXdg1ZtHNFkpUxNyTqVzE4RM6k3kh7c8oq7ZmT5hJGHrDnH5LHLT
actual:   sha384-ujb1lZYygJmzgSwoxRggbCHcjc0rB2XoQrxeTUQyRjrOnlCoYta87iKBWq3EsdM2
```

A browser refuses to execute a script that fails Subresource Integrity, and it
does so quietly: nothing renders differently, and no request fails visibly. So
htmx never loaded, every `hx-post` and `hx-get` attribute on the page was
inert, and every button did nothing. The tabs still worked, which is what made
it look like a working dashboard, because they were plain links.

Two rules follow. **Verify a hash or do not write one.** Compute it, do not
transcribe it:

```bash
curl -sL <url> | openssl dgst -sha384 -binary | openssl base64 -A
```

**And do not put a CDN in front of the page you open when the box is in
trouble.** A dashboard whose stylesheet lives on the internet is unstyled
exactly when the tunnel is down or DNS is broken, which is when it is needed.
The interface is now compiled and embedded in the binary with `go:embed`, so
the page has no runtime dependency at all.

The related trap is that the image is built locally, so **an edit to
`dashboard/` reaches nothing until the image is rebuilt.** The running
container was half an hour older than its own source for a while, which showed
up as a newly added service being absent from the dashboard with no error
anywhere. `corex manage repair dashboard` rebuilds it.

### 36. A control panel's own login is a lockout waiting to happen

The dashboard has accounts now, in `/etc/corex/dashboard-users.json` at 0600
root, with PBKDF2 passwords, RFC 6238 two-factor and a reset code mailed
through the shared relay. Basic auth could do none of that: it cannot change
its own password, recover one, or name who is signed in. Cloudflare Access
covers the same ground at the edge and is the better answer where it works,
but it is configured outside CoreX and failed here in a way CoreX could not
see, its one-time PIN reaching neither mailbox, which locks the operator out
while leaving the page published.

Four rules came out of building it, and the first is the one that matters.

**The way in from SSH is built first and never depends on the web tier.**
`corex manage dashboard-user` edits the file directly: no container, no agent,
no network. `disable-auth` puts Traefik basic auth back. The dashboard is what
you open when the box is already in trouble, so shipping a login without a
documented way past it is shipping a lockout.

**Auth fails closed, and "not configured" is not the same as "cannot tell".**
The login turns itself on the first time the store is read and has an account
in it, and that fact is remembered for the life of the process. A later read
that fails answers 503, not 200: killing the agent must not be a way past the
login. Before any account exists there is nothing to enforce, basic auth is
still in front, and the dashboard behaves exactly as it did.

**The privilege split is the same one as gotcha #30, and the mail is the part
that cannot cross it.** The container runs as `nobody`, so it reads and writes
the document through the agent's `users-get` and `users-put` and hashes in Go.
`/etc/corex/smtp.conf` is 0600 root and stays that way, so `auth-reset` has
the agent generate the code, store only its hash and send the mail. The web
tier verifies that hash later, having seen neither the code nor the relay
password.

**A hash record read by two languages is a contract, and it fails as a correct
password being refused.** `agent/corex_users.py` writes it and `dashboard/auth.go`
reads it, so every secret is stored self-describing:

```json
{"algo": "pbkdf2-sha256", "iterations": 600000, "salt": "...", "hash": "..."}
```

Neither side agrees an iteration count by convention, and a recovery code with
50 bits of its own entropy can be cheaper to check than a password without
either side knowing which it holds. `dashboard/auth_test.go` verifies a
Python-written record in Go and runs RFC 6238's published vectors, and the
image build runs it, because neither language's own tests can catch the
disagreement.

Two smaller traps. Timing tells you whether a username exists: the login path
runs a dummy PBKDF2 for an unknown user so both answers cost the same quarter
second. And an empty Traefik `middlewares` label is rejected outright, so with
the app login on and LAN-only off the chain is empty and the label has to be
left out rather than emitted blank.

### 37. A dashboard that renders reports is not a dashboard

The Storage tab opened with `[0;36m[1mCoreX Storage Report[0m`, because the
panel put a command's output in a `<pre>` and the `Ansi` component next door
went unused. Health printed the same hardware report twice. Both were a
monospace wall a reader had to parse to find out whether anything was wrong.

Showing a command's own output is right for a command someone ran: those
commands are the source of truth for the CLI too, and a paraphrase is a second
place for the answer to be wrong. It is not right for a temperature, a disk
percentage or a two-hour trend. Those are numbers, and a number rendered as
text in a fixed-width font is a number nobody reads.

**The history was already being collected.** `blackbox.log` records
temperature, load, memory, swap, throttling and container count every twenty
seconds because it is the only evidence that survives an unclean shutdown
(gotcha #16). That is a time series, so the graphs read it rather than adding
a second sampler. Two hours is 360 samples, which is the window that answers
"what happened just before it got hot".

**Host numbers have to come from the agent.** The container sees its own
filesystem, so `df` in there measures the wrong thing entirely. Bind-mounting
`/mnt/corex-data` to fix that would hand a web-facing container Vaultwarden's
vault, Immich's photos and the Telegram bot token inside Kuma's `notification`
table. `corex_metrics.py` runs privileged and returns numbers; its Kuma reader
takes monitor names and heartbeats and never opens that table. `du` is cached
for fifteen minutes and computed in a background thread, because walking a
photo library takes far longer than a dashboard poll should.

**A nil slice is not an empty array.** `var urls []string` marshals to JSON
`null`, the client typed it `string[]`, and `svc.urls.length` threw into the
error boundary, so one service with no browsable address blanked every tab.
Any field the client types as an array has to leave Go as one.

**And the check that existed to catch a blank page could not see it.**
`render-check.mjs` failed every fetch, so each tab rendered its error state and
not one service card was ever constructed. It now runs every tab twice, against
fixtures shaped like the real responses and with the server down, and the
fixtures carry the awkward cases on purpose: a null `urls`, a disk at 94%, a
monitor that is down. When changing it, put a bug back and confirm it fails.

### 38. Parse a log line against real logs, or not at all

Container logs were one undifferentiated block, so the error you opened the
dialog to find read exactly like the two hundred routine lines around it. They
are parsed now, and every fault in the first parser was invisible until it ran
against lines this box actually emits:

| Line | What went wrong |
|---|---|
| Traefik `WRN` | the level pattern knew `WARNING` and `WARN`, so every warning read as no level |
| `[03/Sep/2026:18:09:57 +0000]` | taking the first `HH:MM:SS` gave `26:18:09`, out of the middle of the year |
| the same line, after removal | the pattern matched the date but not its brackets, leaving a bare `[]` |
| `[MONITOR] WARN: ...` | a generic leading-bracket strip made it `MONITOR] WARN: ...` |

None of that is visible to a type check or to a render check, because the
output is still a string and the page still draws it. Each timestamp pattern
now removes itself and its own delimiters, anything unrecognised is passed
through untouched, and `logline-check.mjs` runs in the build over shapes taken
off the running box. One case matters in the other direction: the word "error"
inside a URL must not paint a routine request red.

### 39. Count failures, not attempts, and know who the caller is

Two rate-limiting faults in the dashboard's login, both of which look like
working code.

**Counting successful sign-ins locks out the person you are protecting.** Five
attempts per quarter hour includes the phone, the laptop and the tab already
open, so an operator who has done nothing wrong is shut out of their own
control panel for fifteen minutes. Only failures count now, and a correct
password forgives the bucket.

**Behind the tunnel, every visitor is the same address.** Traefik replaces
`X-Forwarded-For` with its own peer unless told to trust the sender, so the
first login from outside logged `signed in from 172.18.0.7`, which is
cloudflared. Everyone on the internet then shared one bucket. That was never a
way in, because the per-username and global buckets still held; it was a way
to deny the way in, since one attacker guessing at any name could spend the
whole allowance. `Cf-Connecting-Ip` is read first.

Both headers are only as good as the hop that set them, and anything reaching
the container directly on proxy-net can forge either. That is why every limit
that matters keeps a second bucket keyed on something the caller does not
choose: the username, or a global ceiling.

### 40. A notification is read on a lock screen, so write it for one

Every message this box sends was a log line pointed at a person. "temp DOWN:
83C, over the 80C limit" is a grep target, not news, and "restart nextcloud" is
the command that was run rather than what happened. A phone shows two lines and
then stops, so the first one has to carry the whole point.

`corex_common.message()` is now the only way a message is built, so the bot,
the job notices and the Kuma alerts share one shape: a headline in plain words,
the detail, then the single next step if there is one. "Running hot at 83C,
above the 80C limit". "nextcloud has restarted". "Killed for using too much
memory, so the limit is set too low".

**Do not get clever with the Kuma template.** Telegram rejects a message whose
MarkdownV2 does not parse, and Kuma logs that as a 400 and moves on, so a
template that breaks on one monitor name containing a hyphen silently turns off
alerting for that monitor. The template stays close to the default and the
wording that carries weight lives in `msg`, which Kuma escapes for us.

Two facts to check rather than assume, both of which were wrong when taken from
documentation and right when read from the running container:

- The template context is `status`, `name`, `hostnameOrURL`, `msg`,
  `monitorJSON` and `heartbeatJSON`. There is no `heartbeat` object and no
  `localDateTime`, so a footer using one renders empty.
- `hostnameOrURL` on a push monitor is the push URL, which carries the token.
  Never put it in a message.

Render a template change through the running Kuma's own engine before shipping:

```bash
docker exec uptime-kuma node -e '
  const { Liquid } = require("/app/node_modules/liquidjs");
  const e = new Liquid({ root: "./no-such-directory-uptime-kuma", relativeReference: false });
  console.log(e.renderSync(e.parse(TEMPLATE), { status: "🔴 Down", name: "X", msg: "y", heartbeatJSON: { status: 0 } }));'
```

**And the template only reaches a phone if it is applied to an existing
install.** `apply_telegram_template` skipped any notification that already had
one, which reads as politeness and is gotcha #22 again: the better wording
shipped in the repository and changed nothing on the box that needed it. Every
template CoreX has written is listed and upgraded; anything else is left alone.
It lives in `lib/watchdog.sh`, so `corex manage watchdog setup` applies it, not
`kuma-seed`.

### 41. Poll the slow half, stream the fast half

The overview was one poll every twenty seconds, which made a temperature up to
twenty seconds old on hardware whose failure mode is a thermal trip with no log
entry. Streaming all of it was not the answer either: the full payload walks
both disks, reads Kuma's database and can wait on a `du` over a photo library.

So it is split. `/api/stream/vitals` pushes temperature, load, memory,
container counts and the heaviest containers every five seconds over SSE, with
`sizes:false` so the agent skips the cached `du` entirely. `/api/overview`
polls the rest more slowly. The page prefers the streamed number wherever it
has one.

Five seconds is close to the floor: `docker stats --no-stream` costs a full
sampling interval per call, so asking much faster spends more time measuring
than waiting. SSE rather than a websocket because the traffic is one way, it
crosses the reverse proxy without an upgrade negotiation, and the browser
reconnects on its own. `X-Accel-Buffering: no` is not optional; without it an
intermediate proxy buffers the stream and nothing arrives until it closes,
which looks exactly like a hung page.

**A number tells you there is a problem, not whose it is.** Every vital is a
button that opens the sorted list of what is consuming it, which is what
Activity Monitor and Task Manager are for. A dashboard that only shows totals
makes the reader open a terminal to find the cause, and then the dashboard was
not the answer.

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

8. **DO NOT use `docker volume prune`**, it destroys ALL unnamed volumes
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

### 4. Frontend checks that run in the build
```bash
cd dashboard/web && npm run build
```
`tsc`, then `vite build`, then three checks. `logline-check.mjs` parses log
lines taken off a running box. `responsive-check.mjs` holds four small-screen
rules, each one a mistake that was in the tree. `render-check.mjs` mounts every
tab three times: against fixtures, with every fetch failing, and at 360px. All
three were added after a bug they should have caught, which is the only honest
reason to add a check: see gotchas #37 and #38.

### 5. Dashboard login, end to end (needs Docker)
```bash
./test/e2e/dashboard-auth.sh
```
Runs the real Go binary against a stand-in agent and drives every path that has
to refuse: a wrong password, an unknown user, a half-completed second factor, a
spent recovery code, a replayed reset code, and an unreachable user store. A
login that is subtly wrong looks exactly like one that works, so this is the
check that has to exist.

### 6. Full integration test (Docker-in-Docker)
```bash
docker run --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e COREX_NON_INTERACTIVE=1 \
  -e TEST_DOMAIN=test.example.com \
  -e TEST_IP=192.168.1.100 \
  corex-test bash install-corex-master.sh
```

### 7. Compose validation on live server (read-only, safe)
```bash
cd /mnt/corex-data/docker-configs/<service>
docker compose config   # Validates and prints resolved compose file
```

### 8. Dry-run mode
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
                                   # NOTE: also drives thermal shed order — see gotcha #17
SERVICE_REQUIRED=false             # true = always installed, not user-selectable
SERVICE_NEEDS_DOMAIN=true          # false = works in local-only mode too
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=512
SERVICE_DISK_GB=5
SERVICE_DESCRIPTION="Run your own Git server. Push code, manage repos, CI/CD — fully private."

# Uptime Kuma reachability checks this module wants, one per line, tab
# separated as name, url, accepted status codes. Seeded by lib/kuma.sh and
# matched by NAME, so renaming one later creates a second monitor and orphans
# the first. Omit it and the module is simply not checked over HTTP.
SERVICE_MONITORS="Gitea\thttps://git.${DOMAIN:-}\t[\"200-299\"]"

# Functions (auto-called by installer and manage commands)
gitea_dirs()        { ... }    # Create dirs with correct ownership
gitea_firewall()    { ... }    # Add UFW rules if needed
gitea_deploy()      { ... }    # Write compose heredoc + docker compose up -d
gitea_destroy()     { ... }    # docker compose down + optional rm -rf data
gitea_status()      { ... }    # Return: HEALTHY | UNHEALTHY | MISSING
gitea_repair()      { ... }    # docker compose up -d --force-recreate (no data loss)
gitea_credentials() { ... }    # Print credential lines for summary doc
```

Drop this file in `lib/services/`, it automatically appears in wizard,
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
3. Implement `_dirs()`, create directories with correct ownership
4. Implement `_firewall()`, add UFW rules if needed
5. Implement `_deploy()`, write compose heredoc + `docker compose up -d` + `state_service_installed`
6. Implement `_status()` and `_repair()` for doctor command support
7. Implement `_credentials()` for the summary doc
8. Declare `SERVICE_MONITORS` if it answers on a hostname, so it is checked
9. Run smoke test to validate compose generation
10. Update this `CLAUDE.md`, add service to dependency map and network table
11. Update `CHANGELOG.md` with the new service under the next version

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
- `state_init`: create fresh state file
- `state_get "field"`: read a value
- `state_set "field" "value"`: write a value
- `state_service_installed "name"`: mark service installed
- `state_service_is_installed "name"`: returns 0 if installed
- `state_list_installed`: list all installed service names

---

## Version History Notes

- **v0.1.0** (2026-02-09): Proof of concept
- **v1.0.0** (2026-02-10): Initial release. Monolithic single-file installer. 14 services + Restic backups.
- **v1.1.0** (2026-02-11): Fixed Time Machine env var (PASSWORD not TM_PASSWORD), moved TM data to shared pool, added `corex.sh` CLI, `nuke-corex.sh`, `migrate-domain.sh`, curl-pipe detection, BASH_SOURCE detection.
- **v2.0.0** (2026-02-21): Modular lib/ structure, wizard, state.json, corex-manage, corex doctor, plugin extensibility. 1,865-line monolith replaced by ~200-line orchestrator + lib/ modules.
- **v2.0.1** (2026-02-22): Fixed `corex doctor` on v1 installs, auto-migrates state from `docker ps` when `state.json` is missing.
- **v2.1.0** (2026-03-01): Added `corex manage lan-setup`, automates AdGuard DNS wildcard rewrite via REST API; prints router/device DNS instructions. Eliminates the manual post-install AdGuard step.
- **v2.1.1** (2026-03-02): Fixed `lan-setup` HTTP 400, v1 migration regex captured YAML quotes around email field, storing domain with embedded quotes in state.json. Fixed at root (migration strips quotes) and defensively in `_load_config()` via `tr -d '"'`.
- **v2.2.0** (2026-03-06): Network performance tuning + security hardening. Added `corex manage network-tune` command. Kernel params expanded from 14 to 50+ (BBR, 64MB TCP buffers, TCP Fast Open, MTU probing). Time Machine rebuilt with high-performance SMB3 (multichannel, 8MB chunks, async I/O, sendfile). SSH hardened with modern ciphers only (ChaCha20/AES-GCM, curve25519 KEX). Fail2ban upgraded to 3-jail system (standard + aggressive + recidive for 30-day repeat-offender bans).
- **v2.3.0** (2026-03-07): Traefik upgraded v3.0→v3.6 (Docker Engine 29+ broke API v1.24 negotiation, v3.6 adds auto-negotiation). Nextcloud LAN transfer performance fix (KB/s → MB/s). PHP output_buffering=Off, OPcache+JIT, APCu local cache, Apache mod_deflate bypass for binary files, mod_reqtimeout unlimited body, MariaDB innodb tuning (256M buffer pool, O_DIRECT), Traefik unlimited read/write timeouts, CalDAV/CardDAV middleware, HSTS headers. Repair command regenerates perf configs.
- **v2.4.0** (2026-03-07): LAN fast-path hardened against 5 browser bypass layers. Self-signed CA + wildcard cert auto-generated by Traefik (file provider + dynamic.yml). SVCB/HTTPS DNS record blocking via AdGuard filtering rules. `lan-setup` expanded with browser config (Chrome QUIC/DNS policies), IPv6 disable instructions, CA trust instructions per platform. Nextcloud max_chunk_size set to 10MB for Cloudflare compatibility. Secondary DNS warnings added.
- **v2.4.1** (2026-03-07): Fixed Nextcloud "Unknown error during upload", APACHE_BODY_LIMIT=0, .htaccess patching, gosu for occ commands, JIT disabled. Added MariaDB/Redis health checks, cron container, security headers.
- **v2.4.2** (2026-03-09): Added HEVC video streaming via Memories app (internal go-vod + ffmpeg). iPhone .mov files now play in Chrome/Firefox via on-demand HLS transcoding. Memories v7+ ships its own go-vod binary, no external container needed. Fixed CalDAV `$$1` interpolation bug. Extracted `_nextcloud_write_compose()` helper so repair regenerates compose files.
