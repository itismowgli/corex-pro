# Changelog

All notable changes to CoreX Pro will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v3.24.0] - 2026-09-05

### Changed
- **The dashboard navigation is a sidebar rather than a row of tabs.** Nine
  sections had outgrown a tab strip: on a wide screen they wrapped, and on a
  phone they were a dropdown that gave no sense of where anything lived. The
  sections are now grouped by what you came to do, as Dashboard, Services,
  Monitoring and Machine, in a fixed left column that collapses to an icon
  rail and is remembered per browser. Below the medium breakpoint that same
  column is a drawer opened from the header, so one list serves both and
  neither can drift from the other.

  The column is fixed, which settles an older rule structurally. Nothing
  rendered on the page can push the navigation off screen any more, because
  the navigation is not on the page.

- **Cmd+K opens a command palette.** It searches the sections, the box-wide
  commands, and every service by name, offering restart, logs and the
  service's own address. Words match in any order, so "restart next" finds
  Nextcloud without knowing the wording. The list is assembled by the app from
  the same handlers the buttons use, never redefined, because a palette that
  defines its own actions is a second place for an action to be wrong.

  Written out rather than added as a dependency, for the reason in gotcha #35:
  this page fetches nothing at runtime.

- **The Overview tiles read as a value against a capacity.** Temperature
  against the shed threshold, load against the core count, memory against
  total, containers running against containers present. Each carries a bar and
  takes its colour from where it sits, which is what makes a number legible
  without knowing the machine: 4.0 is idle on sixteen cores and a queue on
  two. The sparklines and the click through to what is consuming a vital are
  unchanged.

- **Cards are rounder, with a lighter border and a soft shadow**, set once in
  `ui/card.tsx` and `index.css` rather than per panel.

- **Every section opens with its own heading**, drawn by `page-header.tsx`
  from the same list the sidebar and the palette read, so a section cannot be
  described one way in the palette and another at the top of its own page. The
  branding moved to the topbar, which is where the reference keeps it.

- **The Overview charts take a time range**, 30 minutes, 1 hour or the full
  two hours the blackbox holds. The alarms below deliberately do not follow
  it: an alarm that narrowed with the chart would answer "did this box
  throttle" with whichever window happened to be selected.

- **Storage opens with the same tiles as Overview.** The data SSD, the OS
  disk, what Docker occupies and what is purgeable, each as a value against
  its capacity. The tile itself is now `stat-tile.tsx` and both pages draw it,
  rather than each inventing a presentation for the same kind of number.

### Fixed
- **Three service modules were offered by no install preset at all.** The
  dashboard, the shared login and the UPS monitor could only be reached by
  choosing "custom", because the presets were hand written lists and adding a
  module never touched them. The "all services" preset is now read from
  `lib/services/` itself, so a new module is in it by definition, and a unit
  test fails when any module is offered by no preset. The test that should
  have caught this was called "apply_profile full includes all services" and
  checked three of them.

- **`SERVICE_NEEDS_DOMAIN` was declared by all eighteen modules and read by
  nothing.** A LAN-only install therefore selected services that answer on a
  hostname it does not have: the "no domain" preset offered the monitoring
  stack, and the custom checklist offered Cal.com and Stalwart. The wizard
  reads the field now. The LAN-only preset is derived from it, services that
  need a domain are not listed on a LAN-only install and are named as such,
  and anything a preset selects that cannot work is dropped with a line saying
  which and how to add it later.

- **Services were deployed in whatever order they were listed.** Traefik
  creates `proxy-net` and owns the routing every other web service registers
  with, and the installer deploys in array order, so a custom selection built
  from the checklist deployed AdGuard first. Selection is sorted into deploy
  order now: Traefik, AdGuard and Portainer, then by category, which also puts
  Authelia ahead of the services whose routers name its middleware. A router
  naming a middleware that does not exist yet answers 404 rather than falling
  back, which is gotcha #44.

- **`apply_profile` could abort the installer.** Its LAN-only branch ended in
  `cond && array+=(...)`, so it returned non-zero whenever the last module
  tested needed a domain, and `install-corex-master.sh` runs with `set -e`.
  Found by running the new tests under bats, which checks a return status that
  an interactive shell throws away.

- **The preset menu quoted RAM figures written when the presets were.**
  "~8GB RAM" for minimal and "~32GB RAM" for full were both wrong. The menu
  sums `SERVICE_RAM_MB` from the modules at the moment it is drawn.

### Removed
- `ui/tabs.tsx` and `@radix-ui/react-tabs`, which nothing imports now.

### Testing
- Ten new wizard tests: that every module is in the full preset and in at
  least one preset, that the LAN-only preset and filter honour
  `SERVICE_NEEDS_DOMAIN`, that Traefik is deployed first from every preset,
  that Authelia precedes what it protects, and that the field is read by
  something outside `lib/services/`.
- `responsive-check.mjs` rules 5 and 6 are rewritten for the sidebar. They
  check that the fixed column is hidden on a phone, that a drawer and the
  control that opens it both exist, and that no banner or running job renders
  above that control. Each was confirmed by putting the fault back.
- `render-check.mjs` asserts every section name is present on every mount,
  that each one drew an `h1`, and opens the palette with a synthetic Cmd+K, because a palette is closed until
  someone presses a key and no other check could see it. It looks for a
  section, a box-wide command, and a service action built from the services
  payload: the last of those can only appear if the palette read the live list.

---

## [v3.23.1] - 2026-09-05

### Fixed
- **Uptime Kuma seeding had never once worked.** The declarations were piped to
  the seeder on stdin while the Python program was supplied by a heredoc on the
  same stdin. The heredoc is the later redirection, so it won: the program
  loaded correctly and then read an already-consumed stdin, iterated zero
  monitors, and reported success. Every run since the feature shipped did
  nothing, which is why the monitors on this box had all been inserted by hand
  and why a newly installed service was never watched. The declarations go in a
  file now.

- **And once it ran, it skipped almost everything.** The reachability probe
  resolved each hostname normally, which sends the request out to Cloudflare
  and back down the tunnel: Cloudflare answers a bare `Python-urllib` user
  agent with 403, so every check was recorded as "does not answer acceptably
  yet". It connects to the server directly with the hostname in the Host
  header now, which is both the truer test and the faster one, because Kuma
  itself sits inside the Docker network and reaches Traefik directly.

  Two skips are legitimate and remain: a service whose container is
  deliberately disabled, and Uptime Kuma's own hostname, which cannot answer
  while the seeder has it stopped.

---

## [v3.23.0] - 2026-09-05

### Fixed
- **Authelia in front of n8n was the wrong fit, and is removed.** Three
  reasons, two of them measured. Its webhook endpoints needed a bypass list to
  keep working at all. Its interface is a single-page app, and Authelia answers
  an XHR with 401 rather than a redirect, so `/rest/settings` returned 401 and
  the app could not recover: no XHR can follow a redirect to a login page. And
  n8n has its own user management, so the portal was a second prompt for a door
  that already had a lock.

  Verified after removal, from a tunnel-shaped address: the interface, the API
  and a webhook path all answer correctly.

- **Adding a service did not register its Uptime Kuma check.** Authelia is the
  proof: the module declared `SERVICE_MONITORS`, it was installed and healthy,
  and Kuma knew nothing about it, because seeding only ever ran from the
  installer or an explicit `kuma-seed`. `corex manage add` now registers the
  checks a module declares, so a service is watched from the moment it exists.
  A service nobody is watching is one that fails quietly, which is the entire
  point of the monitoring.

- **Portainer reported DOWN the moment the shared login went in front of it.**
  Its monitor accepted only 200-299 and the hostname now answers 302, a
  redirect to the portal, which means the router is up and the portal is
  answering. 302 is accepted now, the way Nextcloud and AdGuard already do for
  their own login redirects. A monitor that cries wolf is worse than no
  monitor, because it trains you to ignore the next alert.

---

## [v3.22.1] - 2026-09-04

### Fixed
- **The Authelia account was created with an address that cannot receive
  mail**, which with a `two_factor` policy is a lockout rather than an
  inconvenience: the registration link is emailed, so nobody could ever
  satisfy the second factor and every protected panel was unreachable.

  The address came from `state.json`, which holds the Let's Encrypt contact,
  `admin@DOMAIN` on a domain with no mailbox, because no mail server can
  receive on a residential line. It now prefers the relay account, which is an
  address the box demonstrably reaches since it is the mailbox it
  authenticates as in order to send at all, and it warns loudly when the
  chosen address is at the box's own domain.

---

## [v3.22.0] - 2026-09-04

### Added
- **`corex manage lan-only`, so a panel you only use from home stops being
  published.** A hostname nothing outside the house can reach cannot be
  scanned, probed or decided to look like a phishing page, which is a stronger
  answer than a login for Portainer, Grafana or AdGuard.

  It works because of how the tunnel is shaped: external traffic reaches
  Traefik from cloudflared's container address, which is not in the LAN range,
  so a Traefik `ipAllowList` refuses it with no `X-Forwarded-For` to reason
  about, while a browser at home reaches Traefik directly on 443. The
  middleware lives in the file provider, so it exists whether or not Authelia
  does, and `sso_label_for` builds the chain with the allowlist first: a
  request from the internet is refused before it costs a round trip to the
  portal.

  `n8n` is refused a place on the list by name. Its webhook endpoints are the
  reason it is published at all.

  This is also the practical answer to Chrome's "Dangerous site" interstitial
  on the admin hostnames. That warning is a false positive and putting a bare
  login form in front of them made it likelier, not less; not publishing them
  removes the question. An existing flag still has to be appealed by hand.

---

## [v3.21.1] - 2026-09-04

### Fixed
- **Authelia was intercepting every n8n webhook.** n8n is published so that
  other systems can call it, and a forwardAuth middleware on its router
  answered a POST to `/webhook/<id>` with a 302 to the login portal. Every
  incoming call from every external service failed, and silently as far as n8n
  was concerned, because nothing reached it to be logged. Measured after
  putting Authelia in front: all of `/webhook`, `/webhook-test`, `/form`, the
  OAuth callback and `/healthz` returned 302.

  Those paths are bypassed in the Authelia access control rules now, which is
  one list in one file rather than a second Traefik router whose priority has
  to be reasoned about. The n8n interface itself is still behind the portal.
  The endpoints are not unprotected by being open: they are protected by the
  unguessable id in the path, which is n8n's own design.

- **The dashboard fired a 26 second request on every page load.** `/api/storage`
  shells out to `corex manage storage`, which walks `/var/lib/docker` and every
  service directory with `du`: 26.7 seconds measured, most of it waiting on a
  USB-attached SSD. It ran on mount for every visitor whether or not they ever
  opened the Storage tab, pinning a core on a box that is thermally limited and
  dragging the whole page behind it.

  `usePoll` takes an `enabled` flag now, so Storage, Ports and Catalogue wait
  until their tab is opened, and the Go side caches the report for five minutes
  behind a single flight, so a reload during those 26 seconds joins the run in
  progress instead of starting a second one.

- **The vitals stream sampled once per viewer instead of once per box.**
  `collectVitals` runs `docker stats --no-stream`, which costs a full sampling
  interval: 1.16 seconds here. At a five second tick that is a quarter of a
  core for one open tab, half for two, and most of a core for three, for as
  long as a tab is left open. The dashboard was one of the hottest things on
  the box purely to draw itself.

  Subscribers share one loop now. It starts when the first arrives, stops when
  the last leaves, and a new subscriber is handed the most recent sample
  straight away rather than triggering one of its own.

---

## [v3.21.0] - 2026-09-04

### Added
- **A CPU clock ceiling, which is the first software answer to this project's
  oldest problem.** `corex manage power cpu <MHz>` caps `scaling_max_freq` and
  sets the energy performance preference, now and at every boot through
  `corex-cpu.service`. It is off by default, because it is hardware-specific
  tuning and CoreX does not guess at it.

  It was found by asking why an idle box was at 86C. `amd-pstate-epp` under the
  powersave governor still boosts to the top of the range when the energy
  performance preference is `performance`, which is what Ubuntu leaves it at.
  Measured on a Ryzen 9 5900HX mini server with 21 mostly idle containers,
  eight samples over a minute for each setting:

  | Setting | Mean | Cores |
  |---|---|---|
  | `performance`, no cap | 86.3C | 4.1 to 4.2 GHz |
  | `balance_power`, no cap | 83.0C | 3.2 to 4.0 GHz |
  | `balance_power`, 3.0 GHz cap | 76.8C | 2.4 to 2.9 GHz |

  Ten degrees, for a ceiling below a base clock the chassis cannot sustain
  anyway, so the peak given up is one the machine never actually held: it was
  boosting and then thermally shedding.

  It matters beyond comfort. `THERMAL_WARN_C` is 80, so at 86C the guardian sat
  permanently in its warn band, the shed list could never drain, and the
  maintenance governor would have paused forever. A number below the warn
  threshold is what makes either of them work.

