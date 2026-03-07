# Changelog

All notable changes to CoreX Pro will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v2.3.0] - 2026-03-07

### Fixed

- **Traefik Docker Engine 29+ compatibility** — Upgraded from `traefik:v3.0` to `traefik:v3.6`. Docker Engine 29 raised the minimum API version from v1.25 to v1.44, but Traefik versions prior to v3.6 hardcoded Docker API v1.24 in their Go client library. This caused Traefik's Docker provider to fail completely — zero routes discovered, no container labels read, no Let's Encrypt certificates issued. All traffic was forced through Cloudflare Tunnel instead of the LAN fast-path, resulting in KB/s transfer speeds. Traefik v3.6 includes automatic Docker API version negotiation ([traefik/traefik#12256](https://github.com/traefik/traefik/issues/12253)).

### Added

- **Nextcloud LAN transfer performance tuning** — Fixes KB/s transfer speeds over LAN, achieving full gigabit throughput:
  - **PHP streaming:** `output_buffering = Off` — the #1 fix. Default 4KB buffering caused PHP to churn through tiny chunks instead of streaming files directly to Apache
  - **OPcache + JIT:** PHP scripts precompiled with JIT (1255 mode, 128MB buffer) — faster page loads and file browser rendering
  - **APCu local cache:** 128MB shared memory cache for Nextcloud metadata lookups — injected into `config.php` via startup hook
  - **Redis file locking:** Automatically configured via `before-starting` entrypoint hook to prevent file corruption on parallel access
  - **Apache binary bypass:** `mod_deflate` disabled for images, videos, archives, and ISO files — eliminates CPU-bound gzip bottleneck on large transfers
  - **Apache timeout extension:** `mod_reqtimeout` body timeout set to unlimited (`body=0`) — multi-GB uploads no longer killed after 20 seconds
  - **MariaDB performance:** `innodb-buffer-pool-size=256M`, `innodb-log-file-size=64M`, `O_DIRECT` flush method, relaxed commit flushing — faster file listing queries
  - **Redis persistence:** `--save 60 1 --loglevel warning` — periodic snapshots with reduced log noise
  - **CalDAV/CardDAV middleware:** Traefik regex redirect for `.well-known/caldav` and `.well-known/carddav` — fixes iOS/macOS calendar and contacts sync discovery
  - **HSTS headers:** `Strict-Transport-Security` with 180-day max-age, includeSubdomains, and preload via Traefik middleware
  - **Traefik response streaming:** `flushInterval=100ms` on Nextcloud loadbalancer — ensures Traefik forwards response chunks immediately

- **Traefik transport timeout configuration** — Unlimited read/write timeouts on the `websecure` entrypoint:
  - `readTimeout: 0s` — large file uploads no longer killed after Traefik's default 60-second timeout
  - `writeTimeout: 0s` — large file downloads stream without time limit
  - `idleTimeout: 300s` — 5-minute idle timeout for persistent connections

### Changed

- **Nextcloud docker-compose** — Three new volume mounts for performance configs:
  - `zzz-corex-performance.ini` → `/usr/local/etc/php/conf.d/` (PHP tuning, loaded last via zzz- prefix)
  - `corex-apache-perf.conf` → `/etc/apache2/conf-enabled/` (Apache transfer tuning)
  - `hooks/before-starting/` → `/docker-entrypoint-hooks.d/before-starting/` (config.php injection)
- **`nextcloud_repair()`** now regenerates performance config files before force-recreating containers — existing installations get the tuning via `corex manage repair nextcloud` without a full redeploy

### How it works

The default `nextcloud:stable` Docker image is optimized for compatibility, not LAN speed. PHP's `output_buffering=4096` forces every file download through a 4KB buffer-and-flush cycle. Apache's `mod_deflate` tries to gzip binary files (photos, videos), burning CPU for zero compression gain. Apache's `mod_reqtimeout` kills request bodies after 20 seconds. Traefik's default `readTimeout=60s` drops upload connections.

These four bottlenecks compound: a 500MB photo upload gets gzipped (CPU-bound), buffered through 4KB PHP chunks, timeout-killed by Apache after 20s, and dropped by Traefik after 60s. The result is KB/s transfer speeds on a gigabit LAN.

The fix: stream (don't buffer), skip compression on binary content, and remove all timeout ceilings. After applying, Nextcloud file transfers should saturate your LAN link.

**For existing installations:** `corex manage repair nextcloud` (after updating CoreX Pro scripts).

---

## [v2.2.0] - 2026-03-06

### Added

- **Network performance tuning** (`corex manage network-tune`) — New command that diagnoses network interfaces, displays current vs optimal kernel parameters, and applies high-performance tuning. Transforms file transfer speeds from KB/s to hundreds of MB/s on gigabit+ networks.
  - Detects all ethernet and wireless interfaces with link speed, state, and MTU
  - Shows 14 critical kernel network parameters with current values
  - Applies BBR congestion control (Google's algorithm, 2-10x better than CUBIC on LAN)
  - Tunes TCP buffer sizes from ~200KB default up to 64MB max per socket
  - Enables TCP Fast Open, MTU path probing, window scaling, and SACK
  - Prints diagnostic speed tips (cable check, iperf3 testing, SMB multichannel verification)
  - Safe to re-run — detects if tuning is already applied

- **High-performance SMB3 for Time Machine** — Rebuilt the Time Machine service with optimized Samba configuration for multi-gigabit LAN transfers:
  - SMB3 minimum protocol enforced (disables insecure SMB1/SMB2)
  - SMB multichannel enabled (uses all available NICs simultaneously)
  - 8MB read/write chunks per SMB request (up from default 64KB — 128x larger)
  - 2MB socket buffers with TCP_NODELAY for low-latency transfers
  - Async I/O via sendfile for zero-copy kernel-level file transfers
  - Aggressive client caching via level2 oplocks
  - Custom `smb-performance.conf` overlay bind-mounted into the container
  - Increased file descriptor limits (ulimits 65536)

- **Interactive menu option 4** — "Network tune" added to `corex.sh` interactive menu

### Changed

- **Kernel network parameters** (lib/security.sh) — Expanded from 14 security-only params to 50+ params covering both security and performance:
  - TCP buffer auto-tuning: min 4KB → default 256KB → max 64MB
  - BBR congestion control with fq qdisc (replaces CUBIC + pfifo_fast)
  - Connection handling: somaxconn 4096, netdev_max_backlog 16384
  - TCP keepalive tuned for faster dead connection detection (60s interval)
  - VM tuning: swappiness 10, dirty_ratio 40 for file-server workloads
  - File descriptor limits: 2M max, inotify watches 524K
  - Source route rejection on all interfaces (IPv4 + IPv6)
  - TCP RFC 1337 compliance (TIME-WAIT assassination protection)

### Security Hardened

- **SSH ciphers restricted** — Only modern, audited algorithms allowed:
  - KEX: curve25519-sha256, diffie-hellman-group16/18-sha512
  - Ciphers: chacha20-poly1305, aes256-gcm, aes128-gcm
  - MACs: hmac-sha2-512-etm, hmac-sha2-256-etm
  - Empty passwords disabled, Debian banner removed
  - Client alive interval 300s with max 2 probes (auto-disconnect idle sessions)

- **Fail2ban upgraded to 3-jail system**:
  - `sshd`: Standard jail — 3 failures in 10min → 24hr ban
  - `sshd-aggressive`: Aggressive detection — 2 failures in 1hr → 7-day ban
  - `recidive`: Repeat offender jail — 3 Fail2ban bans in 24hrs → 30-day ban
  - Ban action changed from iptables to UFW for consistent firewall management

---

## [v2.1.1] - 2026-03-02

### Fixed

- **`corex manage lan-setup` HTTP 400 on domain with embedded quotes** — The v1→v2 state migration extracted the domain from `traefik.yml`'s `email:` field using a regex that captured surrounding YAML quotes (e.g. `"admin@yourdomain.com"` → after stripping `admin@`, stored `"yourdomain.com"` with literal quote characters). This caused the AdGuard DNS rewrite API call to send malformed JSON (`{"domain": "*."yourdomain.com"", ...}`) and receive HTTP 400.
  - Root-cause fix in `_migrate_v1_if_needed()`: pipe through `tr -d '"'` before calling `sed 's/admin@//'` to strip any YAML quote characters during migration.
  - Defensive fix in `_load_config()`: `DOMAIN` and `SERVER_IP` are now cleaned with `| tr -d '"'` on load, so existing installations with already-corrupt `state.json` values are fixed transparently on the next run — no manual state file editing required.

---

## [v2.1.0] - 2026-03-01

### Added

- **LAN fast-path setup** (`corex manage lan-setup`) — New command that eliminates the manual AdGuard DNS rewrite step and prints complete router/device DNS configuration instructions.
  - Automatically detects the AdGuard admin port from `AdGuardHome.yaml`
  - Calls AdGuard's REST API (`POST /control/rewrite/add`) to register a wildcard `*.yourdomain.com → SERVER_IP` DNS rewrite
  - Prompts for AdGuard credentials if the API requires auth (post-wizard state)
  - Falls back to manual instructions if the API call fails
  - Prints step-by-step DNS setup instructions for router, macOS, Windows, iPhone, and Android
  - Includes a verification step (`nslookup nextcloud.domain`) to confirm the fast-path is working
- **Interactive menu option 3** — "LAN fast-path setup" added to `corex.sh` interactive menu for post-install systems
- **Post-install guide updated** — `lib/summary.sh` now shows `lan-setup` as step 2 in "First Things To Do" (replacing the old manual AdGuard UI instruction)

### How it works

When devices on your LAN use AdGuard (running on the CoreX server) as their DNS server, `*.yourdomain.com` resolves to the server's local IP instead of Cloudflare. All traffic — file uploads to Nextcloud, photo syncs with Immich, Vaultwarden vault access — stays entirely on the local network at full LAN speed (~1 Gbps), bypassing the Cloudflare Tunnel entirely.

External access through Cloudflare Tunnel continues to work unchanged for devices off the LAN.

---

## [v2.0.1] - 2026-02-22

### Fixed

- **`corex doctor` on v1 installs:** `corex-manage.sh` was hard-failing with "No state file found" when `/etc/corex/state.json` didn't exist. `_load_config` now calls `_migrate_v1_if_needed()` automatically before reading state — detecting running Traefik, reconstructing state from `docker ps`, and writing `state.json` inline, then proceeding with the doctor health check without any user action required.
- **v1→v2 migration coverage:** Expanded container-to-service mapping to include all sub-containers (nextcloud-db, nextcloud-redis, immich-redis, immich-ml, node-exporter, cadvisor, browserless) so all services are correctly detected from a v1 install.
- **Duplicate service recording in migration:** Services with multiple containers (Nextcloud, Immich, monitoring) were being recorded multiple times; fixed with a `seen_svcs` deduplication guard.

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

[v2.3.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.3.0
[v2.2.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.2.0
[v2.1.1]: https://github.com/itismowgli/corex-pro/releases/tag/v2.1.1
[v2.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.1.0
[v2.0.1]: https://github.com/itismowgli/corex-pro/releases/tag/v2.0.1
[v2.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.0.0
[v1.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.1.0
[v1.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.0.0
[v0.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v0.1.0
