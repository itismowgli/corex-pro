<p align="center">
  <img src="https://img.shields.io/badge/CoreX_Pro-v7.1-blue?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Version">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">
  CoreX Pro - Sovereign Hybrid Homelab
</h1>

<p align="center">
  <strong>"Brains on System. Muscle on SSD."</strong><br>
  One script. 14 services. Zero cloud dependency. Full data sovereignty.
</p>

<p align="center">
  <a href="#-quickstart">Quickstart</a> •
  <a href="#-what-you-get">What You Get</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-services--use-cases">Services</a> •
  <a href="#-configuration">Configuration</a> •
  <a href="#-post-install-guide">Post-Install</a> •
  <a href="#-backup--restore">Backup</a> •
  <a href="#-troubleshooting">Troubleshooting</a> •
  <a href="#-license">License</a>
</p>

---

## 🤔 Why CoreX Pro?

You use Google Drive, Google Photos, Gmail, Bitwarden, Zapier, Vercel, ChatGPT, and a dozen other cloud services. You pay monthly for each, your data lives on someone else's servers, and you're one policy change away from losing access to your own files.

CoreX Pro replaces all of them with self-hosted alternatives running on a single machine in your home. One bash script sets up everything - encrypted, backed up, accessible from anywhere via Cloudflare Tunnel.

**Who is this for?**

- Developers who want a home server but don't want to spend weeks configuring it
- Privacy-conscious users who want to own their data
- Small teams that need shared infrastructure without SaaS costs
- Tinkerers who want a solid foundation to build on

**What you need:**

- A machine running **Ubuntu 24.04 LTS Server** (mini PC, old laptop, NUC, or dedicated server)
- **8GB+ RAM** (16GB recommended for AI services)
- An **external SSD** (500GB minimum, 1TB recommended)
- A **domain name** with DNS managed via Cloudflare (free tier works)

---

## ⚡ Quickstart

```bash
# 1. Clone the repo
git clone https://github.com/itismowgli/corex-pro.git
cd corex-pro

# 2. Edit configuration (REQUIRED - update IP, domain, tunnel token)
nano install-corex-master.sh

# 3. Run
chmod +x install-corex-master.sh
sudo bash install-corex-master.sh
```

The script walks you through drive selection, partitioning, and then auto-deploys everything. Takes about 10–15 minutes depending on your internet speed.

After completion, your credentials are saved to `/root/corex-credentials.txt` and a full dashboard guide is generated at `/root/CoreX_Dashboard_Credentials.md`.

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
│  14 Docker containers on isolated networks                   │
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
├── Partition 1 (400GB) → /mnt/timemachine     # macOS Time Machine
└── Partition 2 (~600GB) → /mnt/corex-data     # Everything else
    ├── docker-configs/                         # docker-compose.yml per service
    │   ├── traefik/
    │   ├── nextcloud/
    │   ├── immich/
    │   └── ...
    ├── service-data/                           # Persistent data
    │   ├── nextcloud-html/
    │   ├── immich-upload/
    │   ├── vaultwarden/
    │   ├── ollama/         # Downloaded LLM models
    │   └── ...
    ├── timemachine-data/                       # TM backups (shared pool)
    └── backups/
        └── restic-repo/                        # Encrypted backup snapshots
```

---

## 🧰 Services & Use Cases

### 🔀 Traefik - Reverse Proxy & TLS

**What:** Automatic HTTPS for all services. Routes `*.yourdomain.com` to the right container.

**When to use:** It's always running. Every service with a subdomain goes through Traefik.

**How it works:** Traefik watches the Docker socket for containers with `traefik.enable=true` labels, automatically creates routes, and gets Let's Encrypt certificates via TLS-ALPN-01 challenge.

**Access:** `http://YOUR_IP:8080` (dashboard)

---

### 🛡 AdGuard Home - DNS & Ad Blocking

**What:** Network-wide DNS server that blocks ads, trackers, and malware domains. Also serves as your local DNS for routing `*.yourdomain.com` to your server's LAN IP.