### Fixed
- **The thermal guardian could leave containers shed indefinitely, and this is
  the third form of the same bug.** `recover` and `normal` both restore
  containers and differ only in batch size, but they counted as separate bands,
  so a box drifting across `THERMAL_RECOVER_C` reset the hysteresis counter on
  every crossing and never reached `THERMAL_CONFIRM_SAMPLES` in either.

  Measured: three containers stayed shed for six minutes while the temperature
  moved 70.2, 70.6, 75.8, 73.6, 75.2, 78.9, with the state file stuck at
  "recover 2". That band edge is exactly where a cooling machine sits, so it
  was not an edge case. The counter is now keyed on what the band will do
  rather than on its name.

  The first form of this was a recover threshold below the machine's idle
  floor, the second was restoring the whole list at once, and this is a counter
  that cannot count.

---

## [v3.20.1] - 2026-09-04

### Fixed
- **Every generated script is written atomically, not truncated where it is.**
  CoreX generates nine scripts into `/usr/local/bin`, and several are running
  when it regenerates them: the blackbox recorder every 20 seconds, the thermal
  guardian every 30, the resource watchdog every 60, and the maintenance runner
  for hours during a first Restic snapshot. Bash reads a script incrementally as
  it executes, so the running copy resumed at its saved byte offset inside
  content that had become something else.

  Reproduced on Ubuntu with a script long enough that bash cannot have buffered
  all of it: the old way ran garbage and exited 127 with
  `line 3: _SHORT: command not found`, the new way let the running copy finish
  its own tail and exit 0. Worth mentioning that the same test on macOS printed
  the new content and looked harmless, because a short script is read in one
  gulp and bash 3.2 differs, so a claim about process behaviour has to be
  measured on the platform the code runs on.

  `install_script` in `lib/common.sh` takes the content on stdin, writes it
  beside the destination and moves it into place, applying the mode after the
  move rather than inheriting `mktemp`'s 0600.

- `lib/selfheal.sh`, `lib/thermal.sh` and `lib/watchdog.sh` source `common.sh`
  explicitly instead of relying on the caller. They already depended on
  `log_info`, so nothing is new, but a missing `install_script` fails far worse
  than a missing log function: the generated script is never written, so the
  guardian does not exist and nothing says so.

---

## [v3.20.0] - 2026-09-04

### Added
- **Confirm who you are before something that cannot be undone.**
  `POST /api/auth/stepup` takes a password, a current TOTP code, or a passkey
  assertion with user verification required, and marks the session confirmed
  for five minutes. `requireElevated` sits beside `requireAuth` and guards
  the routes that need it, answering 403 with an `elevation_required` flag so
  the page can ask for a factor and retry rather than guess which kind of
  refusal it got.

  The passkey path is the one worth preferring, and the dialog says so: user
  verification means the authenticator checked a fingerprint, a face or a PIN
  just now, which proves someone is present. A password proves only that the
  browser still remembers one. It is still accepted, including on an account
  with two-factor enrolled, because a lost phone must not lock the operator
  out of their own power button.

  Confirmation is per browser, not per account: it is found by cookie, so
  confirming on a laptop does not arm a phone. A password change closes the
  window the old password opened. Every confirmation and every refusal lands
  in the access log.

- **Reboot and shut down, on the System tab.** Two new agent actions with
  their own branch, absent from `ACTIONS` because they are not corex-manage
  subcommands and absent from the Telegram bot on purpose: everything the bot
  can reach is reversible, which is what makes a stolen chat account
  survivable, and a poweroff is not.

  Both refuse while another job is running, announce to Telegram before acting
  rather than after (there is no after), and record who asked in the access
  log. The command is delayed four seconds so the reply and the message get
  out while there is still a network. Shutting down asks for the word
  SHUTDOWN to be typed, and says in those words that nobody can turn the
  machine on again from the network, including whoever is reading it.

  A clean shutdown is worth having on this hardware regardless. The last time
  this box went down it was a thermal trip at 93.5C with nothing flushed.

- **Wake-on-LAN, and an honest account of the rest.** `corex manage power`
  reads which interfaces can answer a magic packet and whether they are armed,
  and `power wol on` arms them now and at every boot through
  `corex-wol.service`, because ethtool writes to the driver and not to
  anything persistent.

  The dashboard cannot wake the box and never will: it runs on the machine and
  the tunnel goes down with it. So the Power card names what does work, in
  order, with a smart plug plus "restore on AC power loss" first, since it is
  the only option that also recovers a hung machine. Shipping a shutdown
  button without that is how someone locks themselves out of their own server.

- **Scheduled maintenance.** `lib/maintenance.sh` installs one hourly timer
  and a runner that decides what is due: a Restic backup daily, Docker cleanup
  weekly, a Time Machine check weekly, and a supervised OS upgrade monthly if
  it is turned on. One timer rather than four, because the tasks share a
  machine that thermal trips: exactly one may run at a time, each is refused
  above 85C, and that decision belongs in one place.

  A task overdue by half its interval again runs at the next opportunity
  instead of waiting for its hour, so a machine that is off overnight still
  gets its backup.

  The Maintenance tab reads the runner's own history rather than the schedule,
  which is the whole point: a page showing only the schedule would report a
  backup as configured on a box whose repository does not exist. A task that
  has never run says so, a missing prerequisite is recorded as a failure, and
  a run held back for temperature is neither of those. Failures go to
  Telegram. Installing the timer also removes the v1 backup entry from root's
  crontab, so the snapshot is not taken twice.

  os-upgrade is off by default and is the one task behind a confirmation. It
  is the only one here that can leave the machine unbootable: an unattended
  kernel upgrade interrupted by a thermal trip is what left this box with
  systemd unpacked and unconfigured.

- **Update is only offered when there is one.** `agent/corex_updates.py`
  compares every image in a service against its registry, once a day, on a
  background thread, and the Services tab shows "Update available" with what
  moved. A card the check is confident about loses the button and says the tag
  is current.

  The previous attempt at this had two bugs and both were easy to repeat. It
  read `config --images | head -1`, which is one image out of a stack that may
  ship five, and the one at the top was usually node-exporter. And it compared
  a local `RepoDigest` against a per-platform entry from `docker manifest
  inspect`, which are different digests by construction, so nothing ever
  matched. Every image is checked, and the registry is asked for the index
  digest with the index media types in the Accept header, which is the same
  thing the local image records.

  A third failure mode no digest comparison can see is a tag that has stopped
  moving. Where the registry will say when a tag was last built, that is read
  too, and a moving tag nobody has rebuilt in six months is its own state
  rather than being reported as current. Only tags that were meant to move are
  asked: a pinned `v6.2.0` is supposed to sit still, and calling that stale is
  the kind of noise that teaches people to ignore a badge.

  "unknown" is shown as itself. A registry that could not be reached leaves
  the Update button exactly where it was.

- **One sign-in, with two-factor, for the panels that have no real login.**
  `lib/services/authelia.sh` puts Authelia in front of Portainer, Grafana,
  AdGuard and n8n, and deliberately not in front of Vaultwarden, Nextcloud,
  Immich, Cal.com or the dashboard: every one of those has a login of its own
  and fronting them means signing in twice for one door.

  Newly possible rather than newly thought of. The tunnel used to point at
  container names, so Traefik was only in the path for LAN requests and a
  forwardAuth middleware would have protected nothing arriving from the
  internet. It is one wildcard route to Traefik now.

  Authelia and not Authentik, and on this hardware that is the whole argument:
  one Go binary in one container with a file backend and no Redis, against
  Python plus PostgreSQL plus Redis plus a worker on a box that thermal trips.

  The middleware label is conditional and has to be. A Traefik router naming a
  middleware Traefik cannot find does not fall back to serving the site: the
  router goes into an error state and the hostname answers 404. So
  `sso_protects` checks the config and that the container is running, and
  installing or removing Authelia regenerates the compose files of the
  services concerned. A service switched off with `corex manage disable` stays
  off; the label lands when it is enabled again.

  AdGuard gets a Traefik router for the first time, at `adguard.DOMAIN`, and
  keeps port 3000 published. That is the point rather than an oversight:
  AdGuard is the DNS, so a login that needs DNS must never be the only way to
  reach the thing that serves it. Uptime Kuma is excluded for the same kind of
  reason, being the page you open to find out why something is down.

  Two factors only where a registration link can be delivered. With the shared
  relay configured the policy is `two_factor`; without it, asking for a second
  factor would lock the operator out with no way to enrol a device, so it
  drops to one and notifications are written to a file the deploy names.

  The healthcheck is `GET /api/health` and not `authelia healthcheck`, which
  every self-hosting guide suggests and 4.39 does not have. That was not a
  cosmetic detail: Traefik's Docker provider ignores a container that is not
  healthy, so a check that could never pass made Authelia invisible to
  Traefik, the middleware its labels define did not exist, and three hostnames
  answered 404 while the error named them rather than the container that was
  missing.

### Fixed
- **There were no backups, and there could not have been.** Two faults, either
  of which was enough on its own, and both silent.

  The generated backup script read the Restic password with
  `sed 's/^[^:]*: //'`. `/root/corex-credentials.txt` is column aligned, so
  that takes one space off the padding and leaves the rest inside the
  password, while the repository was created from the properly trimmed value.
  restic answers "wrong password or no key found", which reads as a lost
  password rather than as two strings differing by whitespace.

  And the script ran all four restic commands without looking at any exit
  status, then logged "Backup complete". So a repository it could not even
  open reported a successful backup every night.

  Both are fixed, the repository on this box has been created, and
  `corex manage maintenance setup` rewrites the generated scripts rather than
  trusting whatever is installed, because a box from before v2.5.0 also has
  the Restic password written into a world-readable file.

- **A thermal shutdown no longer takes the services with it permanently.**
  The guardian stops every container and powers the machine off at TjMax,
  which is right and worked as designed during the first full backup. Coming
  back did not: `docker stop` on a container whose policy is `unless-stopped`
  means Docker will not start it at the next boot, so the box came up with 23
  containers stopped, 0 running, and nothing recording why.

  The emergency path now writes what was running before it stops anything, and
  the boot-time self-repair restores it three at a time with a temperature hold
  between. Not the shed list, which is only drained in the recover and normal
  bands and would never be drained on a box whose idle floor is above the warn
  threshold. It also announces itself to Telegram before acting, because there
  is no after.

- **Maintenance tasks are held to a thermal budget while they run, not only
  before they start.** The first full backup began at 66C and was at 96.8C six
  minutes later, and the guardian shut the machine down at 97C. The pre-flight
  check had passed correctly thirty degrees earlier, which is what gotcha #31
  says in as many words.

  restic now runs with `GOMAXPROCS=2`, because it is Go and compresses on every
  core otherwise, and with a cache directory, because under systemd there is no
  HOME and it was re-reading every file on every run. And the task is paused
  with SIGSTOP when it crosses the limit and resumed eight degrees lower.
  SIGSTOP rather than a kill: restic, apt and a Docker prune all resume with
  nothing lost.

  The signal walks the process tree rather than the process group. Inside a
  command substitution bash does not reliably make a background job its own
  group leader, so `kill -- -$pid` either fails or names the group the script
  is in, which stops the governor along with the task.

  Sampling is every five seconds, which was measured rather than chosen: with
  a fifteen second interval the 85C limit was first seen at 95C, because this
  hardware climbs ten degrees in fifteen seconds under a compressing backup.

- **`maintenance setup` no longer rewrites a script that is running.** It
  truncated `/usr/local/bin/corex-maintenance.sh` in place, and that script
  can be running for hours: bash reads a script incrementally, so a rewrite
  underneath a running copy makes it resume in the middle of whatever now
  occupies that offset. It is written to a temporary file and moved into
  place, with the mode set afterwards rather than inherited, which is the same
  trap gotcha #24 records for state.json.

- **AdGuard's admin port was read with a window too small to reach it.**
  `grep -A5 "http:"` no longer finds `address:` in `AdGuardHome.yaml`, because
  current AdGuard writes a `pprof` block and a `doh` routes list in there
  first and the line is eleven down. The fallback was 3000, so the generated
  mapping was `3000:3000` against a container listening on 80 and the admin
  panel stopped answering. `lan-setup` was fixed for this in v2.1.1; the
  module had its own copy of the parse, which was not.

