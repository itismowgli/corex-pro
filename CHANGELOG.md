# Changelog

All notable changes to CoreX Pro will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v3.2.1] - 2026-09-02

### Fixed
- **The CoreX Dashboard had never actually run.** See the entry below — this
  release is what makes it work. Split out from v3.2.0 because the fix landed
  after that tag.

## [v3.2.0] - 2026-09-02

### Fixed — `repair` never delivered compose-level fixes (systemic)

**14 of 16 service modules recreated their container from whatever
`docker-compose.yml` was already on disk.** Only `nextcloud` (v2.4.2) and
`stalwart` regenerated it. Every CoreX fix expressed in the compose file —
environment variables, resource limits, `security_opt`, published ports,
Traefik labels — therefore never reached an existing install. Since
`corex doctor` / `corex manage repair` is the only mechanism users have for
picking up fixes, this quietly blunted the entire self-healing story.

The concrete casualty: the Traefik dashboard publish was changed to
`127.0.0.1:8080:8080` in code, but deployed instances kept `8080:8080` —
binding `0.0.0.0` and exposing the full routing table to the LAN. Docker's
published ports are written straight into the `DOCKER-USER` iptables chain, so
UFW's default-deny did not cover it either.

Every module's `repair()` now regenerates its compose first. `coolify`
(installs its own stack upstream) and `ups` (NUT runs on the host) are the only
exclusions, and a test asserts they genuinely have no compose file.
`_traefik_write_compose()` was extracted so Traefik regenerates without losing
its existing certificate and `dynamic.yml` repair logic.

### Fixed — generated secrets rotated on every run

Making `repair` call `deploy` exposed a latent problem: secrets generated
inline in `deploy` were regenerated on every invocation. A repair would have
silently changed credentials to values nothing recorded.

- **CoreX Dashboard** Basic Auth password — would have locked the operator out
  of the GUI on any repair. Now persisted to
  `${DOCKER_ROOT}/dashboard/.dashboard-password` (0600).
- **Browserless token** — now persisted; a rotation would break any client
  already configured against it.
- **NUT monitor password** — `upsd.users` and `upsmon.conf` must agree on it, so
  a rotation would leave `upsmon` unable to authenticate to `upsd`, silently
  disabling the shutdown-on-battery protection the module exists to provide.

### Fixed — Stalwart could never be logged into

`STALWART_ADMIN_USER` / `STALWART_ADMIN_SECRET` are **not read** by current
Stalwart images. CoreX generated a good password and passed it through
variables the image ignores, so Stalwart fell back to bootstrap mode with its
own random temporary password, printed once to the container log. Observed in
the field as a mail server nobody could configure: no Stalwart entry in the
credentials file, a 4KB data directory weeks after install, and a container
reporting healthy throughout.

Now pinned via `STALWART_RECOVERY_ADMIN` (`user:password`), the supported
variable that Stalwart's own bootstrap message points at, and persisted to
`${DOCKER_ROOT}/stalwart/.admin-password` (0600).

### Fixed — `corex update` poisoned the repo for its owner

`do_update` normally runs under `sudo`, so git wrote new objects, refs and
`.git/config` as root. The repo owner could then never fetch again
(`insufficient permission for adding an object`). Because a failed `git pull`
inside a longer script is easy to miss, the repository silently stopped
updating while deployments appeared to succeed. It now records the repo
directory's owner and restores it on every exit path.

### Fixed — the CoreX Dashboard had never actually run
`ghcr.io/itismowgli/corex-dashboard:latest` was never published. Pulling it
fails with `error from registry: denied`, so the web GUI documented as
auto-installed since v3.0.0 had never started for anyone. Worse,
`dashboard_deploy` logged `CoreX Dashboard deployed` and marked the service
installed **even when the pull failed**, so a completely absent dashboard
reported as healthy — which is how this went unnoticed across two releases.

It is now built from source on the server (all of `main.go`, `templates/` and
`static/` are in the repo, embedded via `//go:embed`), with
`pull_policy: build` so Compose does not consult the registry at all. Deploy
now waits for the container to actually be running and reports a real failure
with the commands to diagnose it if not.

### Added — documentation for things that had none

