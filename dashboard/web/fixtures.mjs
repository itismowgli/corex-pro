/**
 * The payloads every check and every screenshot is driven from.
 *
 * One copy, because two drift and the one that drifts is the one nobody runs.
 * They carry the awkward shapes on purpose: a null `urls` where the Go side
 * marshals a nil slice, a service with no image tag, a disk at 94%, a monitor
 * that is down, and a note that embeds the reason the card also prints. A
 * fixture tidier than the real payload tests a payload nobody sends.
 */
// Realistic payloads, not just failures.
//
// The first version of this file failed every fetch, so each tab rendered its
// error state and no service card, port row or catalogue entry was ever
// constructed. That hid a crash that blanked the entire dashboard: the Go side
// marshals a nil slice as JSON null, three services have no browsable address,
// and `svc.urls.length` on null throws. Every check passed and the page was
// blank. So the fixtures below carry the shapes the server actually sends,
// including the null, and both modes run.
export const SERVICES = [
  {
    name: "nextcloud",
    label: "Nextcloud",
    status: "HEALTHY",
    urls: ["https://nextcloud.example.com"],
    container: "nextcloud",
    enabled: true,
    version: "34",
  },
  // No browsable address. The server sends null here, not [], and this row is
  // the whole reason this fixture exists.
  { name: "traefik", label: "Traefik", status: "HEALTHY", urls: null, container: "traefik", enabled: true, version: "v3.6" },
  // Empty version on purpose: a container whose image has since been untagged
  // has none, and the card must simply omit the line rather than print a
  // confident wrong answer like "latest".
  { name: "coolify", label: "Coolify", status: "DISABLED", urls: null, container: "coolify", enabled: false, version: "" },
  { name: "immich", label: "Immich", status: "UNHEALTHY", urls: ["https://photos.example.com"], container: "immich-server", enabled: true, version: "v3.1.0" },
]

export const STATE = {
  version: "3.17.0",
  domain: "example.com",
  server_ip: "10.0.0.2",
  ssh_port: "2222",
  hostname: "box",
  kernel: "6.8.0",
  uptime: "3 days",
  docker: "29.7.2",
  timezone: "UTC",
  agent_ok: true,
  agent_error: "",
}

