<p align="center">
  <img src="https://img.shields.io/badge/CoreX_Pro-v2.1.1-blue?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Version">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">
  CoreX Pro - Sovereign Hybrid Homelab
</h1>

<p align="center">
  <strong>"Brains on System. Muscle on SSD."</strong><br>
  One command. Choose your services. Zero cloud dependency. Full data sovereignty.
</p>

<p align="center">
  <a href="#-quickstart">Quickstart</a> •
  <a href="#-what-you-get">What You Get</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-services--use-cases">Services</a> •
  <a href="#-post-install-guide">Post-Install</a> •
  <a href="#-managing-services">Managing Services</a> •
  <a href="#-backup--restore">Backup</a> •
  <a href="#-uninstall--rollback">Uninstall</a> •
  <a href="#-troubleshooting">Troubleshooting</a>
</p>

---

## 🤔 Why CoreX Pro?

You use Google Drive, Google Photos, Gmail, Bitwarden, Zapier, Vercel, ChatGPT, and a dozen other cloud services. You pay monthly for each, your data lives on someone else's servers, and you're one policy change away from losing access to your own files.

CoreX Pro replaces all of them with self-hosted alternatives running on a single machine in your home. One command sets up everything — encrypted, backed up, accessible from anywhere via Cloudflare Tunnel. You choose exactly which services to install.

**Who is this for?**

- Developers who want a home server but don't want to spend weeks configuring it
- Privacy-conscious users who want to own their data
- Small teams that need shared infrastructure without SaaS costs
- Tinkerers who want a solid foundation to build on

**What you need:**

- A machine running **Ubuntu 24.04 LTS Server** (mini PC, old laptop, NUC, or dedicated server)
- **8GB+ RAM** (16GB recommended for AI services)
- An **external SSD** (500GB minimum, 1TB recommended)
- A **domain name** with DNS managed via Cloudflare (free tier works) — or run in local-only mode without one

---

## ⚡ Quickstart

### One-Line Install (fresh server)

```bash
curl -fsSL https://raw.githubusercontent.com/itismowgli/corex-pro/main/corex.sh | sudo bash
```

This downloads CoreX Pro, launches an **interactive wizard**, and lets you choose exactly which services to install. Takes about 10–15 minutes depending on your internet speed.

### Manual Install

```bash
git clone https://github.com/itismowgli/corex-pro.git
cd corex-pro
sudo bash corex.sh install
```

### Interactive Menu (recommended for day-to-day use)

```bash
sudo bash corex.sh          # Shows context-aware menu
```

The menu auto-detects whether CoreX is installed and shows relevant options.

### All Commands

```bash
sudo bash corex.sh install              # Install (interactive wizard)
sudo bash corex.sh doctor               # Health check + auto-repair all services
sudo bash corex.sh manage status        # Live status dashboard
sudo bash corex.sh manage add <svc>     # Add a service you skipped during install
sudo bash corex.sh manage lan-setup     # Configure LAN fast-path (full-speed local transfers)
sudo bash corex.sh update               # Pull latest CoreX Pro version
sudo bash corex.sh migrate              # Change domain across all services
sudo bash corex.sh nuke                 # Uninstall / rollback
sudo bash corex.sh help                 # Full command reference
```

After install, credentials are at `/root/corex-credentials.txt` and a full guide at `/root/CoreX_Dashboard_Credentials.md`.

---

## 📦 What You Get

| Replaces               | With                     | Why Self-Host?                                                 |
| ---------------------- | ------------------------ | -------------------------------------------------------------- |
| Google Drive / Dropbox | **Nextcloud**            | Unlimited storage, no monthly fees, your encryption keys       |
| Google Photos / iCloud | **Immich**               | Face recognition, ML search, no storage limits, no AI training |
| Gmail / Outlook        | **Stalwart Mail**        | Full email server, no scanning, custom domain                  |
| Bitwarden / 1Password  | **Vaultwarden**          | Zero-knowledge passwords, family sharing, free                 |
| Zapier / Make          | **n8n**                  | Unlimited automations, no per-task pricing                     |
| Vercel / Netlify       | **Coolify**              | Deploy any app, no vendor lock-in                              |
| ChatGPT / Claude API   | **Ollama + Open WebUI**  | Local LLMs, zero API costs, full privacy                       |
| Time Machine + NAS     | **SMB via Docker**       | Encrypted macOS backups to your own hardware                   |
| UptimeRobot            | **Uptime Kuma**          | Beautiful status pages, unlimited monitors                     |
| Datadog / New Relic    | **Grafana + Prometheus** | Full observability, no per-host pricing                        |
| Cloudflare Access      | **Cloudflare Tunnel**    | Zero port-forwarding, encrypted tunnel                         |
| Pi-hole                | **AdGuard Home**         | DNS-level ad blocking + DNS rewrites for local routing         |