- **CoreX Dashboard — Web GUI**: the GUI shipped in v3.0.0 with no documented
  way to log into it. Now documents the URL, that the username is `admin`,
  where to find the generated password, how to change it, LAN access, what
  each tab does, and troubleshooting for 404 / 502 / auth-loop.
- **Cloudflare Tunnel — Step-by-Step Setup**: previously two sentences. Now a
  full walkthrough: nameserver change, tunnel creation, where the token
  actually is, wiring it into CoreX, and a Public Hostname table. Explains why
  the URL must be a **container name and internal port** rather than
  `localhost` — the most common setup failure — plus what not to expose, and a
  troubleshooting table (Error 1033, 502, HTTP 413).
- Corrected the README's Traefik access instructions, which told users to open
  `http://YOUR_IP:8080`. That is the Traefik dashboard, it is loopback-only by
  design, and the line also invited exposing it. Replaced with the SSH-tunnel
  command and a pointer distinguishing it from the CoreX Dashboard.

### Added — tests
- `test/unit/test_service_contract.bats` — asserts every `repair()` regenerates
  its compose, that the exclusion list is honest, that the Traefik dashboard is
  never bound to `0.0.0.0`, that generated secrets are persisted, that all
  seven contract functions exist in every module, and that Nextcloud pins a
  major version instead of tracking `:stable`.

## [Unreleased]

### Fixed — Nextcloud 34 broke the occ hook (outage)
- **`nextcloud:stable` pulled a major upgrade that removed `gosu`.** The
  `before-starting` hook hardcoded `gosu www-data`, so on Nextcloud 34 every
  `occ` call failed with `gosu: command not found`. Wrapped in a 6-attempt /
  30-second retry loop across 8 calls, that blocked container startup for
  roughly four minutes on every restart, Traefik served **502** for the whole
  window, and none of the configuration was applied. The hook now probes for
  `gosu` / `setpriv` / `runuser` / `su` and fails fast with a clear message if
  none can drop privileges, instead of retrying something unsatisfiable.
- **Pinned `nextcloud` to `:34`.** `:stable` follows major versions, so a
  routine `corex manage update` performed an unattended major upgrade — and
  Nextcloud does not support skipping majors, so an instance two versions
  behind cannot upgrade itself. Majors should be a deliberate decision, as
  `traefik:v3.6` and `mariadb:10.11` already are.

### Added — Whiteboard real-time collaboration
- **Whiteboard WebSocket backend** (`nextcloud-whiteboard`). The Whiteboard app
  draws fine standalone but real-time multi-user editing needs a separate
  WebSocket server, which Nextcloud's setup checks flag as "WebSocket server
  URL is not configured". Added to the Nextcloud compose with a Traefik route
  at `whiteboard.DOMAIN`, Redis-backed shared state, and resource limits. The
  shared JWT secret is persisted in `${DOCKER_ROOT}/nextcloud/.whiteboard-secret`
  (0600) so it survives re-runs — regenerating it would silently break
  collaboration — and deliberately kept out of `corex-credentials.txt`, whose
  format is parsed by exact grep patterns in phase 0.

### Fixed — Nextcloud setup warnings
- **HSTS header missing on tunnel traffic.** Traefik's `nc-headers` middleware
  sets `Strict-Transport-Security`, but Cloudflare Tunnel connects directly to
  `nextcloud:80` and never traverses Traefik, so requests arriving through the
  tunnel carried no HSTS header and Nextcloud's setup checks reported it as not
  set. Now also set at the Apache layer with `Header always setifempty`, which
  covers both paths without duplicating Traefik's value on the LAN path.
- **`maintenance_window_start` was never configured**, so Nextcloud ran heavy
  daily jobs (file scans, preview generation, cleanup) whenever cron fired,
  including during peak use. On a mini server those jobs are a thermal event as
  well as a performance one, so it is now pinned to 01:00 UTC.
- **`nextcloud.log` grew unbounded** — it is written by PHP, not Docker, so the
  daemon's `json-file` rotation never applied to it. Observed at 91MB in the
  field. `log_rotate_size` is now 10MB.
