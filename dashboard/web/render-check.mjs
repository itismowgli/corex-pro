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

const dom = new JSDOM(html, {
  runScripts: "outside-only",
  pretendToBeVisual: true,
  url: "https://dashboard.example.com/",
})
const { window } = dom

// The browser surface the app touches. Every fetch fails on purpose: the page
// has to render its own error state rather than depending on a live server,
// which is also the state an operator sees when the agent is down.
window.fetch = async () => {
  throw new Error("render-check: network disabled")
}
window.EventSource = class {
  close() {}
}

const failures = []
window.addEventListener("error", (e) => failures.push("uncaught: " + (e.error?.stack || e.message)))
const consoleErrors = []
window.console = {
  error: (...a) => consoleErrors.push(a.map(String).join(" ")),
  warn: () => {},
  log: () => {},
  info: () => {},
  debug: () => {},
}

try {
  window.eval(fs.readFileSync(path.join(dist, "assets/app.js"), "utf8"))
} catch (e) {
  failures.push("threw while loading the bundle: " + (e.stack || e.message))
}

setTimeout(() => {
  const root = window.document.getElementById("root")
  const text = (root?.textContent || "").trim()

  if (!root) failures.push("#root is missing from index.html")
  if (text.startsWith("Loading the CoreX dashboard")) {
    failures.push("the boot placeholder was never replaced, so the app did not mount")
  }
  if (text.length < 20) failures.push("#root is empty after mount: " + JSON.stringify(text))
  // The header renders unconditionally, so its absence means the shell itself
  // failed even if something else painted.
  if (!text.includes("CoreX")) failures.push("the header did not render")
  for (const line of consoleErrors) {
    if (line.includes("dashboard render failed")) failures.push("error boundary caught: " + line)
  }

  if (failures.length) {
    console.error("render-check FAILED")
    for (const f of failures) console.error("  - " + f.slice(0, 1200))
    process.exit(1)
  }
  console.error("render-check ok: the app mounts and renders " + text.length + " characters")
  process.exit(0)
}, 1500)
