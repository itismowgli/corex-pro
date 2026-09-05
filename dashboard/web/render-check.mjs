/**
 * Renders the built bundle in a DOM and fails if the page comes out empty.
 *
 * This exists because the first deployment of this app rendered nothing at
 * all, and every check that had been run passed: the bundle built, the types
 * checked, the server returned 200 with the right content types, and the
 * assets were the right size. None of that executes the page. A blank
 * dashboard is indistinguishable from a working one to every one of those
 * tests, so the build now runs the app once and looks at the result.
 *
 * It is deliberately not a test framework. It answers one question: does the
 * app mount and put something in #root.
 */
import { JSDOM } from "jsdom"
import fs from "node:fs"
import path from "node:path"

const dist = path.join(import.meta.dirname, "dist")
const html = fs.readFileSync(path.join(dist, "index.html"), "utf8")

// The entry is discovered from index.html rather than assumed, the way a
// browser finds it. Asset names carry a content hash, so hardcoding one means
// the check silently tests the wrong file, or an absent one, after any build.
const entry = html.match(/<script[^>]+src="([^"]+\.js)"/)?.[1]
if (!entry) {
  console.error("render-check FAILED\n  - index.html has no module script to run")
  process.exit(1)
}
const entryPath = path.join(dist, entry.replace(/^\//, ""))
if (!fs.existsSync(entryPath)) {
  console.error("render-check FAILED\n  - index.html references " + entry + ", which was not emitted")
  process.exit(1)
}
const bundle = fs.readFileSync(entryPath, "utf8")

// Every tab, not just the default one. Radix renders tab content lazily, so a
// component that throws is invisible until someone opens it: exactly the
// blank page this check exists to prevent, one click further in.
const TABS = ["overview", "services", "health", "storage", "network", "catalogue", "maintenance", "system", "account"]

// The names as they appear in the sidebar. Not derived from TABS: a check
// that computes its expectation the same way the code does agrees with the
// code even when both are wrong.
const SECTIONS = [
  "Overview",
  "Services",
  "Catalogue",
  "Health",
  "Storage",
  "Network",
  "Maintenance",
  "System",
  "Account",
]

// Realistic payloads, not just failures.
//
// The first version of this file failed every fetch, so each tab rendered its
// error state and no service card, port row or catalogue entry was ever
// constructed. That hid a crash that blanked the entire dashboard: the Go side
// marshals a nil slice as JSON null, three services have no browsable address,
// and `svc.urls.length` on null throws. Every check passed and the page was
// blank. So the fixtures below carry the shapes the server actually sends,
// including the null, and both modes run.
const SERVICES = [
  {
    name: "nextcloud",
    label: "Nextcloud",
    status: "HEALTHY",
    urls: ["https://nextcloud.example.com"],
    container: "nextcloud",
    enabled: true,
  },
  // No browsable address. The server sends null here, not [], and this row is
  // the whole reason this fixture exists.
  { name: "traefik", label: "Traefik", status: "HEALTHY", urls: null, container: "traefik", enabled: true },
  { name: "coolify", label: "Coolify", status: "DISABLED", urls: null, container: "coolify", enabled: false },
  { name: "immich", label: "Immich", status: "UNHEALTHY", urls: ["https://photos.example.com"], container: "immich-server", enabled: true },
]

const STATE = {
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
const METRICS = {
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
  dpkg: { clean: true, packages: [] },
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
      traefik: { service: "traefik", state: "current", note: "v3.6 is current", images: [{ image: "traefik:v3.6", state: "current", note: "v3.6 is current" }] },
      immich: { service: "immich", state: "unknown", note: "could not ask ghcr.io about release", images: [] },
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
      // Ran a week ago and was declined this morning: the row has to show
      // both, and the deferral must not read as the last run.
      { name: "timemachine", label: "Time Machine check", description: "Share and restart count.", enabled: true, interval_h: 168, hour: 5, last: 1788350000, next: 1788954800, state: "ok", elapsed: 3, detail: "running=true restarts=0", deferred_at: 1788420000, deferred_detail: "deferred, CPU at 91C" },
      { name: "os-upgrade", label: "OS packages", description: "Supervised apt upgrade.", enabled: false, interval_h: 720, hour: 4, last: 0, next: 0, state: "", elapsed: 0, detail: "", deferred_at: 0, deferred_detail: "" },
    ],
  },
}

const DATA = {
  "/api/overview": {
    metrics: METRICS,
    services: { healthy: 13, unhealthy: 0, stopped: 1, missing: 0 },
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

const SIGNED_IN = {
  auth_enabled: true,
  authenticated: true,
  awaiting_totp: false,
  username: "operator",
  display_name: "Operator",
  email: "operator@example.com",
  totp_enabled: false,
  recovery_left: 0,
}

// A duck-typed Response. jsdom does not ship one, and api.ts only ever touches
// these four members.
function reply(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: "OK",
    text: async () => JSON.stringify(body),
  }
}

// withData true serves the fixtures above; false fails every call but
// /api/auth/me, which is the state an operator sees when the agent is down.
// Both have to render, and only the first constructs any rows.
function mount(url, me, withData = true, width = 1280) {
  const dom = new JSDOM(html, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url,
  })
  // jsdom does no layout, so this cannot prove a page fits. It does exercise
  // any code that branches on width, which is the part that can throw.
  Object.defineProperty(dom.window, "innerWidth", { value: width, configurable: true })
  Object.defineProperty(dom.window, "innerHeight", { value: width < 500 ? 780 : 900, configurable: true })
  dom.window.matchMedia = (q) => ({
    matches: /max-width:\s*(\d+)/.test(q) ? width <= Number(RegExp.$1) : width >= 640,
    media: q,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
    onchange: null,
    dispatchEvent: () => false,
  })
  const { window } = dom
  window.fetch = async (path) => {
    const p = String(path)
    if (p.includes("/api/auth/me")) return reply(me)
    if (withData) {
      for (const [route, body] of Object.entries(DATA)) {
        if (p.startsWith(route)) return reply(body)
      }
    }
    throw new Error("render-check: network disabled")
  }
  return { dom, window }
}

// Substrings that prove a panel read its fixture rather than only mounting.
const EXPECT = {
  system: "enp2s0",
  maintenance: "Never run",
  // Not the tile label: the sentence that only appears when cleanup can free
  // nothing and Docker still reports gigabytes unused. That divergence is the
  // whole bug this panel was rewritten for.
  storage: "too new to remove",
  // The range toggle over the blackbox series.
  overview: "30 min",
  // Not just the card: the sentence the check writes above the grid, which
  // only appears when an update payload arrived.
  services: "Update available",
  catalogue: "Gitea",
}

let failed = false

// Every tab twice: once with data, once with everything failing.
const MODES = [
  { withData: true, label: "data", width: 1280 },
  { withData: false, label: "down", width: 1280 },
  // A narrow iPhone, which is the width the layout actually has to survive.
  { withData: true, label: "phone", width: 360 },
]

for (const { withData, label: mode, width } of MODES)
for (const tab of TABS) {
  const { window } = mount("https://dashboard.example.com/#" + tab, SIGNED_IN, withData, width)
  window.EventSource = class {
    constructor() {
      this.onmessage = null
      this.onerror = null
      this.onopen = null
    }
    close() {}
  }

  const failures = []
  window.addEventListener("error", (e) =>
    failures.push("uncaught: " + (e.error?.stack || e.message))
  )
  const consoleErrors = []
  window.console = {
    error: (...a) => consoleErrors.push(a.map(String).join(" ")),
    warn: () => {},
    log: () => {},
    info: () => {},
    debug: () => {},
  }

  try {
    window.eval(bundle)
  } catch (e) {
    failures.push("threw while loading " + entry + ": " + (e.stack || e.message))
  }

  await new Promise((r) => setTimeout(r, 400))

  const root = window.document.getElementById("root")
  const text = (root?.textContent || "").trim()

  if (!root) failures.push("#root is missing from index.html")
  if (text.startsWith("Loading the CoreX dashboard")) {
    failures.push("the boot placeholder was never replaced, so the app did not mount")
  }
  if (text.length < 20) failures.push("#root is empty after mount: " + JSON.stringify(text))
  if (!text.includes("CoreX")) failures.push("the header did not render")
  // The navigation is the shell, so a section missing from it is a section
  // nobody reaches. It renders on every mount, wide or narrow, because the
  // drawer and the fixed column share one list.
  for (const section of SECTIONS) {
    if (!text.includes(section)) failures.push("the nav is missing " + section)
  }
  // Every section opens with its own heading. It is rendered once in App.tsx
  // for all of them, so its absence is every page losing its title at once,
  // which reads as a styling slip rather than a broken component.
  if (!root?.querySelector("h1")) failures.push("the section heading did not render")
  // One content assertion per tab, only where the tab draws something from a
  // fixture that a mounted-but-empty panel would omit. "It rendered" is not
  // the same as "it rendered the data", and the power card is the highest
  // consequence panel on the page: it has to name the interface it read.
  if (withData && EXPECT[tab] && !text.includes(EXPECT[tab])) {
    failures.push("mounted but did not show " + JSON.stringify(EXPECT[tab]))
  }
  for (const line of consoleErrors) {
    if (line.includes("dashboard render failed")) failures.push("error boundary caught: " + line)
  }

  if (failures.length) {
    failed = true
    console.error("render-check FAILED on the " + tab + " tab (" + mode + ")")
    for (const f of failures) console.error("  - " + String(f).slice(0, 1200))
  } else {
    console.error("  " + tab.padEnd(10) + " " + mode.padEnd(5) + " ok, " + text.length + " characters")
  }
  window.close()
}

// The command palette, which no other check can see because it is closed
// until someone presses Cmd+K. It is the only route to most of these actions
// on a narrow screen, and a component that throws when opened looks exactly
// like a key that does nothing.
{
  const { window } = mount("https://dashboard.example.com/#overview", SIGNED_IN, true)
  window.EventSource = class {
    constructor() {
      this.onmessage = null
      this.onerror = null
      this.onopen = null
    }
    close() {}
  }
  const failures = []
  window.addEventListener("error", (e) =>
    failures.push("uncaught: " + (e.error?.stack || e.message))
  )
  const consoleErrors = []
  window.console = {
    error: (...a) => consoleErrors.push(a.map(String).join(" ")),
    warn: () => {},
    log: () => {},
    info: () => {},
    debug: () => {},
  }
  try {
    window.eval(bundle)
  } catch (e) {
    failures.push("threw while loading " + entry + ": " + (e.stack || e.message))
  }
  await new Promise((r) => setTimeout(r, 400))

  window.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "k", metaKey: true, bubbles: true })
  )
  await new Promise((r) => setTimeout(r, 300))

  // It portals outside #root, so this reads the whole document.
  const text = window.document.body.textContent || ""
  // A section, a service action built from the services payload, and a
  // box-wide command. The middle one is the assertion that matters: it can
  // only appear if the palette read the service list rather than a static
  // list of its own.
  for (const want of ["Go to", "Restart Nextcloud", "Run the doctor"]) {
    if (!text.includes(want)) {
      failures.push("Cmd+K opened but did not offer " + JSON.stringify(want))
    }
  }
  for (const line of consoleErrors) {
    if (line.includes("dashboard render failed")) failures.push("error boundary caught: " + line)
  }

  if (failures.length) {
    failed = true
    console.error("render-check FAILED on the command palette")
    for (const f of failures) console.error("  - " + String(f).slice(0, 1200))
  } else {
    console.error("  palette    ok, " + text.length + " characters")
  }
  window.close()
}