- **Missing database indices were never added.** Nextcloud and its apps
  introduce indices over time but never apply them automatically, so the admin
  panel accrues "Database missing indices" warnings and the affected queries
  stay slow (15 were outstanding in the field). `occ db:add-missing-indices` now
  runs on deploy; it is idempotent and a no-op when nothing is missing. The
  mimetype migration is deliberately left manual, as it can take a very long
  time on a large instance.

### Fixed
- **`corex manage health` labelled a live reading as pre-crash evidence.** On
  detecting an unclean shutdown it printed the last line of `blackbox.log`
  under "Last health sample before it died" — but that line comes from the
  *running* system, so a perfectly healthy current reading was presented as the
  state at the moment of the crash. It now selects the last sample recorded
  before the current boot began, and says so plainly when none exists (e.g.
  the blackbox was not yet installed during that boot).
- **A successful `corex update` dropped the user on the interactive-setup
  screen.** `do_update` ended with `exec bash corex.sh "$@"`, but inside that
  function `"$@"` is the function's own arguments and all three call sites
  invoke `do_update` with none. The re-exec therefore ran `corex.sh` with an
  empty argument list and fell through to the no-args path, printing
  "CoreX Pro v2 — Interactive Setup" — which reads as though updating had
  launched the installer. Nothing runs after an update, so the re-exec served
  no purpose; it now reports success and returns.

## [v3.1.1] - 2026-09-02

### Fixed
- **`corex manage health` reported "clean" for unclean shutdowns.** `grep -c`
  prints `0` *and* exits non-zero when nothing matches, so the trailing
  `|| echo 0` fired as well and the variable became the two-line string
  `"0\n0"`. That compares unequal to `"0"`, so the unclean-shutdown branch was
  never taken — the one check specifically meant to detect a thermal trip or
  power loss silently claimed the last shutdown was fine. The same pattern also
  produced a visible `((: syntax error` on the thermal shed count, and affected
  the pending-package count in `os-upgrade` and the container count in
  `network-check`. All four now assign the fallback with `|| var=0` so the
  fallback replaces the value instead of appending to it.

## [v3.1.0] - 2026-09-02

### Fixed — `corex update` reported "already up to date" while behind

`do_update` compared only the `COREX_VERSION` string between local and
`origin/main`. Any commit pushed without a version bump — the normal case for
a hotfix — was therefore invisible: the command printed "Already up to date"
and pulled nothing, leaving users on stale code with no indication. At the time
this was found the repo was 8 commits ahead of the v3.0.0 tag and `update`
still reported no changes available.

Commits behind (`git rev-list --count HEAD..origin/main`) is now the
authoritative signal; the version string is only used for display. The command
also now lists the incoming commit subjects, so what is arriving is visible
even when the CHANGELOG has no section for it yet, and reports the resulting
commit hash after updating.

Also fixed the changelog preview, which grepped for `## [3.0.0]` while the
CHANGELOG writes `## [v3.0.0]` — so it silently matched nothing and no
changelog was ever displayed. It now accepts either form.

### Added — Resilience & self-healing

The goal is a mini server that tolerates its own failure modes instead of
needing a human. All of the following came out of diagnosing a real crash loop
where a Ryzen 9 5900HX thermal-tripped every ~5 minutes.

- **Thermal guardian** (`lib/thermal.sh`). Mini servers run mobile-class CPUs in
  chassis with marginal cooling; at TjMax the CPU fires THERMTRIP, an instant
  hardware power cut that logs nothing and flushes nothing. The guardian samples
  temperature every 30s and sheds container load progressively instead:
  unmanaged containers first (Coolify apps etc., which carry no resource
  limits and are the usual cause), then `ai`, then
  `monitoring`/`productivity`/`storage`/`backup`. `core`, `security` and
  `communication` are never shed, so the box stays reachable. Shed containers
  restart automatically once temperature drops below the recovery threshold.
  At 97°C it performs a graceful shutdown rather than waiting for THERMTRIP.
  Shed order derives from the existing `SERVICE_CATEGORY`, so no service module
  needed changing. Thresholds and the enable flag live in
  `/etc/corex/thermal.conf`; `THERMAL_NEVER_SHED` protects `ups` regardless of
  category. 3-sample hysteresis prevents a transient spike from shedding load.