// A metrics payload with the awkward cases in it on purpose: a null
// temperature, an empty series, a disk at 94%, a monitor that is down, a
// service with no address, and a wake-on-LAN entry that the hardware supports
// but nobody armed. Panels have to render all of those.
export const METRICS = {
  at: 1788400000,
  cpu: { temp_c: 71.6, temp_source: "sensors", temp_state: "ok", load: [0.33, 0.42, 0.59], cores: 16 },
  memory: { used_mb: 4701, total_mb: 31489, swap_used_mb: 4, swap_total_mb: 2047 },
  uptime_s: 98000,
  disks: [
    { path: "/", label: "OS disk", used_b: 57054695424, total_b: 105089261568, free_b: 42649079808, pct: 54.3 },
    { path: "/mnt/corex-data", label: "Data SSD", used_b: 554000000000, total_b: 589600727040, free_b: 3000000, pct: 94.0 },
  ],
  docker: {
    images: { count: 36, active: 32, size: "34.55GB", reclaimable: "576.5MB", size_b: 34550000000, reclaimable_b: 576500000 },
    build_cache: { count: 100, active: 0, size: "2.5GB", reclaimable: "2.0GB", size_b: 2553000000, reclaimable_b: 2047000000 },
  },
  // The whole storage picture, with the two shapes that matter carried on
  // purpose: a partition that is allocated and mounted while holding almost
  // nothing (the Time Machine leftover), and space in the volume group that no
  // filesystem covers. Neither appears in any df output, which is why both
  // went unnoticed on the real box for months.
  storage: {
    disks: [
      {
        name: "nvme0n1", size_b: 512110190592, model: "YC ELECTRONIX 512GB",
        transport: "nvme", unallocated_b: 0,
        parts: [
          { name: "nvme0n1p1", kind: "part", size_b: 1127219200, fstype: "vfat", label: null, mount: "/boot/efi", usage: { used_b: 6200000, total_b: 1100000000, free_b: 1093800000, pct: 0.6 } },
          { name: "nvme0n1p3", kind: "part", size_b: 508833038336, fstype: "LVM2_member", label: null, mount: null, usage: null },
        ],
      },
      {
        name: "sda", size_b: 1000171323904, model: "Extreme 55AE",
        transport: "usb", unallocated_b: 0,
        parts: [
          { name: "sda1", kind: "part", size_b: 399999238144, fstype: "ext4", label: "TIMEMACHINE", mount: "/mnt/timemachine", usage: { used_b: 151000000, total_b: 392600000000, free_b: 392449000000, pct: 0.1 } },
          { name: "sda2", kind: "part", size_b: 600170299392, fstype: "ext4", label: "COREX_DATA", mount: "/mnt/corex-data", usage: { used_b: 120647729152, total_b: 589600727040, free_b: 438927708160, pct: 20.5 } },
        ],
      },
    ],
    volumes: [
      { name: "ubuntu--vg-ubuntu--lv", kind: "lvm", size_b: 268435456000, fstype: "ext4", label: null, mount: "/", usage: { used_b: 63089823744, total_b: 263624122368, free_b: 188685045760, pct: 23.9 } },
      { name: "ubuntu--vg-corex--fast", kind: "lvm", size_b: 53687091200, fstype: "ext4", label: "COREX_FAST", mount: "/mnt/corex-fast", usage: { used_b: 779000000, total_b: 52600000000, free_b: 51821000000, pct: 1.5 } },
    ],
    lvm: { vg: "ubuntu-vg", size_b: 508833038336, free_b: 186700000000 },
    totals: { raw_b: 1512281514496, used_b: 184900000000, free_b: 1051800000000, idle_b: 186700000000 },
  },
  // The state that made the Reclaim button look broken: Docker reports
  // gigabytes unused, and none of it is old enough for cleanup to take. The
  // panel has to say that rather than offer a number it will not deliver.
  purgeable: {
    images_b: 0,
    cache_b: 0,
    total_b: 0,
    cache_held_b: 5981853984,
    held_b: 5981853984,
    next_due_h: 27.7,
    cache_age_h: 72,
  },
  service_sizes: [{ name: "immich", bytes: 41000000000 }, { name: "nextcloud", bytes: 9000000000 }],
  series: Array.from({ length: 60 }, (_, i) => ({
    t: "2026-09-03T23:00:00+05:30",
    temp: 62 + (i % 12),
    load: 0.2 + (i % 5) / 10,
    mem_used_mb: 4600 + i,
    mem_total_mb: 31489,
    swap_used_mb: 4,
    throttled: i === 30,
    containers: 22,
  })),
  watchdog: [{ t: "2026-09-03T22:56:15+05:30", level: "down", text: "temp DOWN: 82C, over the 80C limit." }],
  thermal: { enabled: true, warn_c: 80, shed_c: 85, emergency_c: 97, shed: [] },
  monitors: [
    { name: "Nextcloud", active: true, type: "http", status: "up", last_check: "2026-09-03 17:45:01", message: "200 - OK", ping_ms: 12 },
    { name: "Immich", active: true, type: "http", status: "down", last_check: "2026-09-03 17:45:01", message: "timeout", ping_ms: null },
  ],
  smart: [{ device: "/dev/nvme0n1", status: "PASSED" }, { device: "/dev/sda", status: "not reported" }],
  // Half configured on purpose, like the disk at 94% and the monitor that is
  // down: this is the state with consequences, and it is the one an upgrade
  // interrupted by a power cut actually leaves (gotcha #18).
  dpkg: { clean: false, packages: ["systemd", "libc-bin"] },
  wol: [
    { interface: "enp2s0", supported: true, enabled: false, modes: "d" },
    { interface: "wlp3s0", supported: false, enabled: false, modes: "d" },
  ],
  // One of each outcome on purpose: a task that has never run must not draw a
  // tick, a failure has to be legible, and a task held back for temperature
  // is neither of those.
  // Two of the three states the check can be in, including the one it must
  // never hide the Update button for.
  updates: {
    checked_at: 1788410000,
    checking: false,
    services: {
      nextcloud: { service: "nextcloud", state: "update", note: "34 now points at sha256:9f1c2a", images: [{ image: "nextcloud:34", state: "update", note: "34 now points at sha256:9f1c2a" }] },
      // Held on purpose: upstream is ahead and the module says not to follow,
      // with a reason. Must render as a decision with nothing to press, not
      // as an update waiting.
      // The note embeds the reason, exactly as the agent writes it. It did
      // not here, which is why this check could not see the card printing the
      // reason twice: once from the note and once from the body.
      traefik: { service: "traefik", state: "held", note: "whiteboard is held at this version. v2.0.0 needs the Nextcloud whiteboard app at 2.x, and the app installed here is 1.5.9.", images: [{ image: "ghcr.io/nextcloud-releases/whiteboard:v1.5.9", state: "held", note: "held", newer: "v2.0.0", reason: "v2.0.0 needs the Nextcloud whiteboard app at 2.x, and the app installed here is 1.5.9." }] },
      // Pinned and current for its tag, while upstream published a higher
      // version. The card must show the version and must NOT offer an Update
      // button, because pulling a pinned tag changes nothing.
      immich: { service: "immich", state: "newer-release", note: "v3.1.0 is pinned and current, and upstream has since published v3.2.2", images: [{ image: "ghcr.io/immich-app/immich-server:v3.1.0", state: "newer-release", note: "upstream has since published v3.2.2", newer: "v3.2.2" }] },
      coolify: { service: "coolify", state: "stale-tag", note: "latest is current but has not been rebuilt in 310 days", images: [], },
    },
  },
  maintenance: {
    installed: true,
    timer_active: true,
    enabled: true,
    tasks: [
      { name: "backup", label: "Backup", description: "Restic snapshot.", enabled: true, interval_h: 24, hour: 3, last: 1788400000, next: 1788486400, state: "ok", elapsed: 412, detail: "latest snapshot 2026-09-04T03:07:11+05:30", deferred_at: 0, deferred_detail: "" },
      { name: "cleanup", label: "Docker cleanup", description: "Prune unused images.", enabled: true, interval_h: 168, hour: 4, last: 1788300000, next: 1788904800, state: "failed", elapsed: 9, detail: "cannot find corex-manage.sh", deferred_at: 0, deferred_detail: "" },
      // hour "*" means any hour. int("*") used to fall back to 0 and the page
      // announced "around 0:00", an invented time of day for a task that has
      // none.
      { name: "updates", label: "Check for updates", description: "Ask the registries what is newer.", enabled: true, interval_h: 6, hour: "*", last: 1788410000, next: 1788431600, state: "ok", elapsed: 12, detail: "18 checked", deferred_at: 0, deferred_detail: "" },
      // Ran a week ago and was declined this morning: the row has to show
      // both, and the deferral must not read as the last run.
      { name: "timemachine", label: "Time Machine check", description: "Share and restart count.", enabled: true, interval_h: 168, hour: 5, last: 1788350000, next: 1788954800, state: "ok", elapsed: 3, detail: "running=true restarts=0", deferred_at: 1788420000, deferred_detail: "deferred, CPU at 91C" },
      { name: "os-upgrade", label: "OS packages", description: "Supervised apt upgrade.", enabled: false, interval_h: 720, hour: 4, last: 0, next: 0, state: "", elapsed: 0, detail: "", deferred_at: 0, deferred_detail: "" },
    ],
  },
}