**When to use:**

- Block ads on every device on your network (including smart TVs, phones, IoT)
- Route your subdomains locally so LAN traffic never hits the internet
- Monitor DNS queries for suspicious activity

**How it works:** Runs on port 53, replaces your router's DNS. All devices on your network send DNS queries to your server. AdGuard checks blocklists and DNS rewrites before resolving.

**Key setup:** Add DNS Rewrites: `*.yourdomain.com → YOUR_SERVER_IP`

**Access:** `http://YOUR_IP:3000`

---

### 🐳 Portainer - Docker Management

**What:** Web UI for managing Docker containers, images, volumes, and networks.

**When to use:**

- View container logs without SSH
- Restart services from your phone
- Monitor resource usage per container
- Deploy additional containers via the UI

**Access:** `https://YOUR_IP:9443`

---

### ☁️ Nextcloud - File Storage & Sync

**What:** Self-hosted Google Drive / Dropbox. File sync, calendar, contacts, notes, video calls, kanban boards.

**When to use:**

- Sync files across all your devices
- Share files/folders with family or team via links
- Collaborative document editing
- Calendar and contacts sync (replaces Google Calendar)
- Video calls (Nextcloud Talk, replaces Google Meet)

**How it works:** MariaDB + Redis backend for performance. Traefik handles HTTPS. Desktop/mobile apps sync automatically.

**Apps to install after setup:** Calendar, Contacts, Notes, Talk, Deck, Bookmarks

**Access:** `https://nextcloud.yourdomain.com`

---

### 📸 Immich - Photo & Video Management

**What:** Self-hosted Google Photos. AI-powered face recognition, smart search, automatic mobile backup.

**When to use:**

- Automatic photo backup from iOS/Android
- Search photos by content ("beach sunset", "dog", "birthday")
- Face recognition and people grouping
- Shared albums with family
- Memories and timeline view

**How it works:** Includes a machine learning container that processes your library for face detection, object recognition, and CLIP-based search. Downloads ~1GB of ML models on first start.