- **Boot self-repair** (`lib/selfheal.sh`). Ubuntu does not repair a dpkg
  database left broken by an interrupted transaction — it stays broken until
  someone runs `dpkg --configure -a` by hand, while every unattended-upgrade
  run fails or worsens it. `corex-boot-repair.service` now runs before the apt
  timers, detects an unclean shutdown via a marker file (far more reliable than
  grepping a journal that an unclean shutdown truncates), repairs dpkg,
  flags kernel packages needing reinstall, and checks the data pool's
  filesystem state.
- **`corex manage health`** — host hardware health, which service checks never
  covered: CPU temperature with verdict, thermal guardian state and what it has
  shed, whether the last shutdown was clean, dpkg integrity, per-disk SMART
  (including `-d sat` fallback for USB bridges), and swap pressure.
- **`corex manage os-upgrade`** — supervised OS upgrade that refuses to start
  when an interrupted dpkg transaction is likely: CPU at or above 85°C, dpkg
  already dirty (it repairs first, then re-checks), or uptime under 15 minutes.
  Overridable with `--force`. Always reconciles with `dpkg --configure -a`
  afterwards regardless of the upgrade's exit status.
- **Docker start delayed 15s** so ~38 containers no longer start while the
  kernel, SSD mount and journald compete for CPU. This does not stagger
  individual containers; the thermal guardian handles the residual surge, and
  now begins sampling at 45s so it is watching while the surge happens.
- `test/unit/test_thermal.bats` — 15 tests covering the now load-bearing
  `SERVICE_CATEGORY` contract, shed-tier partitioning, threshold ordering and
  hysteresis, and bash-validity of both generated helper scripts.

### Fixed
- **UFW silently dropped and logged all Docker Swarm / Coolify overlay traffic.**
  `lib/security.sh` allowed only `docker0` and `172.16.0.0/12`, but Swarm-based
  services (Coolify) allocate overlay networks from `10.0.0.0/8`. Every overlay
  packet (e.g. `10.0.1.x -> 10.0.0.1`) was dropped and kernel-logged every
  10-60 seconds, producing a continuous `[UFW BLOCK]` flood that buried real
  security events. Added an explicit `10.0.0.0/8` allow rule and an explicit
  `ufw logging low` so the intent is recorded rather than inherited.
- **`vm.dirty_ratio` lowered from 40% to 10%** (`dirty_background_ratio` 10 -> 5,
  added `dirty_expire_centisecs=3000`). Allowing 40% of RAM to hold un-flushed
  writes meant multiple GB of unwritten data during heavy transfers; on an
  unclean shutdown all of it is lost, risking MariaDB/PostgreSQL corruption. It
  also caused multi-second stalls on flush.

### Added
- **Systemd journal size cap** (`/etc/systemd/journald.conf.d/99-corex.conf`).
  journald previously ran with its default of 10% of the filesystem and was
  never bounded. Now `SystemMaxUse=500M`, `SystemKeepFree=1G`,
  `MaxRetentionSec=1month`, with `Storage=persistent` retained so post-crash
  forensics remain possible.
- **Blackbox crash-forensics recorder** — `corex-blackbox.timer` samples
  temperature, load, memory, swap, CPU throttle count and container count to
  `/mnt/corex-data/blackbox.log` every 20 seconds. An unclean shutdown leaves
  nothing in the journal because journald never flushes; this makes the last
  line before a crash the diagnostic. Self-truncating at ~20MB.
- **Hardware watchdog** (`RuntimeWatchdogSec=60s`) so a hard kernel hang
  triggers an automatic reset instead of leaving the machine dark until it is
  manually power-cycled.
- **`lm-sensors` and `smartmontools`** added to the install package set. Neither
  was previously installed, so no temperature or SMART disk health data was
  available on any CoreX system.

### Changed
- **`corex manage cleanup` now actually reclaims the bulk of recoverable space.**
  It previously pruned only stale images, build cache and `/tmp`. It now also
  vacuums the systemd journal (30 day / 500M), clears the apt cache, prunes
  unused Docker networks, removes rotated logs older than 30 days, and reports
  before/after free space per filesystem. Docker volumes remain deliberately
  un-pruned. `apt-get autoremove --purge` is reported but not executed, since a
  dpkg transaction interrupted by a crash can remove a running kernel.
