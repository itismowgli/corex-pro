/**
 * Screenshots of the built dashboard, from the fixtures every check uses.
 *
 * Not part of `npm run build`, and playwright is deliberately not a dependency
 * of this package: `npm ci` runs in the first Docker stage, and a browser
 * download there would add a hundred megabytes and a network call to every
 * image rebuild on a box whose whole premise is that it needs neither.
 *
 * Install it out of tree and point node at it:
 *
 *   mkdir -p /tmp/corex-shot && cd /tmp/corex-shot
 *   npm init -y && npm i -D playwright && npx playwright install chromium
 *   cd <this directory> && npm run build
 *   PLAYWRIGHT=/tmp/corex-shot/node_modules/playwright/index.mjs \
 *     node shot.mjs services,overview
 *
 * PLAYWRIGHT is a path rather than NODE_PATH, which ESM ignores.
 *
 * This exists because "it does not feel right" is not answerable from a DOM
 * dump. render-check.mjs proves a panel rendered its data; it cannot see that
 * four near-white switches are the loudest thing on a page whose job is to
 * show which service is red. That was found by looking at a screenshot, and
 * every fix after it was judged the same way.
 *
 * Shots land in ./shots, which is git-ignored: they are a working surface, not
 * a baseline. There is no pixel comparison here on purpose, because a diff
 * that fails on every intentional change teaches people to approve diffs.
 */
import fs from "node:fs"
import path from "node:path"
import http from "node:http"

import { DATA, SIGNED_IN } from "./fixtures.mjs"

let chromium
try {
  ;({ chromium } = await import(process.env.PLAYWRIGHT || "playwright"))
} catch {
  console.error(
    "shot: playwright is not resolvable. It is not a dependency of this\n" +
      "package on purpose. Install it somewhere else and name it:\n\n" +
      "  mkdir -p /tmp/corex-shot && cd /tmp/corex-shot\n" +
      "  npm init -y && npm i -D playwright && npx playwright install chromium\n\n" +
      "  PLAYWRIGHT=/tmp/corex-shot/node_modules/playwright/index.mjs node shot.mjs"
  )
  process.exit(1)
}

const DIST = path.join(import.meta.dirname, "dist")
const OUT = path.join(import.meta.dirname, "shots")
if (!fs.existsSync(path.join(DIST, "index.html"))) {
  console.error("shot: no dist/. Run `npm run build` first.")
  process.exit(1)
}

const TABS = (process.argv[2] || "overview,services,catalogue,updates,health,storage,network,maintenance,system,account").split(",")
const THEMES = (process.argv[3] || "dark,light").split(",")

const MIME = {
  ".js": "text/javascript",
  ".css": "text/css",
  ".html": "text/html",
  ".svg": "image/svg+xml",
  ".json": "application/json",
}
const server = http.createServer((req, res) => {
  let f = path.join(DIST, decodeURIComponent(req.url.split("?")[0]))
  // An unknown path is the SPA's own route, exactly as the Go server treats it.
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) f = path.join(DIST, "index.html")
  res.setHeader("Content-Type", MIME[path.extname(f)] || "application/octet-stream")
  res.end(fs.readFileSync(f))
})
await new Promise((r) => server.listen(0, r))
const base = "http://127.0.0.1:" + server.address().port

fs.mkdirSync(OUT, { recursive: true })
const browser = await chromium.launch()

for (const theme of THEMES) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 })
  await ctx.route("**/api/**", (route) => {
    const u = new URL(route.request().url())
    if (u.pathname.includes("/api/auth/me")) return route.fulfill({ json: SIGNED_IN })
    // The vitals stream never completes, so it would hold the screenshot.
    if (u.pathname.includes("/api/stream/")) return route.abort()
    for (const [k, v] of Object.entries(DATA)) if (u.pathname.startsWith(k)) return route.fulfill({ json: v })
    return route.fulfill({ status: 404, json: {} })
  })
  const page = await ctx.newPage()
  await page.addInitScript((t) => {
    try {
      localStorage.setItem("corex-theme", t)
    } catch {
      /* a private window has no storage, and the class below still decides */
    }
  }, theme)

  for (const tab of TABS) {
    // A hash-only goto does not reload, so without this every shot after the
    // first is the first tab again, which looks exactly like a working run.
    await page.goto(base + "/#" + tab, { waitUntil: "load" })
    await page.reload({ waitUntil: "load" })
    await page.waitForTimeout(900)
    await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme)
    await page.waitForTimeout(200)
    await page.screenshot({ path: path.join(OUT, `${tab}-${theme}.png`) })
    console.error("  " + tab.padEnd(12) + theme)
  }
  await ctx.close()
}

await browser.close()
server.close()
console.error("shots written to " + OUT)
