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
const TABS = ["services", "health", "storage", "network", "catalogue", "system", "account"]

// One reply has to succeed, /api/auth/me, or the app renders the login form
// and none of the tabs are exercised at all. Everything else still fails, so
// each tab must render its own error state rather than depend on a server.
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

function mount(url, me) {
  const dom = new JSDOM(html, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url,
  })
  const { window } = dom
  window.fetch = async (path) => {
    if (String(path).includes("/api/auth/me")) return reply(me)
    throw new Error("render-check: network disabled")
  }
  return { dom, window }
}

let failed = false

for (const tab of TABS) {
  const { window } = mount("https://dashboard.example.com/#" + tab, SIGNED_IN)
  window.EventSource = class {
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
  for (const line of consoleErrors) {
    if (line.includes("dashboard render failed")) failures.push("error boundary caught: " + line)
  }

  if (failures.length) {
    failed = true
    console.error("render-check FAILED on the " + tab + " tab")
    for (const f of failures) console.error("  - " + String(f).slice(0, 1200))
  } else {
    console.error("  " + tab.padEnd(10) + " ok, " + text.length + " characters")
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
  })
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
  const text = (window.document.getElementById("root")?.textContent || "").trim()
  if (!text.includes("Sign in")) {
    failures.push("the login form did not render: " + JSON.stringify(text.slice(0, 200)))
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
console.error("render-check ok: every tab and the login form mount and render")
process.exit(0)
