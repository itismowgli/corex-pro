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
const TABS = ["overview", "services", "health", "storage", "network", "catalogue", "updates", "maintenance", "system", "account"]

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

import { DATA, SIGNED_IN } from "./fixtures.mjs"

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
// Substrings that must appear exactly once on a tab.
const ONCE = {
  // The held reason. The card printed it from the service note and again from
  // the image row, so the same paragraph appeared twice under one heading.
  updates: "needs the Nextcloud whiteboard app at 2.x",
}

const EXPECT = {
  system: "enp2s0",
  maintenance: "Never run",
  // The any-hour schedule, which must not render as a clock time.
  maintenanceAnyHour: "whenever it falls due",
  // Three things at once, because the Storage panel now answers three
  // different questions and each has been silently blank at some point:
  // the divergence between what Docker calls unused and what cleanup will
  // take, the physical disk map, and the Time Machine partition that is
  // allocated while holding nothing.
  storage: "too new to remove",
  storageMap: "Extreme 55AE",
  storageIdle: "unallocated on the internal disk",
  // The range toggle over the blackbox series.
  overview: "30 min",
  // The quiet update mark on a row, which only appears when an update payload
  // arrived. "Stale tag" is in no note and on no other tab.
  services: "Stale tag",
  // The state column. One vocabulary is shared with the filter, and this is
  // the word only a row produces: the filter says "Needs attention".
  servicesState: "Not answering",
  // The image tag on a row. This comment used to sit here describing an
  // assertion that had never been written, so the version chip was covered by
  // nothing at all. "v3.6" is in the services fixture and in no note, so only
  // the chip can produce it.
  servicesVersion: "v3.6",
  // Three things this tab has been wrong about, each asserted separately.
  // The group that offers nothing to press:
  updates: "Held back on purpose",
  // The image the note is actually about. The card used to show the service's
  // main container tag beside a note about a different image entirely.
  updatesImage: "immich-server:v3.1.0",
  // The one control that fixes everything, which used to be hidden whenever
  // fewer than two things were waiting.
  updatesButton: "Update everything",
  // Health and Network were converted from cards to rows and had no content
  // assertion at all, so the conversion was verified only as "it mounts". A
  // tab that mounts is not a tab that rendered its data (gotcha #37).
  // /dev/sda only appears if the SMART rows were built from the fixture.
  health: "/dev/sda",
  // The dpkg row, which is its own section now rather than sharing a box.
  healthPackages: "half configured",
  // A service address, which only the rows produce.
  network: "nextcloud.example.com",
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
  // Text that must appear exactly once. A panel that renders the same
  // sentence from two sources reads as a stutter and no "does it contain"
  // assertion can see it.
  if (withData && ONCE[tab]) {
    const needle = ONCE[tab]
    const n = text.split(needle).length - 1
    if (n !== 1) {
      failures.push(`expected ${JSON.stringify(needle)} exactly once, saw it ${n} times`)
    }
  }
  // Extra assertions for a tab that answers more than one question. Keyed
  // "<tab>Something" so one tab can carry several without a second table.
  if (withData) {
    for (const [key, want] of Object.entries(EXPECT)) {
      if (key === tab || !key.startsWith(tab)) continue
      if (!text.includes(want)) {
        failures.push("mounted but did not show " + JSON.stringify(want))
      }
    }
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

// The Services list, which holds its actions one disclosure in.
//
// That is the whole point of the screen: twenty services used to render four
// buttons and a switch each, so the resting page was about a hundred
// controls. Both halves of that claim are invisible to every other check,
// because a collapsed row renders and a mounted tab passes. So this one
// asserts the resting state has no action in it, opens the first row, and
// asserts the actions arrive. Put either half back and it fails.
{
  const { window } = mount("https://dashboard.example.com/#services", SIGNED_IN, true)
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
  const resting = root?.textContent || ""
  // "Repair" is the action that appears on no other part of this tab, so it
  // reads as present only when a row is open.
  if (resting.includes("Repair")) {
    failures.push("the collapsed list already shows its actions, which is the layout this replaced")
  }

  const rows = root?.querySelectorAll("button[aria-expanded]") ?? []
  if (rows.length < 2) {
    failures.push("expected a disclosure per service, saw " + rows.length)
  } else {
    rows[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }))
    await new Promise((r) => setTimeout(r, 200))
    const opened = root?.textContent || ""
    for (const want of ["Repair", "Restart", "Logs"]) {
      if (!opened.includes(want)) {
        failures.push("opened a service row but it did not offer " + JSON.stringify(want))
      }
    }
    if (rows[0].getAttribute("aria-expanded") !== "true") {
      failures.push("the row opened without saying so, so a screen reader never learns it did")
    }
  }

  for (const line of consoleErrors) {
    if (line.includes("dashboard render failed")) failures.push("error boundary caught: " + line)
  }

  if (failures.length) {
    failed = true
    console.error("render-check FAILED on the services list")
    for (const f of failures) console.error("  - " + String(f).slice(0, 1200))
  } else {
    console.error("  services   row actions open on demand")
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
