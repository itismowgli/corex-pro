# Changelog

All notable changes to CoreX Pro will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v1.1.0] - 2025-02-11

### Fixed

- **AdGuard Home:** Port mapping mismatch — first-run wizard listens on 3000, post-setup switches to 80. Script now auto-detects and maps accordingly.
- **Time Machine:** Authentication failure — env var is `PASSWORD` not `TM_PASSWORD` for the `mbentley/timemachine:smb` image.
- **Time Machine:** Moved from rigid dedicated 400GB partition to shared data pool for flexible storage.
- **Time Machine:** Removed dbus/avahi socket mounts that caused container socket conflicts.
- **Phase 6 (Backup):** `cron` package not installed on Ubuntu 24.04 Server minimal — added explicit install.
- **Phase 6 (Backup):** `restic` install check before attempting repo initialization.
- **Phase 6 (Backup):** Crontab update crashed with `set -o pipefail` on empty crontab — rewritten with safe intermediate variables.
- **Prometheus:** Restart loop caused by incorrect data directory permissions — added `chown 65534:65534`.

### Added

- **Stalwart Mail:** Auto-captures admin credentials from first-run container logs and saves to credential file.
- `corex.sh` — Unified CLI entry point (install / nuke / migrate).
- `nuke-corex.sh` — 10-phase uninstall/rollback script with dry-run support.
- `migrate-domain.sh` — Domain migration across all 14 services with backup and auto-restart.
- `NUKE.md` — Complete documentation for the nuke script.
- `CHANGELOG.md` — This file.

### Changed

- `cron` added to Phase 2 apt-get package list.
- Stalwart credentials now included in `/root/corex-credentials.txt` and dashboard docs.
- README updated with one-liner install, uninstall section, domain migration, and repo structure.

---

## [v1.0.0] - 2025-02-10

### Fixed

- Added `loadbalancer.server.port` labels to ALL 9 web services (was missing on 8 of 9).
- **Time Machine:** Added `TM_UID`/`TM_GID`, avahi socket, dbus mount, samba state volume.
- **n8n:** Added `N8N_PORT`, `N8N_PROTOCOL: https`, `user: 1000:1000`, `GENERIC_TIMEZONE`.
- **Nextcloud:** Added `OVERWRITEPROTOCOL: https`, `OVERWRITEHOST`, `TRUSTED_PROXIES` (fixed redirect loops).
- **Immich:** Quoted `model-cache:/cache` volume reference (YAML syntax fix).
- **Portainer:** Data stored on SSD (`${DATA_ROOT}/portainer`) instead of anonymous Docker volume.
- **Stalwart Mail:** Updated from pinned `v0.8.0` to `latest`.
- **resolv.conf:** Locked with `chattr +i` to survive reboots.
- **Cloudflared:** Uses docker-compose instead of raw `docker run` (manageable, restartable).
- **Directories:** Added missing `n8n`, `open-webui`, `browserless`, `crowdsec-config` directories.

### Added

- Phase 6: Restic backup system with `corex-backup.sh`, `corex-restore.sh`, and daily cron.
- `avahi-daemon` package install for Time Machine macOS Bonjour discovery.
- Open WebUI `loadbalancer.server.port` label for Traefik routing.
- Comprehensive inline comments explaining every architectural decision.
- `/root/CoreX_Dashboard_Credentials.md` — Full Markdown docs with credentials, URLs, and setup guide.

---

## [v0.1.0] - 2025-02-09

### Added

- "Brains on System, Muscle on SSD" architecture — Docker engine on local disk, all data on external SSD.
- Smart credential loading — generates on first run, loads from file on re-runs.
- Explicit `container_name` on all services for predictable Docker DNS.
- Bridge-mode AdGuard Home (avoids port 80 conflict with Traefik).
- Interactive SSD partitioning with safety checks and skip-format option.
- UUID-based fstab entries for stable mounts across device reordering.

### Services (14 total)

- Traefik v3, AdGuard Home, Portainer, Nextcloud (MariaDB + Redis), Immich (PostgreSQL + ML), Vaultwarden, n8n, Time Machine, Stalwart Mail, Coolify (installer only), CrowdSec, Uptime Kuma, Grafana + Prometheus + Node Exporter + cAdvisor, Cloudflare Tunnel, Ollama + Open WebUI + Browserless.

### Security

- SSH hardening (custom port, root disabled, max 3 attempts).
- UFW firewall with per-port rules and Docker subnet allowance.
- Fail2ban (3 failures → 24hr ban).
- CrowdSec community IPS.
- Kernel hardening via sysctl (anti-spoof, SYN cookies, ICMP lockdown).
- Automatic security updates via unattended-upgrades.

---

## Version Numbering

CoreX Pro uses semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR** (v1, v2...): Breaking changes, architectural shifts, new phases
- **MINOR** (v1.1, v1.2...): New features, bug fixes, new scripts
- **PATCH** (v1.1.1, v1.1.2...): Small fixes, typos, documentation updates

[v1.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.1.0
[v1.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.0.0
[v0.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v0.1.0
