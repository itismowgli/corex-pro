# Changelog

All notable changes to CoreX Pro will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v2.0.0] - 2026-02-21

This is a major architectural release. The monolithic 1,865-line installer is replaced by a modular `lib/` system. Existing v1 installations are not broken — a migration path reconstructs state from running containers automatically.

### Added

- **`lib/` modular architecture** — All installer logic extracted into focused, testable modules:
  - `lib/common.sh` — Shared logging, colors, and utility functions
  - `lib/state.sh` — `/etc/corex/state.json` management via jq (tracks installed services and configuration)
  - `lib/wizard.sh` — Full interactive setup wizard with whiptail UI + plain-read fallback
  - `lib/preflight.sh` — Pre-flight checks and password generation (Phase 0)
  - `lib/drive.sh` — SSD partitioning and mounting (Phase 1)
  - `lib/security.sh` — SSH hardening, UFW, Fail2ban, sysctl (Phase 2)
  - `lib/docker.sh` — Docker install and network creation (Phase 3)
  - `lib/directories.sh` — Directory structure and file ownership (Phase 4)
  - `lib/backup.sh` — Restic setup, corex-backup.sh, corex-restore.sh (Phase 6)
  - `lib/summary.sh` — Credentials file and dashboard docs (Phase 7)

- **Plugin-style service modules** — Each service is now a self-contained file in `lib/services/`:
  - `traefik.sh`, `adguard.sh`, `portainer.sh`, `nextcloud.sh`, `immich.sh`
  - `vaultwarden.sh`, `n8n.sh`, `stalwart.sh`, `timemachine.sh`, `coolify.sh`
  - `crowdsec.sh`, `cloudflared.sh`, `monitoring.sh`, `ai.sh`
  - Each module exports metadata vars and 6 lifecycle functions: `_dirs`, `_firewall`, `_deploy`, `_destroy`, `_status`, `_repair`
  - Auto-discovered by wizard, doctor, and manage commands — drop a new file, it appears everywhere

- **Interactive wizard** (`lib/wizard.sh`) — Replaces manual config editing:
  - Guided prompts for domain, server IP, email, timezone, SSH port, Cloudflare token
  - Service selection with whiptail checklist (categories: core, storage, security, productivity, AI, monitoring)
  - Installation profiles: `minimal`, `full`, `privacy`, `dev`, `nodomain`
  - Input validation with immediate re-prompting on invalid entries
  - Plain-read fallback when running non-interactively or without whiptail

- **`corex-manage.sh`** — Full post-install service manager:
  - `status` — Live health table (HEALTHY / UNHEALTHY / MISSING) for all installed services
  - `add <svc>` — Deploy a new service without re-running the installer
  - `remove <svc>` — Stop and optionally delete a service and its data
  - `enable / disable <svc>` — Start or stop a service without removing it
  - `update [--all | <svc>]` — Pull latest images and recreate containers
  - `repair [--all | <svc>]` — Force-recreate unhealthy containers (no data loss)
  - `replace <svc>` — Full destroy + redeploy of a service
  - `doctor` — Check all services and auto-repair unhealthy ones

- **`corex.sh` new commands**:
  - `doctor` — Runs `corex-manage doctor` (health check + auto-repair)
  - `manage <cmd>` — Passes through to `corex-manage.sh`
  - Context-aware interactive menu (shows different options pre/post install)

- **`/etc/corex/state.json`** — Machine-readable installation state:
  - Stores domain, server IP, email, timezone, SSH port, CF tunnel token
  - Tracks each service: installed, enabled, installed_at timestamp
  - Read/written by `lib/state.sh` functions; overridable with `COREX_STATE_FILE` env var for testing

- **v1 → v2 migration** — Running the installer on an existing v1 system:
  - Detects Traefik running + missing `state.json`
  - Reconstructs state from `docker ps` output (container-to-service mapping)
  - Writes `state.json` and exits — no restarts, no data changes

- **Test infrastructure** (`test/`):
  - `test/Dockerfile.test` — Ubuntu 24.04 container with bats, shellcheck, jq, docker-compose
  - `test/run-tests.sh` — Test runner (unit + smoke)
  - `test/unit/test_common.bats` — Unit tests for logging and utility functions
  - `test/unit/test_state.bats` — Unit tests for all state.sh functions
  - `test/unit/test_wizard.bats` — Unit tests for validation functions
  - `test/smoke/test_all_compose.bats` — Validates generated docker-compose files for all 14 services

- **`CLAUDE.md`** — Comprehensive AI assistant context document covering architecture, decisions, gotchas, conventions, and service dependency map

### Changed

- **`install-corex-master.sh`** refactored from 1,865-line monolith to ~200-line thin orchestrator:
  - Sources all `lib/` modules; calls `run_wizard` then the 7 phases in sequence
  - Loops over `SELECTED_SERVICES[]` from wizard; calls `_deploy_service` for each
  - All business logic lives in the modules — orchestrator is just sequencing
- **`corex.sh`** version bumped to `2.0.0`; banner uses `v${COREX_VERSION}` dynamically
- **README** fully rewritten to document v2 architecture, wizard, manage commands, v1 upgrade path, and plugin extensibility

### Architecture

- No live server required for testing (Docker-in-Docker + bats)
- Re-run on existing install → health check + repair only (healthy services never restarted)
- Adding a new service = one file in `lib/services/` (zero changes to core scripts)
- Strict mode (`set -uo pipefail`) on all new lib files; `set -e` kept on orchestrator

---

## [v1.1.0] - 2026-02-11

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

## [v1.0.0] - 2026-02-10

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

## [v0.1.0] - 2026-02-09

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

[v2.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.0.0
[v1.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.1.0
[v1.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.0.0
[v0.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v0.1.0