- **Unattended-upgrades no longer performs kernel upgrades.** Restricting
  `Allowed-Origins` to `-security` is not sufficient protection: Ubuntu ships
  kernel updates *through* the security origin. An unattended kernel upgrade is
  the most dangerous unsupervised operation on a mini server — it raises CPU
  load, and an interruption leaves `systemd` and `libc-bin` unconfigured, which
  can render the machine unbootable. `linux-*`, `libc6`, `libc-bin`, `systemd`
  and `udev` are now explicitly blacklisted and applied only via
  `corex manage os-upgrade`. `Remove-Unused-Kernel-Packages` is also now
  `false`, since removing a kernel is itself a dpkg transaction and a
  known-good fallback kernel is worth the disk space.

---

## [v3.0.0] - 2026-06-04

### Added
- **CoreX Dashboard (Go + HTMX)** — browser-based management UI at `https://dashboard.DOMAIN`
  - 4 tabs: Services, Storage, Network, System
  - Services tab: health status cards (HEALTHY/UNHEALTHY/MISSING), Start/Stop/Update actions, real-time log viewer via SSE
  - Storage tab: raw `corex manage storage` output + Cleanup / Preview Cleanup buttons
  - Network tab: service URL table with health badges + LAN setup reminder
  - System tab: host info (hostname, kernel, uptime, Docker/CoreX versions) + quick-reference command reference
  - `hx-boost` navigation — full page re-render on tab switch keeps nav active state correct
  - Input validation on all API endpoints (service names and actions allowlisted)
  - Log streaming via Server-Sent Events (`/api/logs/<container>`) — cancel on tab close / Escape key
  - Single Go binary ~15MB image (`golang:1.22-alpine` builder → `alpine:3.20` runtime)
  - Embedded templates/static via `//go:embed` — no files outside the binary
  - `dashboard/Dockerfile`, `dashboard/go.mod`, `dashboard/main.go`, `dashboard/templates/*.html`, `dashboard/static/tailwind.min.css`
- **CrowdSec firewall bouncer** — `crowdsec-firewall-bouncer-iptables` installed on host, adds iptables DROP rules for flagged IPs (previously CrowdSec collected intel but never blocked)
  - Bouncer connects to CrowdSec LAPI on `127.0.0.1:8081` (container port 8080 exposed to host port 8081 to avoid conflict with Traefik API on :8080)
  - API key auto-generated via `cscli bouncers add --force` (idempotent on re-run)
  - `crowdsec_repair()` restarts bouncer service; `crowdsec_destroy()` uninstalls package
- **CrowdSec `crowdsecurity/nginx` collection** added alongside existing linux/traefik/http-cve/sshd/nextcloud
- **`corex manage network-check`** — read-only diagnostic that tests HTTPS reachability (HTTP status code), SSL certificate expiry (days remaining), and DNS routing (LAN vs WAN) for every installed service. Also checks Traefik API health and Docker network membership for `proxy-net`, `monitoring-net`, and `ai-net`.

### Changed
- **Nextcloud before-starting hook: sed → occ** — all `config.php` edits now use `occ config:system:set` and `occ config:app:set` instead of `sed -i "s|);|...|"` (fragile, injection-prone). Introduced `_occ()` helper with 6-attempt retry loop. `config:system:set` writes directly to `config.php` (no DB dependency); `config:app:set` retries cover DB startup delay.

---

## [v2.5.0] - 2026-06-04

### Security Fixes (Critical)
- **Bash injection via eval in wizard.sh** — replaced with safe `printf+IFS read` pattern (no eval)
- **Traefik dashboard on all interfaces** — bound to `127.0.0.1:8080` only; UFW rule for 8080 removed
- **Vaultwarden open signup** — `SIGNUPS_ALLOWED` now defaults to `false`
- **Stalwart password from Docker logs** — pre-generated, passed via `STALWART_ADMIN_SECRET` env var
- **Restic password in world-readable backup script** — single-quoted heredoc; runtime read from credentials file
- **Temp file leaks in state.sh** — `trap 'rm -f "$tmp"' RETURN` added to all 5 `mktemp` functions