export const DATA = {
  "/api/overview": {
    metrics: METRICS,
    services: { healthy: 13, unhealthy: 0, sleeping: 1, stopped: 1, missing: 0 },
    containers: { running: 22, total: 39, restarting: 0, unhealthy: 0 },
    top: [
      { name: "immich-ml", service: "immich", status: "running", health: "healthy", cpu_percent: 12.4, mem_bytes: 900000000, mem_limit: 3000000000, mem_percent: 30, restarts: 0, oom_killed: false, since: "Up 2 days" },
    ],
    agent_ok: true,
    agent_error: "",
    collected_at: "2026-09-03T23:20:00+05:30",
  },
  "/api/containers": [
    { name: "immich-ml", service: "immich", status: "running", health: "healthy", cpu_percent: 12.4, mem_bytes: 900000000, mem_limit: 3000000000, mem_percent: 30, restarts: 0, oom_killed: false, since: "Up 2 days" },
  ],
  "/api/services": SERVICES,
  "/api/state": STATE,
  "/api/storage": { output: "CoreX Storage Report\n  /mnt/corex-data  40% used" },
  "/api/ports": [{ service: "adguard", url: "http://10.0.0.2:3000", note: "admin" }],
  "/api/catalogue": [
    { name: "gitea", label: "Gitea", category: "productivity", description: "Git server", ram_mb: 512, disk_gb: 5, needs_domain: true, installed: false, enabled: false, urls: ["https://git.example.com"] },
    { name: "traefik", label: "Traefik", category: "core", description: "Reverse proxy", ram_mb: 128, disk_gb: 1, needs_domain: false, installed: true, enabled: true, urls: [] },
  ],
}

export const SIGNED_IN = {
  auth_enabled: true,
  authenticated: true,
  awaiting_totp: false,
  username: "operator",
  display_name: "Operator",
  email: "operator@example.com",
  totp_enabled: false,
  recovery_left: 0,
}