- **`repair adguard` never rewrote resolv.conf after the first install.** The
  installer sets the immutable bit on `/etc/resolv.conf` (gotcha #7) and the
  deploy then tried to `rm` it, which fails with EPERM. It was the last
  command in a function whose status nobody checked, so the file was silently
  left as it was. The lock comes off first now.

- **A deferred maintenance run no longer counts as a run.** Measured on the
  first hot hour after the timer shipped: the backup came due during a
  dashboard rebuild, the CPU was at 86C, the runner correctly declined, and
  stamping the attempt as the last run meant it would not ask again for a day.
  A refusal to start is recorded separately, does not reset the clock, and the
  Maintenance tab shows it as its own line under the last real outcome.

- **The Restic repository now exists.** `/mnt/corex-data/backups/restic-repo`
  had never been created, so the nightly cron had been logging "Is there a
  repository at the following location?" and reporting "Backup complete" every
  night since installation. There were no backups at all. Nothing in the
  installer was wrong; the repository was simply never initialised on this
  box, and nothing checked. The maintenance runner now treats a missing
  repository as a failed run rather than a quiet success.

### Changed
- Root is 250GB rather than 100GB. It holds Docker's images and build cache on
  a box where a local image build is routine, it was 60% full with 38GB free,
  and 374GB of the NVMe was unallocated. `lvextend` plus `resize2fs`, live.
  223GB is left unallocated for a future fast tier for the databases.
- `corex manage agent show` lists the two power actions and the maintenance
  task separately from the rest, and says why the bot cannot reach them.
- The build checks grew a rule: a tab that mounts is not the same as a tab
  that rendered its data, so `render-check.mjs` now asserts one substring per
  tab that only a panel reading its fixture can produce. It also carries a
  wake-on-LAN entry the hardware supports and nobody armed, and one
  maintenance task of each outcome including one that has never run.
- `test/e2e/dashboard-auth.sh` drives the confirmation gate: a power action
  refused with the elevation flag, a wrong password that confirms nothing, a
  right one that lets the action through, an unknown power action refused even
  when confirmed, and a password change closing the window it opened.

---

## [v3.19.0] - 2026-09-04

### Added
- **The overview is live.** Temperature, load, memory, container counts and the
  heaviest containers arrive over Server-Sent Events every five seconds, and
  the page says whether the feed is connected. Polling left the numbers up to
  twenty seconds old, which for a temperature on hardware that trips at TjMax
  with nothing in any log is the wrong kind of stale. The heavier half of the
  payload, which walks both disks, reads Kuma's database and may wait on a
  `du`, stays on a slower poll: doing that every five seconds would spend more
  time measuring than waiting.

- **Click a number to find out whose it is.** Every vital opens the answer
  Activity Monitor and Task Manager give: a sorted list, biggest first, with a
  bar. Heat and load open the containers burning processor, memory opens them
  by resident size against their own limits, and disk opens both volumes and
  then space per service with what is purgeable. It refreshes while open,
  because the question being asked is what is doing this right now.

- **A mobile layout.** Tables scroll in their own box instead of pushing the
  page sideways, dialogs are capped to the viewport so the close control stays
  reachable, recovery codes are one column on a narrow screen, and the tab bar
  is one scrolling row rather than three wrapped ones.
  `responsive-check.mjs` holds four of those rules in the build, each one a
  mistake that was actually in the tree, and the render check now mounts every
  tab at 360px as well.

### Changed
- **`status` in Telegram says how the machine is, not just the services.** The
  reply opens with heat, load, memory and whichever disk is fuller, so one
  command answers whether anything is wrong. The full hardware report stays
  behind `health`, and the reply says so.
- **Telegram messages read like a person wrote them.** Every message is built
  in one place, so the bot, the job notices and the Uptime Kuma alerts share
  one shape: a headline in plain words, the detail, then the single next step.
  A phone notification shows two lines and then stops, so the first line has to
  carry the point.

  "temp DOWN: 83C, over the 80C limit" is now "Running hot at 83C, above the
  80C limit". "Heaviest:" is "Working hardest:". "OOM-killed, so its memory
  limit is too low" is "Killed for using too much memory, so the limit is set
  too low". Job notices said "restart nextcloud", which is a command rather
  than news, and now say "nextcloud has restarted".

  The Kuma template gains a blank line and a closing line that differs by
  state, and nothing more, deliberately: Telegram rejects a message whose
  MarkdownV2 does not parse, so a clever template that breaks on one monitor
  name silently turns monitoring off. It was rendered through the running
  Kuma's own Liquid engine before shipping.

- **The job strip says what happened; the tab shows the output.** Running a
  hardware check used to print the identical report twice on one screen. A
  failure with nowhere else to go still expands on its own.

- Two `code_block` implementations had drifted to opposite truncation rules,
  each with a written rationale, and both were right for their own case. One
  function now, with the mode named at the call site.

### Fixed
- **The hardware report appeared twice on one screen.** The job strip decided
  whether the tab below already owned the output by reading which action was
  running, and that is cleared the instant a job finishes, so the answer was
  always "no" by the time there was any output to place. The owning panel is
  recorded when the action starts and kept until the strip is dismissed.
- **Nothing renders above the tab bar any more.** A banner or a running job
  there pushed the tabs and everything under them down the screen, so opening
  the dashboard on a phone showed no dashboard.
- **The tab bar collapses into a select below the sm breakpoint.** Eight tabs
  in a scrolling strip means the one you want is usually off screen with
  nothing to say so.
- **The Account tab fits a phone.** The activity table's four columns do not
  fit at 360px, and squeezing them makes every column unreadable rather than
  one of them missing, so those rows stack. Addresses wrap, and a terminal
  block is capped to its container, since overflow alone still lets the block
  size the page.
- **A Telegram reply that failed to send left no trace at all.** The bot logged
  the command as received, sent nothing, and logged nothing else, which is
  indistinguishable from success on one side and from an unanswered command on
  the other. Telegram answers a message it cannot parse with a 400 naming the
  offending offset, and all of that was being discarded. The reason is now
  logged beside the first 120 characters of the refused message.
- The improved Telegram template would never have reached a phone.
  `apply_telegram_template` skipped any notification that already had one,
  which is gotcha #22 in a new place: a generated thing written only when
  absent never changes on an existing install. Every template CoreX has written
  is now listed and upgraded; anything an operator wrote is still left alone.

## [v3.18.0] - 2026-09-03

### Added
- **An Overview tab that shows the box rather than reporting on it.** The
  question this page is opened to answer is "is anything wrong", so that is now
  what it leads with. Temperature, load, memory and container count across the
  top, each with two hours of history; both disks with what is purgeable; the
  heaviest containers; every Uptime Kuma check; and what the resource watchdog
  has logged.

  Anything already wrong is gathered into a banner so it cannot be scrolled
  past: past the shed threshold, throttled recently, containers shed by the
  thermal guardian, an uptime check down, a SMART failure, a half-configured
  dpkg, a disk over 90%, a container restarting in a loop, or an unreachable
  agent.

  The history was free. `blackbox.log` already records temperature, load,
  memory, swap, throttling and container count every twenty seconds, because it
  is the only evidence that survives an unclean shutdown. The graphs read it
  instead of adding a second sampler.

- **Passkeys.** WebAuthn, replacing the password and the second factor in one
  step. They cannot be phished: the browser only signs for the origin the key
  was created on, so a convincing copy of the page on another hostname gets
  nothing. Enrolment is discoverable, so signing in asks for no username at
  all. An authenticator whose signature counter goes backwards is refused,
  because that is the documented signal of a cloned key.

  The password stays when a passkey is added. A passkey lives in one
  authenticator, and an operator locked out because a phone was lost is the
  failure this whole design exists to avoid.

- **A record of who signed in from where.** The account page lists the devices
  holding a session, with address and last activity, and can sign the others
  out. Below it is the account's own history: sign-ins, refusals, lockouts,
  password changes, two-factor changes and passkey changes, each with the
  address and the device it came from.

  The log is append-only and lives on the privileged side. That is the point
  rather than an implementation detail: a record of who signed in is worth
  something only if the thing being audited cannot quietly edit it.

- **A `metrics` action on the agent**, returning temperature, load, both disks,
  Docker's reclaimable space, the blackbox series, watchdog findings, SMART,
  the dpkg state and Kuma's monitor states as data. It is privileged because
  the container sees its own filesystem rather than the host's, so `df` in
  there measures the wrong thing, and bind-mounting the data root instead would
  hand a web-facing container every service's files and the bot token inside
  Kuma's notification config.

- **`corex manage kuma-seed`** now has a dispatch entry, so the HTTP checks each
  module declares can be created again at any time.

### Changed
- **Storage and Health show numbers instead of terminal output.** Storage
  opened with `[0;36m[1mCoreX Storage Report[0m`, because the panel rendered
  escape codes literally, and Health printed the same hardware report twice.
  Both are structured now: disk meters, a Docker usage table with a purgeable
  column, space per service, and heat with its own trend. The report each is
  rendered from is still one click away, because those commands remain the
  source of truth.

- **Logs are parsed rather than dumped.** A clock, a level and the message,
  aligned, with errors and warnings tinted and counted, plus a filter, level
  toggles, wrap, follow and copy. Four parsing faults were only visible against
  lines this box actually emits: Traefik's `WRN` was read as having no level,
  an access log's clock came out of the middle of the year, removing that
  timestamp left a bare `[]`, and a generic bracket strip turned `[MONITOR]`
  into `MONITOR]`.

- **The Catalogue has a category sidebar with counts, a search and a state
  filter**, and every entry shows the address it answers on, or would answer on
  once installed. "Needs a domain" was not something anyone could act on.

- **The Go builder moves to 1.25** for the WebAuthn library, which is this
  binary's first external dependency. `go.sum` is committed so the build
  resolves to the versions that were tested.

### Fixed
- A service with no browsable address blanked the entire dashboard. Go marshals
  a nil slice as JSON `null`, three services have no address, and
  `svc.urls.length` threw into the error boundary. The server now always emits
  an array and the components no longer assume.
- Rate limiting counted every internet visitor as one address. Traefik replaces
  `X-Forwarded-For` with its own peer unless told to trust the sender, so
  everyone shared a bucket and one attacker could lock every account out of the
  login. `Cf-Connecting-Ip` is read first.
- Rate limiting also counted successful sign-ins, so five logins across a phone
  and a laptop locked the operator out for fifteen minutes. Only failures
  count, and a correct password forgives the bucket.
- The longest service label pushed the status badge off its card. `CardHeader`
  is a grid, so `CardTitle` defaults to `min-width:auto` and would not shrink.
- `test/e2e/dashboard-auth.sh` was committed without its executable bit.

## [v3.17.0] - 2026-09-03

### Added
- **The dashboard has a login of its own.** Traefik basic auth cannot change
  its own password, cannot recover one, and has no idea who is signed in. The
  dashboard now has accounts: a login page, a password you can change, a
  display name, a forgotten-password code sent through the server's own mail
  relay, and two-factor authentication with an authenticator app.

  Accounts live in `/etc/corex/dashboard-users.json`, mode 0600 root. Not in
  `state.json`, which is 0644 and bind-mounted into the very container being
  protected. Passwords, recovery codes and reset codes are PBKDF2-HMAC-SHA256
  with a per-record salt and iteration count, 600,000 iterations for a
  password. Sessions are server side, in the dashboard's memory, so restarting
  the container signs everyone out, which is the right behaviour for a control
  panel.

  Two-factor is RFC 6238, checked against the specification's own test
  vectors. Enrolment shows a QR code rendered in the page itself, with no
  request to any CDN, and hands over ten single-use recovery codes. A code
  cannot be replayed inside its validity window, and an enrolment that is
  never confirmed changes nothing, so an abandoned setup cannot lock anyone
  out.

- **`corex manage dashboard-user`, which is the way back in.** Add an account,
  change a password, set the recovery address, turn two-factor off, and
  `disable-auth` to put Traefik basic auth back. It edits the user file
  directly, so it needs no container, no agent and no network. This exists
  because a control panel whose own login breaks is a lockout, and the
  dashboard is what you open when the box is already in trouble.

  Nothing changes on an existing install until you ask for it. Basic auth
  stays in front until the first account exists and `dashboard-user
  enable-auth` takes it away.

- **Three agent actions for the account store.** The dashboard container runs
  as `nobody` and cannot read a 0600 file, so it reads and writes the document
  through `users-get` and `users-put` and does the hashing itself.

  `auth-reset` is the part that cannot work that way. Mailing a reset code
  needs the relay credentials in `/etc/corex/smtp.conf`, which a web-facing
  container has no business holding, so the agent generates the code, stores
  only its hash and sends the mail. The web tier verifies the code later
  against that hash, having seen neither the code nor the relay password.

- **Rate limits on every path worth guessing at.** An emailed code is eight
  characters and a second factor is six digits, and PBKDF2 does not help
  there: it costs the server as much as the attacker. Login, reset and code
  entry are limited per address, per username and globally, the last of those
  because a caller reaching the container directly can forge
  `X-Forwarded-For`. A reset code is also dead after six wrong guesses.

- **Tests that run where the mistake would be made.** `dashboard/auth_test.go`
  checks a hash written by `agent/corex_users.py` against the Go
  implementation, which is a contract neither language can verify alone and
  which fails as a correct password being refused. It also runs RFC 6238's
  published vectors. Both run in the image build, alongside the existing
  render check, so a disagreement fails the build rather than the login.

- **Uptime Kuma's HTTP checks are seeded from the service modules.** The six
  resource monitors have come from code since v3.11.0, but the reachability
  checks were made by hand in Kuma's interface, so they lived in exactly one
  place: `kuma.db`. A fresh install had none, a restore had whatever the backup
  held, and a new service went unmonitored until somebody remembered. Alerting
  that depends on someone remembering is not alerting.

  Each module now declares its own check as `SERVICE_MONITORS`, and
  `lib/kuma.sh` seeds them: fourteen checks across twelve modules, matched by
  name so an existing monitor is adopted rather than duplicated. Run it again
  with `corex manage kuma-seed`.

  Only services that are installed and enabled are considered, so a
  deliberately disabled Coolify does not start alerting about a state you
  chose. A new monitor is created only for a hostname that answers acceptably
  now, because a module can be enabled while one of its containers is stopped
  on purpose, and seeding blind would leave a permanently down Grafana check.
  Existing monitors are never removed on that basis: switching something off
  for an hour should not delete its history. Interval and retries are cloned
  from a monitor you already have, so tuning done in the interface survives a
  reseed, and only the address and the accepted status codes are treated as
  ours to correct.

### Changed
- The Go builder moves from 1.22 to 1.24, for `crypto/pbkdf2` in the standard
  library. The alternative was this binary's first external dependency, or
  hand-written key derivation in the one place a subtle mistake is invisible.
- `_dashboard_write_compose` is split out of `dashboard_deploy`, so repair
  regenerates the compose file and a smoke test can check the middleware chain
  without building a two-stage image first. Getting that chain wrong asks for
  a password twice in one direction, and publishes the dashboard with nothing
  in front of it in the other, so there are now tests for both.
- The dashboard no longer prints a password in the post-install summary once
  it has accounts of its own. There is nothing to print: the file holds
  hashes, and the way back in is a reset from SSH.

## [v3.16.0] - 2026-09-03

### Added
- **The dashboard covers what you would otherwise SSH for.** Two new tabs and
  four new panels, all of it through the same privileged agent, and none of it
  adding a capability the agent did not already have.

  Health runs `corex manage health` and the resource watchdog: CPU
  temperature, SMART per disk, the dpkg state, whether the last shutdown was
  clean, then memory, disk, heat, containers stopped against their restart
  policy, climbing restart counts and OOM kills. On this class of hardware the
  most common failure is a thermal trip that logs nothing at all, and those
  numbers were only ever visible over SSH.

  Catalogue lists every service module, installed or not, with its label,
  category, description, RAM and disk estimate and whether it needs a domain.
  The metadata is read from the modules themselves rather than from a list in
  the dashboard, so it cannot drift from `corex manage list`, and a new module
  appears with no other change.

  Network gains the reachability and certificate check, and the extra Traefik
  routes. System gains update-all. Health gains doctor.

- **Terminal output keeps its colour.** These commands are written for a
  terminal and their colour carries the meaning: `[  OK]` green, `[WARN]`
  amber, `[FAIL]` red, headings cyan. The dashboard translates the escape
  sequences rather than stripping them, because a wall of grey text where the
  important line looks like every other line is worse than no colour at all.

- **Four read-only actions on the agent whitelist**: `watchdog`,
  `network-check`, `route-list` and `doctor`. The first three change nothing.
  `doctor` repairs what it finds unhealthy, which is not new privilege: repair
  is already reachable per service, and doctor is repair applied to the ones
  that need it.

- **`npm run smoke` now renders every tab, not just the default one.** Radix
  renders tab content lazily, so a component that throws is invisible until
  someone opens it: the same blank page, one click further in.

- **Every action button disables while any job runs.** The agent deliberately
  serialises jobs and refuses the rest with "busy running X", and a click that
  lands on that refusal reads as a broken button rather than as a queue. The
  reachability check also says how long it takes, since it requests every
  hostname in turn: 118 seconds on this box, which without a hint looks like a
  hang.

## [v3.15.1] - 2026-09-03

### Fixed
- **The new dashboard rendered a blank page, and every check that had been run
  passed.** The bundle built, the types checked, the server answered 200 with
  the right content types through Traefik, and the assets were the right size.
  None of that executes the page.

  Two causes, both now fixed. `useTheme` read `localStorage` inside a
  `useState` initialiser, and reading it throws rather than returning null in
  a browser with site data blocked: an exception during the first render makes
  React unmount the tree, so the page goes completely blank with no visible
  cause. And the build target was Vite's default of whatever is baseline
  widely available, which is newer than an older Safari or the browser on a
  phone; a module the browser cannot parse is a SyntaxError before any of the
  app's own code runs.

- **A blank page can no longer happen silently.** `index.html` ships an inline
  styled placeholder that says the script did not run, plus a `window.onerror`
  handler that paints the message into the page, which catches the failures
  React never sees because it never starts. A React error boundary catches the
  rest and prints the stack instead of unmounting to nothing.

- **The dashboard build ran on Node 20, which is end of life,** and jsdom
  cannot import on it: `webidl.util.markAsUncloneable is not a function`. It
  only failed inside the image, because a current Node imports it fine, which
  is a fair argument for the image being the only supported build path. Now
  Node 22.

- **A failed image build reported "deployed".** The build's exit status was
  not checked, and `up -d` after a failed build starts the previous image, so
  the container comes up and every check after that point passes. It now takes
  the status from `PIPESTATUS`, leaves the running image alone, and prints the
  two commands that reproduce the failure.

- **The build bounds its own heat.** Both compilers in the Dockerfile are Go
  programs that size their parallelism from the CPU count, esbuild inside vite
  and the Go compiler itself. Unbounded, this build took the box from 62C to
  93.4C, a degree and a half from the guardian's shed threshold. `GOMAXPROCS=4`
  in both stages sets heat; `nice` only ever set priority.

- **The fix for the blank page could not have reached the browser, because
  the asset names had no content hash while the server called them
  immutable.** `Cache-Control: public, max-age=31536000, immutable` on a name
  fixed as `assets/app.js` pins the first build for a year: Cloudflare held
  the old bundle and served it alongside the new `index.html`
  (`cf-cache-status: HIT`, `age: 1040`), so redeploying changed nothing a
  browser could see. Vite's content hashing is restored, which is what makes
  the immutable header true, and `index.html` stays `no-cache` so it always
  names the current build.

### Added
- **`npm run smoke`, a render check that runs as part of the build.** It mounts
  the built bundle in a DOM with the network disabled and fails if the page
  comes out empty, if the boot placeholder was never replaced, or if the error
  boundary caught anything. Verified against three negative cases: a bundle
  that throws, an empty bundle, and the real one. The Dockerfile runs it, so a
  dashboard that does not render cannot become an image.

## [v3.15.0] - 2026-09-03

### Fixed
- **Every button on the dashboard was inert, and had been.** The layout loaded
  htmx from unpkg with an `integrity` attribute of 63 characters, where a
  base64 sha384 is 64, and the value did not match the file. Browsers refuse
  to execute a script that fails Subresource Integrity and they do it
  silently, so htmx never loaded, every `hx-post` attribute on the page did
  nothing, and the tabs kept working because they were plain links. Recorded
  as gotcha #35, with the one-line command that computes a real hash.

### Changed
- **The dashboard is rebuilt as a React and shadcn/ui interface**, in place of
  server-rendered templates with Tailwind's Play CDN. Cards, badges, tabs,
  tables and the log dialog are shadcn components over Tailwind v4 tokens,
  dark by default with a light theme remembered per browser.

  Nothing is fetched at page load any more. The stylesheet, the JavaScript and
  the icons are compiled and embedded into the Go binary with `go:embed`,
  which removes both CDN dependencies: a dashboard whose stylesheet lives on
  the internet is unstyled exactly when the tunnel is down, which is when it
  is needed.

- **The server is a JSON API rather than an HTML fragment renderer.**
  `/api/state`, `/api/services`, `/api/storage`, `/api/ports`, the action and
  job endpoints, and the existing log stream. The agent contract is unchanged,
  so the dashboard, the Telegram bot and the CLI still cannot drift apart, and
  the dashboard still cannot do more than the agent's whitelist allows.

- **Statuses refresh on their own** every fifteen seconds and immediately
  after an action completes. They used to stay stale until the operator
  clicked a tab again, so a service that had come back up went on being
  reported as down.

- **An unreachable agent is now reported once, at the top of the page,**
  instead of each button failing separately. "The action failed" and "no
  action can ever work here" need different answers.

- **A deliberately stopped service reads as DISABLED, not UNHEALTHY.** Docker
  keeps the last health verdict on a stopped container forever, and treating a
  deliberate stop as a fault is how a status colour stops meaning anything.

- **The direct-ports table lists only installed services.** It was hardcoded
  in the template, so it advertised Grafana and Open WebUI on boxes that had
  neither.

- **Cleanup preview goes through the agent**, as a new read-only
  `cleanup-preview` action. It used to run `corex-manage cleanup --dry-run` in
  the dashboard container, which is `nobody`, so it answered "Run as root"
  every time: the exact fault the agent exists to fix (gotcha #30), left
  behind in one path because it read as a permissions problem rather than a
  design one.

- **Three host facts were the container's, or stale.** The System tab showed
  the container id as the server's hostname, because `os.Hostname()` inside a
  container returns its own; it now asks Docker for the host's name. Uptime
  held BusyBox's usage message, because `uptime -p` is a procps flag and the
  image is Alpine; it now reads `/proc/uptime`, which is not namespaced. And
  the version came from `state.json`, which records the version that
  installed the box and is never updated, so the footer read v3.10.2 on a box
  running v3.15.0; it now reads `corex.sh` from the mounted repo.

- **The dashboard build has a thermal gate and runs at `nice -n 19`.** It now
  has two compilers in it, npm and Go, which makes it the second hottest thing
  CoreX does; it refuses to start above 85C (gotcha #17 and #31). BuildKit
  ignores `--cpuset-cpus`, so priority is the lever.

### Removed
- `dashboard/templates/` and `dashboard/static/`, replaced by `dashboard/web/`.
  The 991-byte `static/tailwind.min.css` was not Tailwind, and the layout also
  carried an Alpine.js `x-cloak` rule for a library the page never loaded.
- The stale `/opt/corex-pro` clone on the server, four months behind at
  commit 4ff4621. Nothing ran from it: the agent's default repo path is
  overridden in `/etc/corex/agent.conf`, and the dashboard container's
  `/opt/corex-pro` is a mount of the live checkout.

## [v3.14.2] - 2026-09-03

### Fixed
- **Every Cal.com booking page returned 404, because v3.14.1 silenced a
  warning that was doing something.** Setting `ALLOWED_HOSTNAMES` stopped the
  "Match of WEBAPP_URL with ALLOWED_HOSTNAMES failed" line, and that line is
  the branch of `getOrgSlug` which returns null and makes the instance a plain
  one rather than an organization. With the bare domain in the list,
  `cal.DOMAIN` matches `DOMAIN`, the remainder `cal` becomes an organization
  slug, and every profile is then looked up inside an organization that does
  not exist. `/username` answered 404 saying the username was still available
  while the account was present, ADMIN, and fully onboarded.

  The variable is now deliberately unset, with the reason recorded in the
  compose comment and as gotcha #34. The warning stays. Log volume is a
  rotation problem and `/etc/logrotate.d/corex` already handles it.

## [v3.14.1] - 2026-09-03

### Fixed
- **Cal.com's account probe queried a table that does not exist.** The Prisma
  model is `User`, and most Cal.com models map to their own name, but this one
  carries `@@map(name: "users")`. The query therefore failed with "relation
  does not exist" on a database that had migrated perfectly, so every install
  reported "schema is not ready yet": public signup was never closed and the
  Telegram webhook was never written. Guarding the query with
  `CASE WHEN to_regclass(...) IS NULL` does not help either, because
  PostgreSQL plans both branches of the CASE, so a missing relation is a
  planning error rather than an unevaluated branch. A failed call is the
  signal now.

- **`corex-manage.sh` did not source `lib/wizard.sh`,** which is where
  `smtp_conf_load` lives, so `add` and `repair` ran with the function
  undefined. Any service that takes its relay from `/etc/corex/smtp.conf`
  found none and reported outbound mail as unconfigured on a box with a
  working relay.

- **`ALLOWED_HOSTNAMES` is set for Cal.com.** Left empty, the application logs
  "Match of WEBAPP_URL with ALLOWED_HOSTNAMES failed" at WARN several times
  per page render, which buries everything else in the container log.

## [v3.14.0] - 2026-09-03

### Added
- **Cal.com, the seventeenth service module**, at `cal.DOMAIN`: booking links
  with availability rules, calendar sync and confirmation mail, in place of
  Calendly. Three containers, `calcom`, `calcom-db` (PostgreSQL 16) and
  `calcom-helper`, nothing published to the host, and the image pinned to
  `calcom/cal.com:v6.2.0` rather than a tag that moves.

  Nothing is compiled. `NEXT_PUBLIC_WEBAPP_URL` is a build argument, which is
  why every self-hosting guide says the image has to be rebuilt for a custom
  domain, but the Dockerfile records the same value again as
  `BUILT_NEXT_PUBLIC_WEBAPP_URL` and the entrypoint rewrites the compiled
  assets on boot when the two differ. So the published image is pulled and
  pointed at the domain at run time, which matters because compiling a Next.js
  application is the peak thermal load on this hardware (gotcha #31).

- **`calcom-helper`, which supplies the two things Cal.com expects a hosting
  platform to provide.** Its cron endpoints exist in the image and nothing
  calls them outside Vercel, so without them reminder mail for unconfirmed
  bookings is never sent, scheduled webhook triggers never fire, and a
  connected Google calendar's watch subscription expires and stops delivering
  changes. The helper calls each on upstream's own schedule, trying POST and
  falling back to GET on 405 because the routes disagree about which verb they
  export, and sending either `CRON_API_KEY` bare or `Bearer CRON_SECRET`
  because they authenticate against two different variables.

- **A Telegram message when someone books.** Cal.com sends webhooks; it does
  not send messages. The helper receives them and posts a plain-text summary
  with the time in the organiser's own timezone to the same chat as the Uptime
  Kuma alerts and the control bot, for new bookings, requests awaiting
  confirmation, reschedules, cancellations, rejections and meeting starts. The
  payload is signed and the signature is checked before anything is sent, so
  being reachable on the Docker network is not enough to make it message you.
  The wiring is one webhook row per account, written by deploy and repair and
  visible in the app under Settings, Developer, Webhooks.

- **Signup that closes itself.** Cal.com's signup form is open by default,
  which on a published hostname lets strangers create accounts, and closing it
  before the first account exists locks the owner out. It now follows the
  account count: open at zero, closed above it, applied on the next repair.
  Set `calcom_allow_signup` in `state.json` to keep it open.

### Changed
- **The shared mail relay is written before services deploy, not after.** It
  was persisted in Phase 5b, so on a fresh install every module that reads
  `/etc/corex/smtp.conf` found nothing and had to be repaired afterwards to
  pick the relay up.

## [v3.13.0] - 2026-09-03

### Added
- **The installer asks for an outbound mail relay.** Several services need one
  and each fails differently without it: Nextcloud silently cannot send a
  password reset, and some applications refuse to start rather than run with no
  way to send mail. Collecting it once at setup and storing it in
  `/etc/corex/smtp.conf` (0600) means a service that needs mail finds it
  already configured rather than failing afterwards. Skipping is offered and
  safe.

  The wizard strips whitespace from the password, because Google displays app
  passwords in four groups for readability while SMTP authentication wants the
  sixteen characters. Values are written quoted, which is not tidiness: an
  unquoted password containing a space is parsed by the shell as a command
  prefix, so the variable is silently never set while the file looks correct.

- **A reference entry in the README for all sixteen services**, installed or
  not, written for someone who has not used them. Each says what the thing is,
  where to reach it, which containers it starts, where its data lives, what it
  needs before it will work, and what to do on first run, along with the
  specific trap that service is known for. Stalwart's entry leads with why a
  home connection usually cannot run a mail server, and Coolify's explains why
  CoreX will not install it automatically.

- **Two gotchas about building images locally** (#31 and #32), which matter for
  any service without a published image. #31 records that compiling is the
  peak thermal load on small hardware, with measurements from a build that took
  a Ryzen mini server from 64C to 96.4C and made the thermal guardian shed
  twelve containers, and that two services sharing an image must not both
  declare a build or BuildKit compiles it twice in parallel. #32 records how to
  find a container's real requirements in its compiled bundle when it
  crash-loops without explaining itself.

## [v3.12.1] - 2026-09-03

### Changed
- **One release convention, and a tool that enforces it.** Release titles had
  drifted through three styles at once, so fourteen of the thirty-six were
  renamed and the title is now exactly the tag. Four versions documented here
  had no GitHub release and three had no tag; v2.1.0, v2.2.0, v2.4.1 and
  v2.5.0 are now tagged at the commits whose subjects match their entries, and
  released.

  `tools/release-notes.py` takes a release body from this file, so the
  changelog stays the single source of truth, and refuses to print notes
  containing em dashes, an IP address, an email address, a bot token or a
  credential. It refuses rather than warns because a release body cannot be
  quietly fixed later: it is what people receive in notifications.

  Prose em dashes in the v2.1.0 to v2.5.0 sections are rewritten, since those
  sections became release bodies for the first time.

## [v3.12.0] - 2026-09-03

### Added
- **The dashboard action buttons work, and the same actions are available from
  Telegram.** The buttons had never worked: the dashboard runs as `nobody` in a
  container and `corex-manage.sh` requires root, so every click returned "Run
  as root: sudo bash corex.sh". Both obvious fixes are wrong. Running a
  web-facing container as root hands it the host, and giving it passwordless
  sudo is the same thing with extra steps.

  `lib/agent.sh` installs one privileged process, `corex-agent`, which accepts
  a fixed list of actions over a unix socket at `/run/corex/agent.sock`, mode
  0660, group `corex-agent`. The dashboard joins that group and keeps running
  as `nobody`. There is one place to audit, and a second client adds no new
  privilege.

  Reachable: start, stop, restart, repair, update, cleanup, status, list,
  health, storage, logs. Absent by design: remove, replace, add, migrate and
  nuke, so neither a stolen Telegram account nor a dashboard session can
  destroy data or an install. Those stay on SSH.

- **`corex-telegram`, a control bot.** Send `stop immich` or `restart n8n` in
  the chat that already receives the alerts and it happens. It long-polls
  rather than using a webhook, so nothing has to be forwarded through the
  router, which is the same reason CoreX uses a Cloudflare tunnel at all.

  It takes its bot token and chat id from the Uptime Kuma Telegram
  notification, so there is nothing extra to configure and replies land in the
  same chat as the alerts. Commands from any other chat id are logged and
  ignored without a reply.

  The bot is not root. It runs as `corex-bot`, whose entire privilege is
  membership of the `corex-agent` group. It cannot read the credentials file,
  reach the Docker socket, or remove anything. This is the process that parses
  untrusted input from the internet, so it holds nothing worth stealing.

- **Job completion notices.** Actions run asynchronously, because update and
  repair outlast any sensible request timeout and a button that appears to hang
  gets clicked twice. The dashboard polls and updates itself; Telegram gets a
  second message when the job finishes.

  The notice comes from the bot rather than from Kuma because Kuma only
  notifies on a state change: a successful `update` produces no Kuma event at
  all, and a successful `stop` produces one only when the service monitor
  notices a minute later.

- **`corex manage agent`**, with `setup`, `test` and a default view showing
  what the agent will and will not run. `test` also checks the path from inside
  the dashboard container, which is the one that was broken.

- **`corex manage restart <service>`**, distinct from `repair`: it restarts
  containers and changes nothing else.

- **Formatted Telegram replies.** `corex-manage.sh` writes for an 80-column
  terminal: box-drawing rules, aligned columns and lines well past 60
  characters. Telegram renders none of that well, and a code block does not
  wrap, so a wide line becomes a horizontal scrollbar on a phone. Each
  command's output is reshaped rather than forwarded.

  `status` groups services by state, naming the ones needing attention
  individually and collapsing the healthy ones into a block. `list` splits
  installed from available and says where to install one, since that is not an
  action the agent will perform. `health` and `storage` keep their labelled
  lines as wrapping text and put only their tables in a code block, which is
  the one place monospace is the point. `logs` gives each container its own
  block.

### Fixed
- **`help` replied with nothing at all.** Its text contained unescaped `.`,
  `-` and `(`, which MarkdownV2 reserves, so Telegram rejected the entire
  message with HTTP 400 and no reply ever arrived. Every reply is now checked
  by sending it and reading the API's answer, rather than by looking at it.

- **`corex manage restart` resurrected disabled components on its first run.**
  `docker restart` starts a stopped container, so operating on the full
  container list started Prometheus, Grafana, cAdvisor and node-exporter, all
  four deliberately switched off, one of which had previously been measured
  burning 49% of a core on a box that thermal-trips. It now restarts only what
  is already running, and skips any disabled component regardless.

- **`corex manage enable` left the restart policy at `no`, so a re-enabled
  service did not survive a reboot.** `docker update --restart=no`, which
  `disable` uses, changes the running container's HostConfig without changing
  the config hash Compose compares against, so `up -d` saw nothing to
  reconcile and started the container with disable's policy still in place.
  The service ran immediately and silently failed to come back after a power
  cut, which is the worst version of this bug because nothing looks wrong
  until it matters. `enable` now restores the policy explicitly, the way the
  per-component branch already did.

- **`corex manage enable <service>` started components that were individually
  disabled.** It used a bare `docker compose up -d` rather than
  `compose_up_enabled`, so enabling a service as a whole overrode the
  per-component choices inside it.

- **A non-UTF-8 file in `lib/services/` crashed the agent on startup.** A macOS
  `tar` had left an AppleDouble sidecar named `._dashboard.sh`, which matches
  the `*.sh` service-module glob and is binary. Service discovery now skips
  `._*` and decodes with `errors="replace"`, because one undecodable byte
  anywhere in `lib/` must never stop the agent from starting.

- **`agent setup` installed new code and kept running the old.** It used
  `systemctl enable --now`, which leaves an already-running unit alone. Same
  trap as regenerating config only when it is missing, gotcha #22.

- **ANSI colour codes reached the browser and Telegram.** `corex-manage.sh`
  colours its output, which rendered as a literal `[0;32m` in both. Stripped
  once in the agent, where output leaves the host, so no client needs to know.

## [v3.11.0] - 2026-09-03

### Added
- **`lib/watchdog.sh`, resource alerting for the faults an HTTP check cannot
  see.** The nine Uptime Kuma monitors added previously answer one question:
  does the URL respond. On this hardware that misses most of what goes wrong.
  A container OOM-killed and restart-looping, a disk filling, the thermal
  guardian shedding services, one background container pinning five cores:
  none of it changes a 200 OK. It also cannot cover a container with no URL at
  all, so an HTTP-only setup reported a healthy Nextcloud while its cron
  container had been dead for a week.

  Six checks run every 60 seconds and push to Kuma, which already owns retry,
  dedupe, re-notify and Telegram delivery: CPU temperature, load per core,
  memory and swap, free space on both disks, container health, and whether the
  thermal guardian currently has anything shed. Every alert names the
  containers responsible, because "the box is hot" is not actionable and
  "immich-ml at 190%" is. `docker stats` is the expensive call, so it runs only
  after a threshold has tripped, never on the healthy path.

  Not Prometheus and Grafana, which is the textbook answer and the wrong one
  here: that stack was measured holding 13GB of TSDB and burning 49% of a core
  on a box that thermal-trips, so the observability was itself a load source,
  and its alerting still needed a separate route to reach a phone.

- **`corex manage watchdog`**, with `setup` to install and register the Kuma
  monitors, `run` to execute one cycle and print what it found, `test` to send
  a real alert through the whole chain, and no argument to show state,
  thresholds and recent findings. `corex manage health` now reports whether
  the watchdog is running, so a silent phone can be told apart from nothing
  measuring.

- **Readable alert formatting.** Kuma's default Telegram message is
  `[name] [status] msg` on one line, which buries the two things read first.
  `watchdog setup` now applies a message template putting the verdict and the
  service on line one, where the phone's notification preview shows them, and
  the detail below. It skips any Telegram notification that already has a
  template, so an operator's own is never overwritten.

  MarkdownV2 rather than HTML, because in that mode Kuma escapes the
  interpolated values, so a container name or an error string containing
  brackets or a hyphen cannot break the parse and silently drop the whole
  notification.

  Each alert is now built as three parts: what happened with numbers, who is
  responsible, and what to run about it. Container faults get one line each,
  since a container can be in several of those states at once. The log keeps
  the flattened single-line form so `watchdog show` and grep still work.

- **Log rotation for CoreX logs.** Nothing rotated them before. The blackbox
  log gets its own longer schedule because it is crash evidence rather than
  operational noise (gotcha #16), and rotation needs an `su root syslog`
  directive or logrotate skips every entry, since Ubuntu ships `/var/log`
  group-writable.

### Fixed
- **`watchdog test` never actually alerted.** It sent one DOWN beat, and the
  monitor allows a single retry, so the beat only reached PENDING and no
  notification was ever sent. It sends two now, which is what crosses the
  retry threshold, and the next scheduled cycle delivers the recovery.

- **Time Machine had been crash-looping 60 times and nothing reported it.**
  `CUSTOM_SMB_CONF=true` tells `mbentley/timemachine` that the operator
  supplies the whole of `/etc/samba/smb.conf`, so the image generates nothing
  and exits 1 when that exact path is missing. CoreX set the flag while
  mounting a partial overlay at `/etc/samba/smb-performance.conf`, a path the
  image never reads, so the container never started and none of the SMB3
  tuning added in v2.2.0 was ever in effect. The module now writes a complete
  `smb.conf`, including the `fruit:` settings the image would have generated,
  without which macOS does not offer the share as a backup target at all.

  Found by the watchdog on its first run. See gotcha #29.

- **`SO_RCVBUF` and `SO_SNDBUF` removed from the Samba socket options.**
  Setting either disables Linux TCP buffer autotuning and pins the window at
  the value given, which would have overridden the 64MB buffers
  `corex manage network-tune` configures. Samba's own `testparm` warns about
  exactly this. They never applied, since the config was never loaded.

## [v3.10.2] - 2026-09-02

### Fixed
- **The thermal guardian resurrected services the operator had disabled.** It
  restarts whatever is on its shed list and knew nothing about the disabled
  flag, so Prometheus, cAdvisor, Grafana and node-exporter came back after
  being deliberately switched off. Prometheus alone then burned 49% CPU, a
  large share of the heat that caused the shed in the first place: the guardian
  was fighting the operator and losing to itself. `restore` now skips any
  container belonging to a disabled service or component, reading both flags
  from `state.json`, and drops it from the shed list rather than deferring it,
  since deferring means retrying forever a container it must never start.

- **A container the guardian killed but failed to record stayed down
  indefinitely.** `shed` recorded a container only if the `docker stop` client
  returned success within its 45s timeout. But `docker stop --time 25` waits
  25s for SIGTERM before sending SIGKILL, so under load the call can exceed
  that timeout: the client is killed while the daemon stops the container
  anyway. The container ends up stopped and absent from the shed list, and an
  unlisted container is never restored. Found on `nextcloud-cron`, sitting at
  exit code 137 with Nextcloud's background jobs silently not running.
  Recording is now decided by whether the container is still running, and a
  container that genuinely refuses to stop is logged and left alone.

### Notes
- The symptom was Immich and Uptime Kuma repeatedly going down. The guardian
  was behaving correctly; the box was oscillating. From `blackbox.log`:
  recovering six containers took it from 70C to 94C in ninety seconds, which
  tripped the critical shed, then it cooled to 58C and recovered six again.
- `THERMAL_RESTORE_BATCH` is set to 1 on that machine. Three, or six in the
  recover band, is reasonable on hardware with cooling headroom and far too
  aggressive where each container costs several degrees.
- Those 93C readings included the resurrected Prometheus at 49% CPU, so they
  measured the bug rather than the hardware. With it fixed the same nineteen
  containers converge and idle at 60C to 70C, well under the 80C warn
  threshold: recovery walked back from 11 shed to 0 while staying in the 60s.
  Bursts still reach the low 90s, so the cooling is worth fixing, but it does
  not limit which services can run.

---

## [v3.10.0] - 2026-09-02

### Added
- **Disable one container inside a module.** `corex manage disable
  monitoring:grafana` stops that component and leaves the rest of the module
  supervised. Previously turning Grafana off meant disabling the whole
  monitoring module, which made `repair` skip it and Uptime Kuma stop being
  auto-healed: a working service lost its supervision to turn off two it
  happened to sit next to. Recorded in `state.json` as
  `disabled_components`, and `enable` takes the same syntax.
- `compose_up_enabled`, which is what makes the choice stick. A plain
  `up -d` starts every service in the file, so a repair silently restarted a
  component that had been deliberately stopped. It names only the enabled
  ones, then stops the disabled ones and clears `restart=always`, so the
  choice survives repair, update and reboot. With nothing disabled it behaves
  exactly like `up -d`. An unknown component name is rejected with the list of
  real ones rather than recorded and silently ignored.

### Fixed
- **Deploy wiped the service's own state on every run.**
  `state_service_installed` assigned a fresh object to `.services[$svc]`,
  discarding every other field, and deploy calls it each time. So a repair
  threw away `disabled_components` and restarted a component that had been
  stopped on purpose, and would have reset `enabled` to true, undoing a
  disable. `installed_at` also came to mean "last repaired". It now merges.
- **The first attempt at that merge reintroduced the jq trap** fixed earlier
  in this release: `(.enabled) // true` is `true` when enabled is `false`, so
  a disabled module came back enabled. The guard test only matched
  `.enabled //` and missed `.enabled) //`, which is how it got back in.
- **monitoring reported UNHEALTHY for a component that was switched off.**
  `monitoring_status` checked Grafana unconditionally, so doctor kept flagging
  a fault that was a choice. It now judges only the components meant to be
  running.

---

## [v3.9.0] - 2026-09-02

### Fixed
- **A disabled service started itself again on the next doctor run.**
  `corex manage disable` recorded `enabled=false` in `state.json` and nothing
  ever read that flag, so doctor saw a stopped container, called it UNHEALTHY
  and started it back up. A service could not be turned off and left off.
  `state_service_is_enabled` now exists; repair skips a disabled service
  rather than treating it as a fault, update skips it since `up -d` would
  start it, and status reports DISABLED with the action column pointing at
  enable. Absent means enabled, so older state files behave as before.
- **The first version of that reader always returned true.** Written as
  `.enabled // true`, it could not work: jq's alternative operator treats
  `false` as absent, so `false // true` evaluates to `true`. Both boolean
  readers now test for null explicitly, and a test fails the build if `//`
  reappears on a boolean field.
- **Removing a service left its firewall rules open forever.** No
  `<svc>_destroy` revoked anything, across ten modules and twenty-two rules.
  Uninstalling Stalwart left ports 25, 143, 465, 587 and 993 allowed from
  Anywhere with nothing listening behind them. Each module now declares
  `SERVICE_FIREWALL_SPECS` and `cmd_remove` revokes them after destroy. Full
  `ufw allow` specs rather than bare ports, because a scoped rule can only be
  deleted by repeating the spec it was added with.
- **`enable` and `disable` could not touch a service that installs its own
  stack.** Both hard-failed with "No compose file", so Coolify could not be
  switched off through CoreX at all. They now resolve containers from the
  compose file when there is one and from the container name prefix when there
  is not. `disable` also sets `restart=no` before stopping, because a
  container on `restart=always` returns when the daemon restarts even though
  it was stopped deliberately, and `enable` restores `unless-stopped`.

### Notes
- `docker builder prune` failed with a permission error on a root-owned
  `~/.docker/buildx` lock, left behind by an earlier `sudo docker compose
  build`. The same class of problem as the root-owned `.git` directory fixed
  in v3.3.0: running a user-scoped tool under sudo leaves state the user can
  no longer write.

---

## [v3.8.0] - 2026-09-02

### Added
- **`corex manage route`**, for containers CoreX did not deploy:

      corex manage route list
      corex manage route add crm.example.com http://twenty-server:3000
      corex manage route remove crm.example.com

  Pointing the tunnel at a single wildcard hostname makes Traefik decide every
  name, so a hostname Traefik does not route returns a Traefik 404 rather than
  reaching its container. Anything deployed outside CoreX, a Coolify app for
  instance, needs a route or it stops being reachable. Routes live in Traefik's
  file-provider directory rather than the application's compose file, because
  whatever deployed the application owns that file and rewrites it on upgrade,
  and a test asserts a Traefik repair never wipes that directory.

  Both inputs are validated. A malformed hostname produces a router Traefik
  silently ignores, and a backend without a scheme is rejected when the file
  loads, taking every other route in that file down rather than just the bad
  one. An https backend also gets the `insecure-backend` transport, since a
  self-signed or mismatched origin certificate otherwise returns 500.

### Fixed
- `route add` printed a verify hint with an over-escaped newline, so it
  rendered across two lines with a stray quote.

### Notes
- With the wildcard tunnel entry in place, all fourteen hostnames were
  confirmed to route through Traefik, each returning the `noindex` header on
  the external path. Before the change that header only ever applied to LAN
  traffic.
- Cloudflare terminates TLS at the edge for proxied hostnames, so external
  visitors see Cloudflare's certificate rather than Traefik's. Traefik's
  Let's Encrypt certificates serve the LAN fast-path, which is what limits how
  much the wildcard-certificate question in gotcha #28 matters.

---

## [v3.7.2] - 2026-09-02

### Added
- **n8n can answer on more than one hostname.** `n8n_subdomain` accepts a
  space-separated list. The first entry is primary and drives `N8N_HOST` and
  `WEBHOOK_URL`, so the links and webhook URLs n8n generates match the URL
  people actually open; every entry gets a Traefik Host rule, so the rest work
  as aliases. Two names are useful when one has been flagged by Safe
  Browsing: Chrome then refuses that name everywhere, including the LAN, while
  the service keeps returning HTTP 200, so a second unflagged name gives a URL
  that opens while a review is pending.

### Fixed
- **n8n's own configuration pointed at the wrong hostname.** After the earlier
  rename, `N8N_HOST` and `WEBHOOK_URL` still said `flows` while requests
  arrived for `n8n`, so every link and webhook URL it generated named a host
  nobody was using.

---

## [v3.7.1] - 2026-09-02

### Fixed
- **n8n crash-looped out of memory, 33 restarts.** It was unreachable because
  it was not running. The log ends in `FATAL ERROR: Ineffective mark-compacts
  near heap limit / JavaScript heap out of memory`, dying at roughly a 250MB
  heap against a 512m container limit: Node sizes its old-space from the
  cgroup limit, so 512m leaves it about 256MB and n8n 2.x needs more just to
  start. Nothing in docker pointed at memory, because `OOMKilled` stayed false
  throughout: Node killed itself at its own ceiling rather than the kernel
  killing the container. The limit is now 1536m with
  `NODE_OPTIONS=--max-old-space-size=1024`, set explicitly rather than
  inferred, and deliberately below the container limit so the kernel does not
  OOM-kill the container instead of Node collecting.
- **uptime-kuma raised from 256m to 512m.** Also Node, and 2.x is heavier than
  the 1.x line it was pinned up from, so it was one step from the same
  failure. cadvisor stays at 256m, being Go.

### Corrected
- **The wildcard certificate added in v3.7.0 is inert**, and the release notes
  overstated it. `entryPoints.websecure.http.tls.domains` does not override a
  router's own `tls.certresolver`, which every CoreX service sets. Measured
  after deploying it: `acme.json` held 13 certificates, all per hostname, none
  with a SAN, and a hostname added afterwards still got its own certificate.
  Making it work needs `tls.domains` labels on all eleven routers, which
  changes issuance for every service and wants doing deliberately. Documented
  as gotcha #28, with what reduces its importance: Cloudflare terminates TLS
  at the edge for anything published through the tunnel, so it is the LAN
  fast-path that uses Traefik's certificate.

---

## [v3.7.0] - 2026-09-02

### Added
- **Every route carries a `noindex` directive.** Set once as a middleware on
  Traefik's `websecure` entrypoint, so it covers services added later:
  `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet, noimageindex,
  notranslate`. A per-service label would be one forgotten label away from a
  hostname being indexable. Nextcloud's own weaker `X-Robots-Tag` is removed,
  because router middlewares run after entrypoint middlewares and it would
  have replaced the full set.
- **A wildcard certificate is requested** when a Cloudflare DNS token is
  configured, though see the correction in v3.7.1: the entrypoint default it
  uses does not override a router's own resolver, so per-hostname issuance
  continues. Let's Encrypt publishes every certificate it issues
  to the Certificate Transparency logs, so a certificate per hostname
  advertises that hostname at crt.sh; eleven certificates meant eleven names.
  A wildcard names only `*.DOMAIN`. It also covers a newly added hostname
  immediately with no ACME round trip, which is what left Coolify on the
  self-signed CA, and leaves one certificate to renew rather than one per
  service.
- **n8n's hostname is overridable** through `$N8N_SUBDOMAIN` or
  `n8n_subdomain` in `state.json`. A hostname can be blocked by something
  outside the service: Google Safe Browsing flagged `n8n.DOMAIN` as a
  "Dangerous site" while n8n itself kept returning HTTP 200, and that block
  follows the name rather than the address, so it applies on the LAN too. Set
  it once and the Traefik router, `N8N_HOST`, `WEBHOOK_URL`, the credentials
  output and the dashboard link all follow.

### Documented
- Gotcha #27: the tunnel bypasses Traefik, so Traefik cannot protect external
  traffic. Public Hostnames point at container names, meaning cloudflared
  talks to applications directly and everything Traefik adds is absent from
  exactly the traffic that comes from the internet. Measured: on the LAN all
  ten hostnames returned the full `noindex` set, while from outside `mail` had
  no such header at all and `vault` had only what Vaultwarden sets itself. The
  fix is one wildcard Public Hostname pointing at `https://traefik:443` with
  No TLS Verify, which also stops a container port change from breaking the
  tunnel.
- README: a section on keeping the domain out of search results, including why
  `robots.txt` is not the mechanism, and the `crt.sh` query for checking what
  is already public.

---

## [v3.6.0] - 2026-09-02

### Fixed
- **`corex manage update --all` reported success while Uptime Kuma sat ten
  months behind.** The root cause is upstream:
  `louislam/uptime-kuma:latest` was last built in October 2025 and is frozen
  on the 1.x line, because the current release ships as `:2` and `:2.5.3`. A
  moving tag that stops moving is the inverse of gotcha #19 and nothing below
  the tag can detect it: `docker pull` correctly reports "Image is up to
  date". Pinned to `2.5.3`, which migrates the 1.x database on first start.
- **The update logic decided a whole stack from one image.** The digest
  shortcut read `config --images | head -1`, so a single current image
  returned early and skipped the rest. `monitoring` ships five images and `ai`
  ships three, and the one it always checked was `node-exporter`, which rarely
  changes. It also compared a `RepoDigest` against a per-platform entry from
  `docker manifest inspect`, which are different digests by construction, so
  the comparison was not meaningful either way. The shortcut is gone; docker
  already skips layers it has.
- **A failed pull was reported as an update.** `docker compose pull` ran
  without its exit code being checked, `up -d` ran regardless, and success was
  logged either way, so a rate limit, an expired tag or a dropped connection
  all looked identical to a successful update. Both commands are checked now,
  and `update --all` collects failures and names them at the end.
- **Browserless ran a two-and-a-half-year-old abandoned image.**
  `browserless/chrome` on Docker Hub was last built in February 2024; upstream
  moved to `ghcr.io/browserless/chromium` for v2. Now pinned to `v2.38.1`.
  `MAX_CONCURRENT_SESSIONS` is a v1 name that v2 ignores, which would have
  left the default concurrency in force, so it is `CONCURRENT` with an
  explicit `TIMEOUT`.

### Changed
- Browserless publishes on loopback rather than every interface. Open WebUI
  reaches it over `ai-net` by container name, so a LAN-facing port was never
  needed, and what it exposed was a scriptable browser behind one token.
- `update` now reports which images actually changed, so "already current" and
  "updated" are different messages.

### Documented
- Gotcha #26: a moving tag can stop moving, with the registry query that
  detects it, since neither `docker pull` nor `docker inspect` can.

---

## [v3.5.3] - 2026-09-02

Three faults in `corex update`, each hiding the next. Together they meant the
command could neither be run unattended nor talked past when it refused.

### Fixed
- **A non-interactive `corex update` reported success while doing nothing.**
  With no terminal, `read` returns an empty answer, so the confirmation prompt
  printed a bare "Aborted." and returned 0. A cron job or a `sudo -n`
  invocation therefore looked like it had updated. It now says why it cannot
  ask and returns non-zero.
- **`corex update` dropped its own `--force` flag.** The dispatch called
  `do_update` with no arguments, unlike `nuke` and `migrate`, which both shift
  and forward. So `corex update --force` behaved exactly like `corex update`,
  and the warning telling you to use `--force` was advice you could not
  follow.
- **`--force` could not be used without a terminal.** The terminal check ran
  before `--force` was considered, so the one flag meant to make the update
  non-interactive was itself blocked by the absence of a terminal. `--force`
  is now tested first and answers the prompt as well as waiving the
  local-changes check.

All three paths are verified on a live install: in sync reports up to date,
behind without a terminal warns and exits non-zero, and behind with `--force`
pulls and validates the scripts.

---

## [v3.5.2] - 2026-09-02

### Fixed
- **`corex update` refused to run on a repo that was already in sync.** It
  reported "Local changes detected, update would overwrite them" on a checkout
  zero commits behind, where there was nothing to pull and nothing that could
  be overwritten. The three offending files were macOS AppleDouble sidecars
  left behind by a file copy, and `git pull` does not touch an untracked file
  unless an incoming commit writes the same path. The check ran before the
  fetch, so "already up to date" never got a chance to win, and it used plain
  `git status --porcelain`, which counts untracked files. It now runs after the
  commits-behind count, considers tracked modifications plus untracked files
  that collide with an incoming path, and lists the offending files rather than
  leaving you to guess. Aborting also restores repository ownership, which the
  early return skipped.


### Added
- `.gitignore` entries for `._*` and `.DS_Store`. Those sidecars arrive from
  any macOS copy and are not project files.

---

## [v3.5.1] - 2026-09-02

### Added
- **Coolify is published at `https://coolify.DOMAIN`.** It was reachable only
  at `http://SERVER_IP:8000` with no certificate. Coolify installs its own
  stack on its own Docker network with no interface on `proxy-net`, so
  `coolify:8080` does not resolve from Traefik and a Docker label cannot
  describe the backend. Traefik addresses it directly through a rule in its
  file-provider directory, written from both deploy and repair and removed on
  destroy. The rule lives outside Coolify's own compose, which Coolify
  rewrites on upgrade.
- **Traefik's file provider reads a directory** rather than a single
  `dynamic.yml`, so any service whose backend Traefik cannot discover can
  contribute a route. The TLS defaults move to `dynamic/00-tls.yml`.

### Fixed
- **Repair silently reverted Traefik from DNS-01 to `tlsChallenge`.** The
  Cloudflare DNS API token lived only in the environment of whoever ran the
  command, and repair regenerates `traefik.yml` unconditionally, so a repair
  without it exported restored both faults that stopped certificates being
  issued in the first place: the wrong challenge type and the wildcard
  `defaultCertificate` that suppresses the resolver. It hides well, because
  certificates already in `acme.json` keep being served and only a newly added
  hostname is affected. `_traefik_cf_token` now resolves from the environment,
  then a 0600 dotfile, then the running compose file, persisting forward at
  each step.

### Documented
- README: n8n and Coolify added to the list of things to keep off the
  internet, with the reason each is equivalent to a shell, and the observation
  that Google Safe Browsing flagged both `portainer.` and `n8n.` as a
  "Dangerous site" on a clean install. A generic admin login form on a domain
  with no reputation matches its phishing heuristics; neither host was
  compromised.
- Gotcha #21 extended with the token persistence requirement.

---

## [v3.5.0] - 2026-09-02

### Fixed
- **The dashboard linked to four hostnames that do not exist.** It built every
  link as `<service>.DOMAIN`, but a name only resolves if a Traefik Host rule
  declares it. Immich answers on `photos`, AdGuard has no router and is reached
  on port 3000, the Traefik dashboard is bound to loopback, and Coolify runs
  its own stack on port 8000. `status.DOMAIN` was missing altogether, because
  its map key was `uptime-kuma`, which is not a service module. `serviceURLs`
  now holds the addresses each module actually answers on, including the ones
  that are not Traefik routes, and a module can list more than one.
- **Immich would not start.** The moving `:release` tag had carried it from the
  1.x line to 3.1.0, which supports only VectorChord or pgvector, while the
  database holds its embeddings in pgvecto.rs columns. Server and machine
  learning images are pinned to `v3.1.0`, and the database moves to the
  transitional image that carries both extensions so Immich migrates the
  embeddings itself. The Nextcloud whiteboard backend and Open WebUI are pinned
  for the same reason, and a test fails the build on any `:release`, `:stable`
  or `:main` tag.
- **Two credential loaders disagreed, locking Immich out of its database.**
  `lib/preflight.sh` read the column-aligned credentials file with `awk` on a
  field number, which drops the alignment padding, so the database was created
  with the trimmed password. `corex-manage.sh` read it with a `sed` that left
  the padding in place, so a repair sent Postgres `"      nJBrU8gc..."` and
  authentication failed. Both now call `cred_get`, which trims the padding and
  keeps spaces inside a value. This affected all eleven credentials, including
  the Restic repository password.
- **Thermal recovery waited for a temperature the hardware never reaches.** The
  guardian shed 24 containers and left them stopped, because recovery only ran
  at `THERMAL_RECOVER_C` (72C) and this machine idles between 79C and 84C.
  Recovery now also runs below `THERMAL_WARN_C`.
- **Restoring the shed list at once re-triggered the shed.** Measured while
  restoring by hand in groups of three, the temperature went 79C, then 92.9C,
  then 96.2C in under two minutes, one degree below the emergency threshold.
  `restore` now restarts at most `THERMAL_RESTORE_BATCH` containers per cycle,
  doubled where there is real headroom.

### Added
- `cred_get` in `lib/common.sh`, the single way to read the credentials file.
- `THERMAL_RESTORE_BATCH`, written into `/etc/corex/thermal.conf`.
- Tests: dashboard links must match the Traefik Host rules in both directions,
  map keys must name real modules, no image may track a moving major tag, no
  script may parse the credentials file by hand, and thermal recovery must be
  both reachable and batched.

### Documented
- Writing rules at the top of `CLAUDE.md`: run the humanizer skill before
  writing, committing or publishing any prose, and never put AI attribution in
  the repository, its history or its releases. Both carry a verification
  command.
- Gotcha #25: thermal recovery must be reachable and gradual, with the
  measurements that show the cooling itself is the limit.
- README lists all ten public hostnames with their tunnel URLs, and a table of
  where every service answers and which addresses carry a certificate.

---

## [v3.4.1] - 2026-09-02

Follow-on fixes to v3.4.0, all found by making failures visible rather than
by reading code.

### Fixed
- **`pipefail` inverted Stalwart's bootstrap-mode check.** It used
  `docker logs stalwart | grep -q ...`; grep exits on the first match, docker
  logs takes SIGPIPE, and under `set -o pipefail` the pipeline reports 141. So
  the check returned false exactly when it matched, and a bootstrap-mode
  server reported HEALTHY through `corex-manage.sh`, which sets pipefail.
  Called directly it worked, which is what made it confusing. Both checks now
  capture the output and pattern-match instead. A test blocks
  `docker logs | grep -q` from coming back.
- **`jq` was missing from the dashboard image**, so every `state_get` inside
  the container returned empty.
- **The dashboard's Storage tab had never worked.** `corex-manage.sh` required
  root, the container runs as `nobody`, and `main.go` called it as
  `out, _ :=` so the "Run as root" message went nowhere. `storage` and
  `status --plain` are read-only and now run without root; the error is
  logged.
- **The dashboard Go build broke on a redeclared `err`.** docker compose kept
  serving the previous image and `repair dashboard` still reported success.

### Added
- `corex-manage.sh status --plain`, a machine-readable
  `<service><TAB><STATUS>` listing that asks each service module for its
  status. The dashboard now uses it instead of deriving health from
  `docker ps`, which is why it disagreed with `corex doctor`.

### Known limitation
- Service actions from the dashboard (start, stop, update, cleanup) still
  require root and fail from the unprivileged container. Those handlers show
  the error rather than hiding it. How an unprivileged container should
  perform privileged work is a design question, not a patch.

---

## [v3.4.0] - 2026-09-02

### Fixed
- **The dashboard reported "No services installed" on a box running 36
  containers.** `state.json` is mode 0600 root, the dashboard container runs as
  `nobody`, and `loadState` discarded the read error. The file is now 0644 and
  the read failure is logged. Every write site re-applies the mode, because
  `mv` from `mktemp` preserves 0600 and a single `state_set` silently re-broke
  it.
- **The Cloudflare tunnel token was stored in `state.json`**, which is
  bind-mounted into that same web-facing container. It now lives in
  `${DOCKER_ROOT}/cloudflared/.tunnel-token` at mode 0600, matching every other
  CoreX secret. `state_set` refuses secret-looking keys outright rather than
  trusting callers, and `state_strip_secrets` removes the legacy copy from an
  installed box.
- **A repair destroyed working Cloudflare tunnels.** `cloudflared_deploy` ran
  `docker rm -f cloudflared` before checking for a token, so a repair on a box
  whose `state.json` lacked one tore down all external access and returned only
  a warning. The token is resolved first, from env, the dotfile, legacy
  `state.json`, or the running compose file, and an existing tunnel is left
  alone when no token can be found.
- **The dashboard mounted `/root/corex-credentials.txt`** and never read it.
  The container cannot read it either, so the mount only exposed every service
  password to a web-facing service. Removed.
- **Stalwart reported healthy through a total external mail outage.** A bot
  probed `mail.DOMAIN//wp-content/.env`; because the request arrived through
  the tunnel, Stalwart banned cloudflared's container IP and with it every
  external visitor. Traefik has a different container IP, so the LAN path kept
  working and the failure looked like tunnel misrouting. `stalwart_status` now
  returns UNHEALTHY when a proxy IP is banned or when the server is still in
  bootstrap mode, since both leave mail unusable while `docker ps` looks fine.
- **Portainer returned 500 through Traefik on every request.** Its self-signed
  certificate is issued for `0.0.0.0`, so Traefik could not verify it against
  the container IP. `dynamic.yml` now defines an `insecure-backend`
  serversTransport that Portainer opts into by label. Scoped on purpose:
  `serversTransport.insecureSkipVerify` in `traefik.yml` would disable backend
  verification for every route.

### Added
- `state_strip_secrets` for migrating a credential out of an existing
  `state.json`.
- Detection for Stalwart bootstrap mode and for a banned reverse proxy, both
  surfaced through `corex doctor` and `corex manage repair stalwart`.
- Unit tests covering the no-secrets invariant, the state file mode after a
  write, the token resolution order, and the honest Stalwart status.

### Documented
- CLAUDE.md gotcha #23: Stalwart bans the reverse proxy, not the scanner, and
  the two settings that fix it for good.
- CLAUDE.md gotcha #24: `state.json` must never hold a credential, and why its
  mode is load-bearing.

---

## [v3.3.0] - 2026-09-02

### Fixed
- **Certificates were never issued behind a residential ISP.** Four separate
  faults, each hiding the next: a stale `dynamic.yml` pointing at a cert
  filename that no longer existed; `tlsChallenge` requiring inbound port 443,
  which most home ISPs block; an empty ACME email, without which Let's Encrypt
  will not register; and a wildcard `defaultCertificate` that matched every
  route, so Traefik's TLS lookup always succeeded and the resolver was never
  invoked. That last one was the real culprit. Removing it caused DNS-01 to
  issue 10 certificates in seconds after months of issuing none.
- **Traefik logged at ERROR**, hiding all ACME activity. A misconfigured
  resolver presented only as a browser warning with an empty log. Now INFO.
- **The Traefik dashboard and API were unreachable.** The entrypoint bound the
  container's own loopback, but Docker publishes to a container's external
  interface, so every request was reset. Exposure is still restricted to the
  host's loopback by the publish itself.
- **The CoreX Dashboard misreported a healthy system.** No membership of the
  Docker socket group meant every `docker ps` failed, and `containerExists`
  read the permission error as output, so 15 running services showed as
  UNHEALTHY. Links were also broken by a quoted domain in `state.json`, which
  `state_set` now strips on write and the dashboard trims on read.
- **`mail-setup` wrote the wrong encryption mode and never enabled auth**, so a
  correct Gmail app password still failed. The mode is now derived from the
  port, and `mail_smtpauth` uses a type `occ` accepts.

### Added
- **`corex manage mail-setup`** configures Nextcloud outbound SMTP, verifying
  the port is reachable before credentials get blamed.
- **README rewritten.** The web dashboard shipped in v3.0.0 with no documented
  way to log into it, and Cloudflare Tunnel had two sentences. Now covers
  dashboard access, tunnel setup, DNS-01 certificates, outbound email limits on
  home connections, thermal protection, and UPS monitoring.

## [Unreleased]

### Added
- **`corex manage mail-setup`**: configures Nextcloud outbound SMTP. Nextcloud
  cannot send password resets, share notifications or activity digests until
  this is set, and its own setup check only reports the config as "not set or
  verified" without saying what breaks. Takes settings from the environment
  (scriptable) or prompts with hidden password input, and verifies the SMTP
  port is actually reachable before credentials get blamed.
- **README section on outbound email**: documents that
  self-hosting mail on a residential connection generally cannot work, with the
  three commands to prove it (inbound 25, outbound 25, reverse DNS). Most ISPs
  block port 25 in both directions and `PTR` cannot be set on a residential IP,
  which alone causes major providers to reject the mail. Submission (587) is
  normally open, so relaying through an authenticated provider works where
  direct delivery does not.

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
- **Bash injection via eval in wizard.sh**: replaced with safe `printf+IFS read` pattern (no eval)
- **Traefik dashboard on all interfaces**: bound to `127.0.0.1:8080` only; UFW rule for 8080 removed
- **Vaultwarden open signup**: `SIGNUPS_ALLOWED` now defaults to `false`
- **Stalwart password from Docker logs**: pre-generated, passed via `STALWART_ADMIN_SECRET` env var
- **Restic password in world-readable backup script**: single-quoted heredoc; runtime read from credentials file
- **Temp file leaks in state.sh**: `trap 'rm -f "$tmp"' RETURN` added to all 5 `mktemp` functions

### Security Fixes (High)
- **awk credential parsing**: replaced with `sed 's/^[^:]*: //'` (handles passwords with spaces)
- **Dangerous glob in rm -rf**: `"${DATA_ROOT}/${svc}"*` → exact path, no glob
- **Silent `git reset --hard` on update**: confirmation flow, `git pull --ff-only`, `bash -n` post-validation
- **`log_warning` undefined in corex.sh**: added standard logging functions block

### Added
- Docker log rotation: `json-file` driver, `max-size: 10m`, `max-file: 3` (30MB cap per container)
- Docker on SSD opt-in via wizard (`DOCKER_ON_SSD` state, `data-root` in daemon.json)
- Per-service resource limits: `deploy.resources.limits` on all 14 service containers
- `corex manage storage`, OS disk, SSD, per-service data breakdown, Docker usage
- `corex manage cleanup [--dry-run]`, safe image/cache cleanup (no `docker system prune`)
- Prometheus disk alerts: SSD < 15% free, OS disk < 10% free (`alerts.yml`)
- Backup integrity verification: `restic check --read-data-subset=5%` after each backup
- Restore `--list` (snapshots only) and `--dry-run` (preview) flags
- Immich DB health check: `pg_isready -U postgres` with 30s start period
- Separate `BROWSERLESS_TOKEN` credential (was shared with `WEBUI_SECRET_KEY`)
- CrowdSec `crowdsecurity/nextcloud` collection added
- `lib/services/dashboard.sh`, plugin stub for upcoming Go+HTMX web UI (v3.0.0)
- Conditional directory creation, only creates dirs for selected services

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

- **Nextcloud "Unknown error during upload"**: Multiple issues caused file uploads to fail silently:
  - **`APACHE_BODY_LIMIT` not set**: Apache 2.4.54+ changed the default `LimitRequestBody` from unlimited to 1GB. The Nextcloud Docker image inherits this default, silently rejecting uploads >1GB. Now explicitly set to `0` (unlimited) via the official `APACHE_BODY_LIMIT` env var.
  - **`.htaccess` overrides server config**: Nextcloud regenerates `.htaccess` on every startup, and `AllowOverride All` means it can override `conf-enabled/` settings. Before-starting hook now patches `.htaccess` with `LimitRequestBody 0` after Nextcloud creates it (background process, adapted from Umbrel's post-start hook pattern).
  - **`max_chunk_size` occ command ran as root**: Created cache files with wrong ownership and failed silently (`2>/dev/null || true`). Now runs via `gosu www-data` with a 30-second retry loop for database readiness.
  - **PHP JIT instability**: `opcache.jit=1255` (aggressive tracing mode) known to cause segfaults in Nextcloud's chunked upload and WebDAV code paths. Disabled JIT, OPcache without JIT provides 95% of the performance benefit for I/O-bound workloads.

### Added

- **MariaDB health check**: `healthcheck.sh --connect --innodb_initialized` with 30s start period ensures database is ready before Nextcloud starts. Before-starting hooks that run `occ` commands now reliably find the database.
- **Redis health check**: `redis-cli ping` with 5s start period. Combined with `depends_on: condition: service_healthy` for proper startup ordering.
- **Nextcloud cron container**: Dedicated `nextcloud-cron` container runs background jobs (`/cron.sh`) so they don't compete with web request PHP workers. Shares the same data volume and image.
- **Security headers**: Added `X-Robots-Tag: noindex,nofollow` (prevents search engine indexing) and `Permissions-Policy: interest-cohort=()` (blocks FLoC tracking) via Traefik middleware.

### Changed

- **`depends_on` with health checks**: Nextcloud app and cron containers now use `condition: service_healthy` instead of simple service dependency, eliminating the race condition where hooks fail because the database isn't ready.
- **Triple-layer body limit fix**: `APACHE_BODY_LIMIT=0` env var + `LimitRequestBody 0` in `conf-enabled/` + `.htaccess` patching. Defense in depth against Apache's 1GB default.

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

- **Network performance tuning** (`corex manage network-tune`): New command that diagnoses network interfaces, displays current vs optimal kernel parameters, and applies high-performance tuning. Transforms file transfer speeds from KB/s to hundreds of MB/s on gigabit+ networks.
  - Detects all ethernet and wireless interfaces with link speed, state, and MTU
  - Shows 14 critical kernel network parameters with current values
  - Applies BBR congestion control (Google's algorithm, 2-10x better than CUBIC on LAN)
  - Tunes TCP buffer sizes from ~200KB default up to 64MB max per socket
  - Enables TCP Fast Open, MTU path probing, window scaling, and SACK
  - Prints diagnostic speed tips (cable check, iperf3 testing, SMB multichannel verification)
  - Safe to re-run, detects if tuning is already applied

- **High-performance SMB3 for Time Machine**: Rebuilt the Time Machine service with optimized Samba configuration for multi-gigabit LAN transfers:
  - SMB3 minimum protocol enforced (disables insecure SMB1/SMB2)
  - SMB multichannel enabled (uses all available NICs simultaneously)
  - 8MB read/write chunks per SMB request (up from default 64KB, 128x larger)
  - 2MB socket buffers with TCP_NODELAY for low-latency transfers
  - Async I/O via sendfile for zero-copy kernel-level file transfers
  - Aggressive client caching via level2 oplocks
  - Custom `smb-performance.conf` overlay bind-mounted into the container
  - Increased file descriptor limits (ulimits 65536)

- **Interactive menu option 4**: "Network tune" added to `corex.sh` interactive menu

### Changed

- **Kernel network parameters** (lib/security.sh): Expanded from 14 security-only params to 50+ params covering both security and performance:
  - TCP buffer auto-tuning: min 4KB → default 256KB → max 64MB
  - BBR congestion control with fq qdisc (replaces CUBIC + pfifo_fast)
  - Connection handling: somaxconn 4096, netdev_max_backlog 16384
  - TCP keepalive tuned for faster dead connection detection (60s interval)
  - VM tuning: swappiness 10, dirty_ratio 40 for file-server workloads
  - File descriptor limits: 2M max, inotify watches 524K
  - Source route rejection on all interfaces (IPv4 + IPv6)
  - TCP RFC 1337 compliance (TIME-WAIT assassination protection)

### Security Hardened

- **SSH ciphers restricted**: Only modern, audited algorithms allowed:
  - KEX: curve25519-sha256, diffie-hellman-group16/18-sha512
  - Ciphers: chacha20-poly1305, aes256-gcm, aes128-gcm
  - MACs: hmac-sha2-512-etm, hmac-sha2-256-etm
  - Empty passwords disabled, Debian banner removed
  - Client alive interval 300s with max 2 probes (auto-disconnect idle sessions)

- **Fail2ban upgraded to 3-jail system**:
  - `sshd`: Standard jail, 3 failures in 10min → 24hr ban
  - `sshd-aggressive`: Aggressive detection, 2 failures in 1hr → 7-day ban
  - `recidive`: Repeat offender jail, 3 Fail2ban bans in 24hrs → 30-day ban
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

- **LAN fast-path setup** (`corex manage lan-setup`): New command that eliminates the manual AdGuard DNS rewrite step and prints complete router/device DNS configuration instructions.
  - Automatically detects the AdGuard admin port from `AdGuardHome.yaml`
  - Calls AdGuard's REST API (`POST /control/rewrite/add`) to register a wildcard `*.yourdomain.com → SERVER_IP` DNS rewrite
  - Prompts for AdGuard credentials if the API requires auth (post-wizard state)
  - Falls back to manual instructions if the API call fails
  - Prints step-by-step DNS setup instructions for router, macOS, Windows, iPhone, and Android
  - Includes a verification step (`nslookup nextcloud.domain`) to confirm the fast-path is working
- **Interactive menu option 3**: "LAN fast-path setup" added to `corex.sh` interactive menu for post-install systems
- **Post-install guide updated**: `lib/summary.sh` now shows `lan-setup` as step 2 in "First Things To Do" (replacing the old manual AdGuard UI instruction)

### How it works

When devices on your LAN use AdGuard (running on the CoreX server) as their DNS server, `*.yourdomain.com` resolves to the server's local IP instead of Cloudflare. All traffic, file uploads to Nextcloud, photo syncs with Immich, Vaultwarden vault access, stays entirely on the local network at full LAN speed (~1 Gbps), bypassing the Cloudflare Tunnel entirely.

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