### Security Fixes (High)
- **awk credential parsing** — replaced with `sed 's/^[^:]*: //'` (handles passwords with spaces)
- **Dangerous glob in rm -rf** — `"${DATA_ROOT}/${svc}"*` → exact path, no glob
- **Silent `git reset --hard` on update** — confirmation flow, `git pull --ff-only`, `bash -n` post-validation
- **`log_warning` undefined in corex.sh** — added standard logging functions block

### Added
- Docker log rotation: `json-file` driver, `max-size: 10m`, `max-file: 3` (30MB cap per container)
- Docker on SSD opt-in via wizard (`DOCKER_ON_SSD` state, `data-root` in daemon.json)
- Per-service resource limits: `deploy.resources.limits` on all 14 service containers
- `corex manage storage` — OS disk, SSD, per-service data breakdown, Docker usage
- `corex manage cleanup [--dry-run]` — safe image/cache cleanup (no `docker system prune`)
- Prometheus disk alerts: SSD < 15% free, OS disk < 10% free (`alerts.yml`)
- Backup integrity verification: `restic check --read-data-subset=5%` after each backup
- Restore `--list` (snapshots only) and `--dry-run` (preview) flags
- Immich DB health check: `pg_isready -U postgres` with 30s start period
- Separate `BROWSERLESS_TOKEN` credential (was shared with `WEBUI_SECRET_KEY`)
- CrowdSec `crowdsecurity/nextcloud` collection added
- `lib/services/dashboard.sh` — plugin stub for upcoming Go+HTMX web UI (v3.0.0)
- Conditional directory creation — only creates dirs for selected services

### Changed
- `state.sh` `_COREX_VERSION`: `2.0.0` → `2.4.2` (version sync fix)
- `corex.sh` version: `2.4.0` → `2.5.0`
- `generate_pass()` entropy: 32 input bytes → 32 output chars (was 24 bytes, fewer chars after stripping)
- Nuke log path: `/tmp/` → `/var/log/` (survives reboot, audit trail)
- `cmd_update` digest check: skips pull+restart when remote digest matches local
- Unattended upgrades: proper `/etc/apt/apt.conf.d/50unattended-upgrades` (security-only, no auto-reboot)

---

## [v2.4.2] - 2026-03-09

### Added

- **HEVC video streaming via Memories** — iPhone `.mov` files (HEVC/H.265) cannot play in Chrome or Firefox natively. Added the Memories app with internal go-vod transcoding (Memories v7+ ships its own `go-vod-amd64` binary in `bin-ext/`). Transcodes on-demand to H.264 HLS adaptive bitrate streams for cross-browser playback. Falls back to the original stream if transcoding fails. ffmpeg is auto-installed in the Nextcloud container (skipped on restarts, only runs on recreate).

### Fixed

- **CalDAV/CardDAV redirect broken by docker-compose variable interpolation** — The CalDAV redirect regex replacement `https://$1/remote.php/dav/` used `\${1}` in the heredoc, which docker-compose interprets as a variable reference (producing empty string). Fixed by using `$$1` (docker-compose escape for literal `$`).
- **Memories config layer mismatch** — Memories reads transcoding settings from `config.php` via `config:system:set`, not from the database via `config:app:set`. Settings are now written to the correct config layer with proper `--type bool` for boolean values.
- **Upload speed regression after revert** — Extracted `_nextcloud_write_compose()` helper so `nextcloud_repair()` regenerates docker-compose.yml (previously repair only force-recreated from stale compose). Added `--remove-orphans` to clean up removed containers.

### Removed

- **ClamAV antivirus** — Removed. Hard `depends_on: service_healthy` risked blocking Nextcloud startup if ClamAV was slow. Not needed for a single-user homelab.
- **External go-vod container** — Removed. The `radialapps/go-vod:latest` container tried to download its binary from a Memories endpoint (`/static/go-vod`) that no longer exists in Memories v7+. Memories now handles transcoding internally.
- **`enabledPreviewProviders` override** — Removed. Replacing the entire default provider list broke preview generation for common file types.

---

## [v2.4.1] - 2026-03-07

### Fixed