---

## 🏗 Architecture

```
┌─ INTERNET ──────────────────────────────────────────────────┐
│  Cloudflare Tunnel (encrypted, zero port-forwarding)         │
├─ SECURITY ──────────────────────────────────────────────────┤
│  UFW → CrowdSec (community IPS) → Fail2ban (SSH jail)       │
│  SSH on custom port + kernel hardening + auto-updates        │
├─ DNS & ROUTING ─────────────────────────────────────────────┤
│  AdGuard Home (DNS + ad blocking + local DNS rewrites)       │
│  Traefik v3 (HTTPS termination, Let's Encrypt, auto-certs)  │
├─ SERVICES ──────────────────────────────────────────────────┤
│  14 optional Docker containers on isolated networks          │
│  You choose which ones to install — nothing forced           │
├─ BACKUP ────────────────────────────────────────────────────┤
│  Restic (encrypted, deduplicated, daily at 3AM)              │
├─ STORAGE ───────────────────────────────────────────────────┤
│  Local Disk: OS + Docker Engine (the "Brain")                │
│  External SSD: All data, configs, backups (the "Muscle")     │
└─────────────────────────────────────────────────────────────┘
```

### Network Isolation

Services are deployed across three isolated Docker networks:

- **`proxy-net`** - All web-facing services + Traefik + Cloudflare Tunnel
- **`monitoring-net`** - Prometheus + Grafana + exporters (no internet access)
- **`ai-net`** - Ollama + Open WebUI + Browserless (sandboxed)

### Storage Strategy

CoreX separates the "brain" (OS + Docker engine on local disk) from the "muscle" (all data on external SSD). This means:

- **Fast boot**: OS disk is lean, no large data volumes
- **Easy migration**: Unplug SSD, plug into new machine, restore
- **Clean backups**: Everything worth backing up is on one mount point
- **SSD failure isolation**: OS survives if SSD dies, and vice versa

```
External SSD (/dev/sdX)
├── Partition 1 (optional) → /mnt/timemachine   # macOS Time Machine
└── Partition 2            → /mnt/corex-data    # Everything else
    ├── docker-configs/                          # docker-compose.yml per service
    │   ├── traefik/
    │   ├── nextcloud/
    │   ├── immich/
    │   └── ...
    ├── service-data/                            # Persistent data
    │   ├── nextcloud-html/
    │   ├── immich-upload/
    │   ├── vaultwarden/
    │   ├── ollama/          # Downloaded LLM models
    │   └── ...
    └── backups/
        └── restic-repo/                         # Encrypted backup snapshots
```

### Plugin-Style Extensibility

Every service is a self-contained module in `lib/services/`. Adding a new service to CoreX requires only dropping one file:

```
lib/services/gitea.sh    ← drop this file, that's it
```

The wizard, `corex doctor`, and `corex manage` automatically discover and support it. No changes to any other file required.

---

## 🧰 Services & Use Cases

### 🔀 Traefik - Reverse Proxy & TLS

**What:** Automatic HTTPS for all services. Routes `*.yourdomain.com` to the right container.

**How it works:** Watches Docker socket for containers with `traefik.enable=true` labels, automatically creates routes, gets Let's Encrypt certificates via TLS-ALPN-01 challenge.

**Access:** `http://YOUR_IP:8080` (dashboard)

---

### 🛡 AdGuard Home - DNS & Ad Blocking

**What:** Network-wide DNS server that blocks ads, trackers, and malware domains. Also serves as your local DNS for routing `*.yourdomain.com` directly to your server's LAN IP — bypassing Cloudflare for full-speed local transfers.