// And the login form, which is what an unauthenticated visitor gets. It is the
// only screen on a box whose dashboard has accounts, so a component that
// throws here locks the operator out of their own control panel with a blank
// page, which is precisely the failure this file exists to catch.
{
  const { window } = mount("https://dashboard.example.com/", {
    ...SIGNED_IN,
    authenticated: false,
  }, true)
  // jsdom has no WebAuthn, so without this stub the passkey half of the form
  // never renders and the check can only ever see the password. The stub is
  // deliberately minimal: `supported()` asks for these three and nothing
  // else, and a conditional ceremony that is never offered is exactly what a
  // browser without autofill support does.
  window.PublicKeyCredential = function () {}
  window.navigator.credentials = {
    create: async () => null,
    get: async () => new Promise(() => {}),
  }
  const failures = []
  window.addEventListener("error", (e) =>
    failures.push("uncaught: " + (e.error?.stack || e.message))
  )
  window.console = {
    error: () => {},
    warn: () => {},
    log: () => {},
    info: () => {},
    debug: () => {},
  }
  try {
    window.eval(bundle)
  } catch (e) {
    failures.push("threw while loading " + entry + ": " + (e.stack || e.message))
  }
  await new Promise((r) => setTimeout(r, 400))
  const root = window.document.getElementById("root")
  const text = (root?.textContent || "").trim()
  if (!text.includes("Sign in")) {
    failures.push("the login form did not render: " + JSON.stringify(text.slice(0, 200)))
  }
  // Both ways in have to be on the screen. Losing the password leaves anyone
  // without their device locked out of the control panel; losing the passkey
  // silently demotes the stronger factor to nothing.
  if (!text.includes("Sign in with a passkey")) {
    failures.push("the passkey button is missing from the login form")
  }
  if (!text.includes("or use your password")) {
    failures.push("the password fallback is missing from the login form")
  }
  // And in that order. A passkey offered after a password reads as a second
  // step rather than an alternative, which is the arrangement to avoid: a
  // passkey already proves possession and verifies the person.
  const passkeyAt = text.indexOf("Sign in with a passkey")
  const passwordAt = text.indexOf("or use your password")
  if (passkeyAt >= 0 && passwordAt >= 0 && passkeyAt > passwordAt) {
    failures.push("the password is offered before the passkey")
  }
  // The field has to be marked for it, or the conditional request is armed
  // and the browser never offers it anywhere.
  const user = root?.querySelector("#username")
  const ac = user?.getAttribute("autocomplete") || ""
  if (!ac.split(/\s+/).includes("webauthn")) {
    failures.push('the username field is not marked autocomplete="... webauthn", so autofill cannot offer a passkey')
  }
  if (failures.length) {
    failed = true
    console.error("render-check FAILED on the login screen")
    for (const f of failures) console.error("  - " + String(f).slice(0, 1200))
  } else {
    console.error("  login      ok, " + text.length + " characters")
  }
  window.close()
}

if (failed) process.exit(1)
console.error("render-check ok: every tab renders with data and with the server down, and the login form mounts")
process.exit(0)