**Access:** `https://photos.yourdomain.com`
**Mobile:** [iOS App](https://apps.apple.com/app/immich/id1613945652) / [Android App](https://play.google.com/store/apps/details?id=app.alextran.immich)

---

### 🔐 Vaultwarden - Password Manager

**What:** Lightweight, self-hosted Bitwarden server. Works with all official Bitwarden clients.

**When to use:**

- Store and autofill passwords across all devices
- Share passwords with family (Organizations feature)
- Store secure notes, credit cards, identities
- Generate strong passwords
- TOTP authenticator codes

**How it works:** Rust implementation of the Bitwarden API. All data encrypted with your master password before storage. Admin panel at `/admin` for user management.

**Important:** Set `SIGNUPS_ALLOWED: "false"` in docker-compose.yml after creating your accounts.

**Access:** `https://vault.yourdomain.com`
**Admin:** `https://vault.yourdomain.com/admin`
**Clients:** [Browser Extension](https://bitwarden.com/download/) / iOS / Android / Desktop

---

### ✉️ Stalwart Mail - Email Server

**What:** All-in-one email server: SMTP, IMAP, CalDAV, CardDAV. Written in Rust.

**When to use:**

- Host email on your own domain (`you@yourdomain.com`)
- Full control over email data (no scanning, no AI training)
- CalDAV/CardDAV for calendar and contacts sync
- Custom spam filtering via ManageSieve

**How it works:** Handles all email protocols. Auto-generates admin credentials on first boot (captured by the script). Requires DNS records (MX, SPF, DKIM, DMARC) for proper deliverability.

**Note:** Self-hosted email has deliverability challenges. Consider an SMTP relay (SMTP2GO, Mailgun free tier) for outbound mail.

**Access:** `https://mail.yourdomain.com`
**Ports:** 25 (SMTP), 587 (Submission), 465 (SMTPS), 143 (IMAP), 993 (IMAPS), 4190 (Sieve)

---

### 🚀 Coolify - Web Hosting PaaS

**What:** Self-hosted Vercel / Netlify / Heroku. Deploy web apps with git push.

**When to use:**

- Deploy static sites, Next.js, Laravel, Rails, Django apps
- Automatic deployments from GitHub/GitLab
- Preview deployments for pull requests
- Managed databases (Postgres, MySQL, Redis, MongoDB)
- Free SSL certificates for deployed apps

**How it works:** Installs its own Docker stack and reverse proxy. Run the installer separately after CoreX setup to avoid port conflicts.

**Access:** `http://YOUR_IP:8000`

---

### ⚡ n8n - Workflow Automation

**What:** Self-hosted Zapier / Make.com. Visual workflow builder with 400+ integrations.

**When to use:**

- Automate repetitive tasks (RSS to email, form submissions to Slack)
- Connect services that don't natively integrate
- Build webhook-triggered workflows
- Scheduled data processing and reporting
- AI agent workflows with Ollama integration

**How it works:** Runs as user 1000:1000 for file permission compatibility. Encryption key protects stored credentials. Webhooks work via Cloudflare Tunnel.

**Access:** `https://n8n.yourdomain.com`

---

### 💾 Time Machine - macOS Backups

**What:** Network Time Machine server via SMB. Your Mac backs up to your server automatically.

**When to use:**

- Automatic hourly macOS backups over Wi-Fi
- Restore individual files or full system from any backup point
- No need for a dedicated external drive on your desk

**How it works:** Samba share advertised via Bonjour/mDNS. macOS discovers it automatically in System Settings → Time Machine. Backups are incremental (only changed files).

**Access:** `smb://YOUR_IP/CoreX_Backup` or auto-discovered in Time Machine preferences.

---

### 📊 Uptime Kuma - Status Monitoring

**What:** Self-hosted UptimeRobot. Beautiful status pages and multi-protocol monitoring.

**When to use:**

- Monitor uptime of all your services
- Get notifications when something goes down (email, Slack, Discord, Telegram)
- Public status page for your team or users
- TCP, HTTP, DNS, Docker, and ping monitors

**Access:** `https://status.yourdomain.com`

---

### 📈 Grafana + Prometheus - Metrics & Dashboards

**What:** Full observability stack. Prometheus collects metrics, Grafana visualizes them.

**When to use:**

- Monitor CPU, RAM, disk, and network usage over time
- Per-container resource metrics (via cAdvisor)
- Custom dashboards for any metric
- Set up alerts for disk space, high CPU, container crashes

**How it works:** Node Exporter exposes host metrics, cAdvisor exposes container metrics, Prometheus scrapes them every 30 seconds, Grafana renders dashboards.

**Quick start:** Import dashboard ID `1860` (Node Exporter Full) in Grafana.

**Access:** Grafana at `https://grafana.yourdomain.com` / Prometheus at `http://YOUR_IP:9090`

---

### 🤖 Ollama - Local LLM Engine

**What:** Run large language models locally. Supports Llama, Mistral, CodeLlama, Gemma, and more.

**When to use:**

- Private AI chat (no data sent to OpenAI/Anthropic/Google)
- Code generation and review
- Document analysis and summarization
- AI-powered automation via n8n + Ollama

**Recommended models:**

- `llama3.2:3b` - Fast, good for chat (3GB RAM)
- `mistral:7b` - Balanced quality/speed (7GB RAM)
- `codellama:7b` - Coding assistant (7GB RAM)
- `gemma2:9b` - Strong general-purpose (9GB RAM)

**Access:** API at `http://YOUR_IP:11434`

---

### 💬 Open WebUI - AI Chat Interface

**What:** Self-hosted ChatGPT-like interface that connects to Ollama.

**When to use:**

- Chat with local LLMs through a polished web interface
- Multi-model conversations (switch models mid-chat)
- Upload documents for RAG (retrieval-augmented generation)
- Share chat sessions with team members
- Custom system prompts and personas

**Access:** `https://ai.yourdomain.com`

---

### 🌐 Browserless - Headless Chrome

**What:** Chrome browser as an API. For AI agents, web scraping, PDF generation.

**When to use:**

- n8n workflows that need to interact with web pages
- AI agents that need to browse the web (via Ollama + Browserless)
- Generate PDFs from HTML
- Take screenshots of web pages
- Web scraping and data extraction

**Access:** API at `http://YOUR_IP:3005`

---

### 🛡 CrowdSec - Community Intrusion Prevention

**What:** Community-powered IPS. Detects attack patterns and shares threat intelligence globally.

**When to use:** Always running. Monitors Traefik logs, SSH logs, and system logs for:

- Brute force attacks
- CVE exploit attempts
- Bot and crawler abuse
- Port scanning

**How it works:** Detects threats locally, reports to CrowdSec community, receives blocklists of known-bad IPs from the community. You block attackers _before_ they even target you.

**Commands:**

```bash
docker exec crowdsec cscli decisions list    # View blocked IPs
docker exec crowdsec cscli metrics           # View detection stats
```

---

### 🔒 Cloudflare Tunnel - Secure External Access

**What:** Encrypted tunnel from Cloudflare's edge network to your server. No port forwarding required.

**When to use:**

- Access services from outside your home (phone on cellular, travel, work)
- Zero exposed ports on your router
- DDoS protection and WAF included (Cloudflare free tier)
- SSL termination at Cloudflare's edge

**How it works:** The `cloudflared` container maintains a persistent outbound connection to Cloudflare. When someone visits `photos.yourdomain.com`, Cloudflare routes the request through the tunnel to `immich-server:2283` inside Docker.

**Critical:** In Cloudflare Dashboard → Tunnels → Public Hostnames, use **container names** (not `localhost`). The tunnel runs inside Docker.

---

## ⚙️ Configuration

Edit the configuration block at the top of `install-corex-master.sh` before running:

```bash
SERVER_IP="192.168.1.100"               # Your server's static LAN IP
DOMAIN="example.com"                    # Your domain (managed via Cloudflare)
EMAIL="admin@example.com"              # For Let's Encrypt certificates
TIMEZONE="UTC"                          # Your timezone
SSH_PORT="2222"                         # Custom SSH port
CLOUDFLARE_TUNNEL_TOKEN="PASTE..."      # From Cloudflare Dashboard
TM_SIZE="400GB"                         # Time Machine partition size
```

### Getting a Cloudflare Tunnel Token

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com)
2. Navigate to **Networks → Tunnels → Create a Tunnel**
3. Choose **Cloudflared** connector
4. Copy the token (starts with `eyJ...`)
5. Paste into the config

### Setting a Static IP

Your server needs a static LAN IP. Either:

- Configure it in your router (DHCP reservation) - recommended
- Or set it on the server in `/etc/netplan/` config

---

## 📋 Post-Install Guide

After the script completes, follow these steps **in order**:

### 1. AdGuard Home (DNS) - Do This First

1. Open `http://YOUR_IP:3000`
2. Complete setup wizard
3. Add DNS Rewrites: `*.yourdomain.com → YOUR_IP` and `yourdomain.com → YOUR_IP`
4. Set your router's primary DNS to `YOUR_IP`
5. Now all `*.yourdomain.com` URLs resolve locally

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

> ⚠️ Use **container names**, not `localhost`. Cloudflared runs inside Docker on `proxy-net`.

### 3. Create Admin Accounts

Open each service and create your account **immediately** - first visitor becomes admin:

- Portainer: `https://YOUR_IP:9443`
- Nextcloud: `https://nextcloud.yourdomain.com`
- Immich: `https://photos.yourdomain.com`
- Vaultwarden: `https://vault.yourdomain.com`
- n8n: `https://n8n.yourdomain.com`
- Uptime Kuma: `https://status.yourdomain.com`
- Open WebUI: `https://ai.yourdomain.com`

### 4. View All Credentials

```bash
# Quick credentials reference
cat /root/corex-credentials.txt

# Full dashboard with setup instructions for every service
cat /root/CoreX_Dashboard_Credentials.md
```

---

## 🔄 Backup & Restore

CoreX uses [Restic](https://restic.net/) for encrypted, deduplicated, versioned backups.

**What's backed up:** All service data (databases, uploads, mail, photos, configs, compose files).

**What's NOT backed up:** Docker images (re-pulled on restore), Time Machine data (macOS manages its own backups), the Restic repo itself.

### Commands

```bash
# Manual backup
sudo corex-backup.sh

# View backup log
tail -20 /var/log/corex-backup.log

# List all snapshots
sudo RESTIC_REPOSITORY=/mnt/corex-data/backups/restic-repo \
     RESTIC_PASSWORD='YOUR_RESTIC_PASSWORD' \
     restic snapshots

# Restore (interactive - shows snapshots, asks confirmation)
sudo corex-restore.sh

# Restore specific snapshot
sudo corex-restore.sh abc123ef
```

### Automatic Schedule

Backups run daily at **3:00 AM** via cron. Retention policy: 7 daily, 4 weekly, 6 monthly snapshots.

### Migrate to New Hardware

```bash
# On old server: run a fresh backup
sudo corex-backup.sh

# Copy the restic repo to new server
rsync -avP /mnt/corex-data/backups/restic-repo/ new-server:/mnt/corex-data/backups/restic-repo/

# On new server: partition SSD, install Docker, then restore
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

### Service won't start

```bash
# Check container status
docker ps -a | grep SERVICE_NAME

# View logs
docker logs SERVICE_NAME --tail 50

# Restart
cd /mnt/corex-data/docker-configs/SERVICE_NAME
docker compose restart
```

### 502 Bad Gateway

Usually a Docker network issue. Verify the container is on `proxy-net`:

```bash
docker network inspect proxy-net | grep SERVICE_NAME
```

If not listed:

```bash
cd /mnt/corex-data/docker-configs/SERVICE_NAME
docker compose down && docker compose up -d
```

### Cloudflare Tunnel returns 403

- Verify hostname is configured in CF Dashboard → Tunnels → Public Hostnames
- Use **container names** in the service URL (e.g., `n8n:5678` not `localhost:5678`)
- Enable **No TLS Verify** under each hostname's TLS settings

### Time Machine not connecting

```bash
# Check SMB is listening
ss -tlnp | grep 445

# Check container logs
docker logs timemachine --tail 20

# Test from Mac
smbutil view //timemachine@YOUR_IP
```

### AdGuard not accessible after reboot

AdGuard changes its internal port after setup (3000 → 80). Re-run the script or manually update the compose:

```bash
cd /mnt/corex-data/docker-configs/adguard
# Check internal port: grep "address" in the AdGuard config
docker compose down && docker compose up -d
```

### Prometheus restart loop

```bash
# Fix permissions (Prometheus runs as nobody:65534)
sudo chown -R 65534:65534 /mnt/corex-data/service-data/prometheus
cd /mnt/corex-data/docker-configs/monitoring
docker compose restart prometheus
```

### Update all containers

```bash
for dir in /mnt/corex-data/docker-configs/*/; do
  if [[ -f "$dir/docker-compose.yml" ]]; then
    echo "Updating $(basename $dir)..."
    (cd "$dir" && docker compose pull && docker compose up -d)
  fi
done
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

## 🤝 Contributing

Contributions are welcome! This project was born from real-world deployment and debugging - every fix in the changelog came from an actual production issue.

**Ways to contribute:**

- Report bugs (include `docker logs` output and your Ubuntu version)
- Add support for additional services
- Improve documentation
- Add GPU passthrough support for Ollama
- Create Ansible/Terraform alternatives

**Before submitting a PR:**

1. Test on a fresh Ubuntu 24.04 LTS Server install
2. Run `bash -n install-corex-master.sh` to validate syntax
3. Document any new configuration variables

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