- **Nextcloud "Unknown error during upload"** — Multiple issues caused file uploads to fail silently:
  - **`APACHE_BODY_LIMIT` not set** — Apache 2.4.54+ changed the default `LimitRequestBody` from unlimited to 1GB. The Nextcloud Docker image inherits this default, silently rejecting uploads >1GB. Now explicitly set to `0` (unlimited) via the official `APACHE_BODY_LIMIT` env var.
  - **`.htaccess` overrides server config** — Nextcloud regenerates `.htaccess` on every startup, and `AllowOverride All` means it can override `conf-enabled/` settings. Before-starting hook now patches `.htaccess` with `LimitRequestBody 0` after Nextcloud creates it (background process, adapted from Umbrel's post-start hook pattern).
  - **`max_chunk_size` occ command ran as root** — Created cache files with wrong ownership and failed silently (`2>/dev/null || true`). Now runs via `gosu www-data` with a 30-second retry loop for database readiness.
  - **PHP JIT instability** — `opcache.jit=1255` (aggressive tracing mode) known to cause segfaults in Nextcloud's chunked upload and WebDAV code paths. Disabled JIT — OPcache without JIT provides 95% of the performance benefit for I/O-bound workloads.

### Added

- **MariaDB health check** — `healthcheck.sh --connect --innodb_initialized` with 30s start period ensures database is ready before Nextcloud starts. Before-starting hooks that run `occ` commands now reliably find the database.
- **Redis health check** — `redis-cli ping` with 5s start period. Combined with `depends_on: condition: service_healthy` for proper startup ordering.
- **Nextcloud cron container** — Dedicated `nextcloud-cron` container runs background jobs (`/cron.sh`) so they don't compete with web request PHP workers. Shares the same data volume and image.
- **Security headers** — Added `X-Robots-Tag: noindex,nofollow` (prevents search engine indexing) and `Permissions-Policy: interest-cohort=()` (blocks FLoC tracking) via Traefik middleware.

### Changed

- **`depends_on` with health checks** — Nextcloud app and cron containers now use `condition: service_healthy` instead of simple service dependency, eliminating the race condition where hooks fail because the database isn't ready.
- **Triple-layer body limit fix** — `APACHE_BODY_LIMIT=0` env var + `LimitRequestBody 0` in `conf-enabled/` + `.htaccess` patching. Defense in depth against Apache's 1GB default.

---

## [v2.4.0] - 2026-03-07

### Fixed

- **Browser LAN bypass via SVCB/HTTPS DNS records** — Cloudflare publishes SVCB/HTTPS (Type 65) DNS records containing embedded IPv4/IPv6 address hints and ECH (Encrypted Client Hello) configuration. Chrome, Edge, and Firefox query these records and connect directly to the embedded Cloudflare IPs, completely bypassing AdGuard's A-record wildcard rewrite. `lan-setup` now blocks `||domain^$dnstype=SVCB` and `||domain^$dnstype=HTTPS` via AdGuard's filtering rules API.

- **Browser LAN bypass via QUIC Alt-Svc caching** — Chrome caches HTTP/3 QUIC connections to Cloudflare via the `Alt-Svc` HTTP header. Even after DNS changes, Chrome reuses these cached connections for up to 30 days. `lan-setup` now prints Chrome/Edge policy instructions to disable QUIC (`QuicAllowed=false`) and the built-in DNS client (`BuiltInDnsClientEnabled=false`) per platform.

- **Browser LAN bypass via IPv6** — When a domain uses Cloudflare, AAAA records point to Cloudflare IPv6 edge servers. Browsers prefer IPv6 over IPv4, so even with a correct A-record rewrite to the LAN IP, the browser connects via IPv6 to Cloudflare. `lan-setup` now prints IPv6 disable instructions per platform (macOS `networksetup`, Windows `Disable-NetAdapterBinding`, Linux `sysctl`).

- **Nextcloud upload failures via Cloudflare Tunnel** — Default chunk size (100MB) exceeds Cloudflare free plan's 100MB body limit, causing HTTP 413 errors on large file uploads. Now set to 10MB (10485760 bytes) via `occ config:app:set files max_chunk_size` in the before-starting entrypoint hook.

- **Secondary DNS defeating LAN fast-path** — `lan-setup` previously recommended `1.1.1.1` as secondary DNS. DNS race conditions meant some queries hit the fallback server, returning Cloudflare IPs instead of the LAN IP. Steps 1 and 2 now explicitly warn against setting a secondary DNS server.

### Added

- **Self-signed CA + wildcard certificate generation** — Traefik now auto-generates a CoreX Pro CA and `*.DOMAIN` wildcard certificate on deploy. The wildcard cert is served as Traefik's default TLS certificate via a file provider (`dynamic.yml`). LAN clients that trust the CA get valid HTTPS without Let's Encrypt, which is critical for setups where TLS-ALPN-01 challenges are blocked by NAT or ISP restrictions.

- **Traefik file provider** — Added `providers.file` configuration in `traefik.yml` pointing to `dynamic.yml`. This loads the default wildcard cert store alongside the existing Docker provider and ACME resolver. Let's Encrypt certs take priority when available.

- **`lan-setup` Step 4: Browser Configuration** — Platform-specific instructions for disabling Chrome/Edge QUIC caching and built-in DNS client. Covers macOS (`defaults write`), Windows (registry policies), and Linux (JSON policy files).

- **`lan-setup` Step 5: Disable IPv6** — Platform-specific instructions for disabling IPv6 on the LAN interface to prevent Cloudflare IPv6 bypass. Covers macOS (`networksetup -setv6off`), Windows (`Disable-NetAdapterBinding`), and Linux (`sysctl`).

- **`lan-setup` Step 6: Trust CA Certificate** — Instructions for trusting the CoreX Pro CA cert on macOS (Keychain Access), Windows (Certificate Manager), iOS (Profile Install + Trust Settings), and Android (Install from storage).

- **`lan-setup` SVCB/HTTPS DNS blocking** — Automatically adds AdGuard custom filtering rules via the `set_rules` API to block SVCB and HTTPS DNS record types for the domain.

- **`lan-setup` verification improvements** — Updated verify section with browser DevTools instructions (check for `cf-ray` response header), browser restart guidance, and improved troubleshooting pointers.

### Changed

- **`lan-setup` DNS advice** — Steps 1 and 2 now warn against setting a secondary DNS server, as DNS race conditions with fallback servers are the most common reason the LAN fast-path fails.
- **Traefik `docker-compose.yml`** — Added volume mounts for `dynamic.yml` and `certs/` directory.
- **Traefik `traefik_repair()`** — Now regenerates LAN certs and `dynamic.yml` if missing before force-recreating containers.
- **Traefik `traefik_credentials()`** — Now prints the CA cert path when available.
- **Nextcloud before-starting hook** — Now also sets `max_chunk_size` to 10MB via `occ` command.

### How it works

When a domain uses Cloudflare (proxy enabled), browsers have five independent paths that can bypass the AdGuard DNS rewrite and route traffic through Cloudflare instead of the LAN:

1. **A-record lookup** → solved by AdGuard wildcard DNS rewrite (existing)
2. **SVCB/HTTPS (Type 65) DNS records** → contain embedded Cloudflare IPs that browsers query directly → solved by AdGuard filtering rules
3. **HTTP/3 QUIC Alt-Svc cache** → Chrome caches QUIC connections to CF for 30 days → solved by Chrome policy
4. **Browser built-in DNS** → bypasses system DNS entirely → solved by Chrome policy
5. **IPv6 AAAA records** → browsers prefer IPv6 to CF over IPv4 to LAN → solved by disabling IPv6 on LAN interface

All five layers must be addressed for the LAN fast-path to work reliably. The `lan-setup` command now handles all of them: layers 1-2 are automated via AdGuard API, layers 3-5 are guided with per-platform instructions.

**For existing installations:** Re-run `sudo bash corex-manage.sh lan-setup` and follow the new Steps 4-6.

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

[v2.4.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.4.0
[v2.3.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.3.0
[v2.2.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.2.0
[v2.1.1]: https://github.com/itismowgli/corex-pro/releases/tag/v2.1.1
[v2.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.1.0
[v2.0.1]: https://github.com/itismowgli/corex-pro/releases/tag/v2.0.1
[v2.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v2.0.0
[v1.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.1.0
[v1.0.0]: https://github.com/itismowgli/corex-pro/releases/tag/v1.0.0
[v0.1.0]: https://github.com/itismowgli/corex-pro/releases/tag/v0.1.0