**LAN fast-path setup (automated):**
```bash
sudo bash corex.sh manage lan-setup
```
Automatically adds the wildcard DNS rewrite `*.yourdomain.com → SERVER_IP` via the AdGuard API and prints per-device/router DNS configuration instructions.

**Access:** `http://YOUR_IP:3000`

---

### 🐳 Portainer - Docker Management

**What:** Web UI for managing Docker containers, images, volumes, and networks. View logs, restart services, monitor resources — all from a browser.

**Access:** `https://YOUR_IP:9443`

---

### ☁️ Nextcloud - File Storage & Sync

**What:** Self-hosted Google Drive / Dropbox. File sync, calendar, contacts, notes, video calls, kanban boards.

**Apps to install after setup:** Calendar, Contacts, Notes, Talk, Deck, Bookmarks

**Access:** `https://nextcloud.yourdomain.com`

---

### 📸 Immich - Photo & Video Management

**What:** Self-hosted Google Photos. AI-powered face recognition, smart search, automatic mobile backup. Downloads ~1GB of ML models on first start.

**Access:** `https://photos.yourdomain.com`
**Mobile:** [iOS](https://apps.apple.com/app/immich/id1613945652) / [Android](https://play.google.com/store/apps/details?id=app.alextran.immich)

---

### 🔐 Vaultwarden - Password Manager

**What:** Lightweight, self-hosted Bitwarden server. Works with all official Bitwarden clients.

**Important:** Disable signups after creating your accounts (`SIGNUPS_ALLOWED: "false"`).

**Access:** `https://vault.yourdomain.com` / Admin: `https://vault.yourdomain.com/admin`

---

### ✉️ Stalwart Mail - Email Server

**What:** All-in-one email server: SMTP, IMAP, CalDAV, CardDAV. Written in Rust. Admin credentials auto-captured from first-boot logs.

**Note:** Self-hosted email has deliverability challenges. Consider an SMTP relay (SMTP2GO, Mailgun free tier) for outbound mail.

**Access:** `https://mail.yourdomain.com`
**Ports:** 25 (SMTP), 587 (Submission), 465 (SMTPS), 143 (IMAP), 993 (IMAPS)

---

### 🚀 Coolify - Web Hosting PaaS

**What:** Self-hosted Vercel / Netlify / Heroku. Deploy web apps with git push, managed databases, preview deployments.

**Note:** Installs via a helper script (separate from CoreX Traefik to avoid port conflicts).

**Access:** `http://YOUR_IP:8000`

---

### ⚡ n8n - Workflow Automation

**What:** Self-hosted Zapier / Make.com. Visual workflow builder with 400+ integrations. AI agent workflows work with Ollama.

**Access:** `https://n8n.yourdomain.com`

---

### 💾 Time Machine - macOS Backups

**What:** Network Time Machine server via SMB. Your Mac backs up automatically over Wi-Fi.

**Access:** `smb://YOUR_IP/CoreX_Backup` or auto-discovered in System Settings → Time Machine.

---

### 📊 Uptime Kuma + Grafana + Prometheus - Monitoring

**What:** Uptime Kuma for status pages and alerting (email, Slack, Discord, Telegram) + Grafana + Prometheus for full metrics and dashboards.

**Quick start:** Import Grafana dashboard ID `1860` (Node Exporter Full).

**Access:** Status at `https://status.yourdomain.com` / Grafana at `https://grafana.yourdomain.com`

---

### 🤖 AI Stack - Ollama + Open WebUI + Browserless

**What:** Run LLMs locally with a ChatGPT-like interface + headless Chrome for AI agents. `llama3.2:3b` is pulled automatically.

**Recommended models:**

- `llama3.2:3b` — Fast, good for chat (3GB RAM)
- `mistral:7b` — Balanced quality/speed (7GB RAM)
- `codellama:7b` — Coding assistant (7GB RAM)

**Access:** Chat at `https://ai.yourdomain.com` / Ollama API at `http://YOUR_IP:11434`

---

### 🛡 CrowdSec - Community IPS

**What:** Community-powered intrusion prevention. Detects brute force, CVE exploits, and bot abuse. Shares threat intel globally — you block attackers before they target you.

```bash
docker exec crowdsec cscli decisions list    # View blocked IPs
docker exec crowdsec cscli metrics           # View detection stats
```

---

### 🔒 Cloudflare Tunnel - Secure External Access

**What:** Encrypted tunnel from Cloudflare's edge to your server. Zero port forwarding required. DDoS protection and WAF included.

**Critical:** In CF Dashboard → Tunnels → Public Hostnames, use **container names** (e.g., `n8n:5678`), not `localhost`.

---

## 📋 Post-Install Guide

After the script completes, follow these steps **in order**:

### 1. AdGuard Home (DNS) - Do This First

1. Open `http://YOUR_IP:3000` and complete the setup wizard
2. Run the automated LAN fast-path setup — it adds the wildcard DNS rewrite and prints router/device instructions:
   ```bash
   sudo bash corex.sh manage lan-setup
   ```
3. Set your **router's primary DNS to `YOUR_IP`** (printed at the end of `lan-setup`)
4. Now all `*.yourdomain.com` lookups from LAN devices resolve to your server — file uploads, photo syncs, and vault access all stay on the local network at full speed, bypassing Cloudflare entirely

### 2. Cloudflare Tunnel (External Access)

In [Cloudflare Dashboard](https://one.dash.cloudflare.com) → Networks → Tunnels → Public Hostnames, add:

| Hostname                   | Service | URL                  |
| -------------------------- | ------- | -------------------- |
| `photos.yourdomain.com`    | HTTP    | `immich-server:2283` |
| `nextcloud.yourdomain.com` | HTTP    | `nextcloud:80`       |
| `vault.yourdomain.com`     | HTTP    | `vaultwarden:80`     |
| `n8n.yourdomain.com`       | HTTP    | `n8n:5678`           |
| `mail.yourdomain.com`      | HTTP    | `stalwart:8080`      |
| `status.yourdomain.com`    | HTTP    | `uptime-kuma:3001`   |
| `grafana.yourdomain.com`   | HTTP    | `grafana:3000`       |
| `ai.yourdomain.com`        | HTTP    | `open-webui:8080`    |

> ⚠️ Use **container names**, not `localhost`. Cloudflared runs inside Docker on `proxy-net`. Enable **No TLS Verify** under each hostname's TLS settings.

### 3. Create Admin Accounts

Open each service immediately — the first visitor becomes admin:

- Portainer: `https://YOUR_IP:9443`
- Nextcloud: `https://nextcloud.yourdomain.com`
- Immich: `https://photos.yourdomain.com`
- Vaultwarden: `https://vault.yourdomain.com`
- n8n: `https://n8n.yourdomain.com`
- Uptime Kuma: `https://status.yourdomain.com`
- Open WebUI: `https://ai.yourdomain.com`

### 4. View All Credentials

```bash
cat /root/corex-credentials.txt           # Quick reference
cat /root/CoreX_Dashboard_Credentials.md  # Full guide with every URL and setup instruction
```

---

## 🔧 Managing Services

v2.0.0 introduced full post-install service management. v2.1.0 added LAN fast-path automation. No need to re-run the installer to add, fix, or configure services.

### Health Check & Auto-Repair

```bash
sudo bash corex.sh doctor
```

Checks every installed service and automatically repairs any that are unhealthy — without touching data.

```
CoreX Pro — Service Health
────────────────────────────────────────────────────
  SERVICE          STATUS       ACTION
  ──────────────────────────────────────────────────
  traefik          HEALTHY
  nextcloud        HEALTHY
  immich           UNHEALTHY    → auto-repairing...
  vaultwarden      HEALTHY
  n8n              MISSING      → run: corex manage add n8n
```

### Add / Remove Services

```bash
sudo bash corex.sh manage add stalwart      # Add a service skipped during install
sudo bash corex.sh manage add ai            # Add the full AI stack
sudo bash corex.sh manage remove n8n        # Remove (prompts about data deletion)
sudo bash corex.sh manage list              # List all installed + available services
```

### Update Container Images

```bash
sudo bash corex.sh manage update --all      # Update all installed services
sudo bash corex.sh manage update nextcloud  # Update a specific service
```

### Start / Stop Without Removing

```bash
sudo bash corex.sh manage disable immich    # Stop container (data preserved)
sudo bash corex.sh manage enable immich     # Start again
```

### ⚡ LAN Fast-Path (Full-Speed Local Transfers)

When your devices use AdGuard (on the CoreX server) as their DNS, `*.yourdomain.com` resolves to the server's **local IP** instead of Cloudflare. File uploads, photo syncs, and vault access all stay entirely on the local network at full LAN speed (~1 Gbps), bypassing the Cloudflare Tunnel.

```bash
sudo bash corex.sh manage lan-setup
```

This command:
- Automatically adds the wildcard `*.yourdomain.com → SERVER_IP` DNS rewrite in AdGuard via API
- Prints step-by-step DNS configuration instructions for router, macOS, Windows, iPhone, and Android
- Includes a verification command to confirm the fast-path is active

**External access** through Cloudflare Tunnel continues to work unchanged for devices off the LAN.

---

## 🔄 Backup & Restore

CoreX uses [Restic](https://restic.net/) for encrypted, deduplicated, versioned backups.

**What's backed up:** All service data (databases, uploads, mail, photos, configs, compose files).

**What's NOT backed up:** Docker images (re-pulled on restore), the Restic repo itself.

### Commands

```bash
sudo corex-backup.sh                    # Manual backup
tail -20 /var/log/corex-backup.log      # View backup log
sudo corex-restore.sh                   # Interactive restore (shows all snapshots)
sudo corex-restore.sh abc123ef          # Restore specific snapshot
```

### Automatic Schedule

Backups run daily at **3:00 AM** via cron. Retention: 7 daily, 4 weekly, 6 monthly snapshots.

### Migrate to New Hardware

```bash
# On old server
sudo corex-backup.sh
rsync -avP /mnt/corex-data/backups/restic-repo/ new-server:/mnt/corex-data/backups/restic-repo/

# On new server (after fresh CoreX install)
sudo corex-restore.sh latest
```

---

## 🔒 Security

CoreX implements defense-in-depth:

| Layer       | Tool                         | What It Does                                       |
| ----------- | ---------------------------- | -------------------------------------------------- |
| Firewall    | UFW                          | Default deny incoming, explicit per-port allow     |
| SSH         | Custom port + max 3 attempts | Moves off port 22, limits brute force              |
| Brute Force | Fail2ban                     | 3 failures → 24hr IP ban                           |
| IPS         | CrowdSec                     | Community threat intel, blocks known attackers     |
| Kernel      | sysctl hardening             | Anti-spoofing, SYN flood protection, ICMP lockdown |
| Updates     | unattended-upgrades          | Automatic security patches daily                   |
| Containers  | no-new-privileges            | Prevents privilege escalation inside containers    |
| DNS         | resolv.conf locked           | `chattr +i` prevents tampering                     |
| TLS         | Let's Encrypt via Traefik    | Auto-renewed HTTPS certificates                    |
| Tunnel      | Cloudflare                   | Zero exposed ports on router, DDoS protection      |

### Hardening After Install

```bash
# 1. Set up SSH keys (from your local machine)
ssh-copy-id -p 2222 your_user@YOUR_IP

# 2. Disable password auth (on the server)
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd

# 3. Disable Vaultwarden signups
# Edit /mnt/corex-data/docker-configs/vaultwarden/docker-compose.yml
# Change SIGNUPS_ALLOWED: "true" → "false"
cd /mnt/corex-data/docker-configs/vaultwarden && docker compose up -d
```

---

## 🔧 Troubleshooting

### Service won't start / is broken

```bash
# Auto-detect and repair all unhealthy services
sudo bash corex.sh doctor

# Or inspect manually
docker ps -a | grep SERVICE_NAME
docker logs SERVICE_NAME --tail 50
sudo bash corex.sh manage repair SERVICE_NAME
```

### 502 Bad Gateway

Usually a Docker network issue. Verify the container is on `proxy-net`:

```bash
docker network inspect proxy-net | grep SERVICE_NAME
# If missing:
sudo bash corex.sh manage repair SERVICE_NAME
```

### Cloudflare Tunnel returns 403

- Use **container names** in the service URL (e.g., `n8n:5678` not `localhost:5678`)
- Enable **No TLS Verify** under each hostname's TLS settings in CF Dashboard

### Time Machine not connecting

```bash
ss -tlnp | grep 445               # Verify SMB is listening
docker logs timemachine --tail 20  # Check container logs
```

### AdGuard not accessible after reboot

AdGuard changes its internal port after the setup wizard (3000 → 80). Fix with:

```bash
sudo bash corex.sh manage repair adguard
```

### Prometheus restart loop

```bash
# Prometheus runs as UID 65534 (nobody) — ownership must match
sudo chown -R 65534:65534 /mnt/corex-data/service-data/prometheus
sudo bash corex.sh manage repair monitoring
```

### Update all containers

```bash
sudo bash corex.sh manage update --all
```

---

## 🗺 Port Reference

| Port       | Service                         | Protocol | Exposure             |
| ---------- | ------------------------------- | -------- | -------------------- |
| 53         | AdGuard Home (DNS)              | TCP/UDP  | LAN                  |
| 80         | Traefik (HTTP → HTTPS redirect) | TCP      | Public via CF Tunnel |
| 443        | Traefik (HTTPS)                 | TCP      | Public via CF Tunnel |
| 445        | Time Machine (SMB)              | TCP      | LAN only             |
| 2222       | SSH                             | TCP      | LAN (or VPN)         |
| 2283       | Immich                          | TCP      | Via Traefik          |
| 3000       | AdGuard Home (Admin UI)         | TCP      | LAN                  |
| 3001       | Uptime Kuma                     | TCP      | Via Traefik          |
| 3002       | Grafana                         | TCP      | Via Traefik          |
| 3003       | Open WebUI                      | TCP      | Via Traefik          |
| 3005       | Browserless                     | TCP      | LAN                  |
| 5678       | n8n                             | TCP      | Via Traefik          |
| 8000       | Coolify                         | TCP      | LAN                  |
| 8080       | Traefik Dashboard               | TCP      | LAN                  |
| 9090       | Prometheus                      | TCP      | Internal             |
| 9443       | Portainer                       | TCP      | LAN                  |
| 11434      | Ollama API                      | TCP      | LAN only             |
| 25/587/465 | Stalwart (SMTP)                 | TCP      | Public               |
| 143/993    | Stalwart (IMAP)                 | TCP      | Public               |

---

## ⬆️ Upgrading from v1

If you have a v1 install (no `state.json`), run the installer once — it detects the running Traefik container, reconstructs state from your existing containers, and exits without touching anything:

```bash
sudo bash corex.sh install
# → Detected v1 install — migrating to v2 state tracking
# → Run: sudo bash corex.sh manage status
```

No restarts. No data changes. Just state file creation so all v2 management commands work.

---

## 🤝 Contributing

Contributions are welcome! The v2 architecture makes adding services easy.

**Adding a new self-hosted service:**

1. Create `lib/services/yourservice.sh` following the module contract
2. Export metadata vars: `SERVICE_NAME`, `SERVICE_LABEL`, `SERVICE_CATEGORY`, `SERVICE_RAM_MB`
3. Implement 6 functions: `_dirs`, `_firewall`, `_deploy`, `_destroy`, `_status`, `_repair`
4. Drop the file — the wizard, doctor, and manage commands discover it automatically

**Before submitting a PR:**

1. Test on a fresh Ubuntu 24.04 LTS Server install
2. Run `bash -n` on all modified shell files (zero errors policy)
3. Run `shellcheck` (zero warnings policy)
4. Add a smoke test in `test/smoke/` for any new service module

---

## 🧹 Uninstall & Rollback

CoreX Pro comes with a companion nuke script that cleanly reverses everything the installer did.

```bash
# Interactive - choose what to undo
sudo bash corex.sh nuke

# Preview what would happen (changes nothing)
sudo bash corex.sh nuke --dry-run

# Full nuke (still asks for confirmation)
sudo bash corex.sh nuke --all
```

The nuke script has 10 phases - each asks for confirmation. You can selectively undo just containers, just firewall rules, just DNS, etc. Your SSD data is preserved unless you explicitly choose to wipe it (requires typing `WIPE MY DATA`).

**Full documentation:** [NUKE.md](NUKE.md)

---

## 📁 Repo Structure

```
corex-pro/
├── corex.sh                    # CLI entry point (all commands)
├── install-corex-master.sh     # Thin orchestrator (~200 lines)
├── corex-manage.sh             # Post-install service manager
├── nuke-corex.sh               # Uninstall/rollback (10 phases)
├── migrate-domain.sh           # Change domain across all services
├── CLAUDE.md                   # AI assistant context (architecture + gotchas)
├── CHANGELOG.md
├── README.md
├── lib/
│   ├── common.sh               # Logging, colors, utilities
│   ├── state.sh                # /etc/corex/state.json management
│   ├── wizard.sh               # Interactive setup wizard (whiptail + fallback)
│   ├── preflight.sh            # Pre-flight checks, password generation
│   ├── drive.sh                # SSD partitioning and mounting
│   ├── security.sh             # SSH hardening, UFW, Fail2ban, sysctl
│   ├── docker.sh               # Docker install, network creation
│   ├── directories.sh          # Directory structure and ownership
│   ├── backup.sh               # Restic setup, backup/restore scripts
│   ├── summary.sh              # Credentials file + dashboard docs
│   └── services/               # One file per service — drop a file to add one
│       ├── traefik.sh
│       ├── adguard.sh
│       ├── portainer.sh
│       ├── nextcloud.sh
│       ├── immich.sh
│       ├── vaultwarden.sh
│       ├── n8n.sh
│       ├── stalwart.sh
│       ├── timemachine.sh
│       ├── coolify.sh
│       ├── crowdsec.sh
│       ├── cloudflared.sh
│       ├── monitoring.sh       # Uptime Kuma + Grafana + Prometheus bundle
│       └── ai.sh               # Ollama + Open WebUI + Browserless bundle
└── test/
    ├── Dockerfile.test         # Ubuntu 24.04 + bats + shellcheck + jq
    ├── run-tests.sh
    ├── unit/                   # Pure bash unit tests (no Docker/root required)
    └── smoke/                  # Validates generated docker-compose files
```

---

## 🔀 Domain Migration

Need to change your domain? One command updates all services:

```bash
sudo bash corex.sh migrate                               # Interactive
sudo bash corex.sh migrate olddomain.com newdomain.com   # Direct
sudo bash corex.sh migrate --dry-run old.com new.com     # Preview only
```

Backs up all compose files, updates every reference, clears old TLS certs (Traefik auto-renews), restarts affected services, and prints a checklist of manual steps (Cloudflare Tunnel hostnames, AdGuard DNS rewrites, mobile app server URLs).

---

## 🙏 Credits

CoreX Pro builds on these excellent open-source projects:

[Traefik](https://traefik.io/) • [AdGuard Home](https://adguard.com/adguard-home.html) • [Portainer](https://www.portainer.io/) • [Nextcloud](https://nextcloud.com/) • [Immich](https://immich.app/) • [Vaultwarden](https://github.com/dani-garcia/vaultwarden) • [Stalwart Mail](https://stalw.art/) • [Coolify](https://coolify.io/) • [n8n](https://n8n.io/) • [Ollama](https://ollama.com/) • [Open WebUI](https://openwebui.com/) • [Browserless](https://www.browserless.io/) • [Uptime Kuma](https://uptime.kuma.pet/) • [Grafana](https://grafana.com/) • [Prometheus](https://prometheus.io/) • [CrowdSec](https://www.crowdsec.net/) • [Restic](https://restic.net/) • [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

Inspired by the self-hosting philosophy of [NetworkChuck](https://www.youtube.com/@NetworkChuck), [Techno Tim](https://www.youtube.com/@TechnoTim), and the [r/selfhosted](https://www.reddit.com/r/selfhosted/) community.

---

<p align="center">
  <strong>Own your data. Own your stack.</strong>
</p>
<p align="center">
  <strong>Made with ❤️ in 🇮🇳</strong>
</p>
