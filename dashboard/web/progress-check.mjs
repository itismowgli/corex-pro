/**
 * Checks the update progress parser against output this box actually emits.
 *
 * Every fixture below was captured from the server with `docker compose pull`
 * and `docker compose up -d`, and the first version of the parser got two of
 * them wrong in ways nothing else could see:
 *
 *  - Compose names the IMAGE, not the service: " Image authelia/authelia:4.39
 *    Pulling". The parser matched on "<service> Pulling" and so matched none
 *    of it, reporting every update as "Starting" forever.
 *  - A fast pull finishes with no layer line ever reaching "Pull complete".
 *    Counting layers alone therefore reported 0% on a pull that was done.
 *
 * Neither is visible to a type check or a render check, because the output is
 * still a string and the card still draws it. When changing the parser, put a
 * bug back and confirm this fails.
 */
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const out = fs.mkdtempSync(path.join(os.tmpdir(), "progress-"))
execFileSync(
  "npx",
  [
    "tsc", "src/lib/progress.ts",
    "--outDir", out,
    "--module", "esnext",
    "--target", "es2022",
    "--moduleResolution", "bundler",
    "--skipLibCheck",
    "--typeRoots", path.join(out, "no-types"),
  ],
  { cwd: import.meta.dirname, stdio: "inherit" },
)
const { updateProgress, currentTarget, sliceFor } = await import(path.join(out, "progress.js"))

const ESC = String.fromCharCode(27)

const CASES = [
  {
    name: "image already current, two lines, must not read as still starting",
    output: [
      " Image authelia/authelia:4.39 Pulling ",
      " Image authelia/authelia:4.39 Pulled ",
    ].join("\n"),
    phase: "restarting",
    pct: 100,
  },
  {
    name: "fast pull finishes with no layer reaching Pull complete",
    output: [
      " Image alpine:3.19 Pulling ",
      " 17a39c0ba978 Pulling fs layer 0B",
      " Image alpine:3.19 Pulled ",
    ].join("\n"),
    phase: "restarting",
    pct: 100,
  },
  {
    name: "mid download, layer detail on a single image",
    output: [
      " Image alpine:3.19 Pulling ",
      " 17a39c0ba978 Pulling fs layer 0B",
      " ef1614f30685 Download complete 0B",
      " 17a39c0ba978 Downloading 3.42MB",
    ].join("\n"),
    phase: "pulling",
    pct: 0,
    contains: "layers ready",
  },
  {
    name: "a stack reports images, not one image out of five",
    output: [
      " Image prom/prometheus:v3.14.0 Pulling ",
      " Image grafana/grafana:latest Pulling ",
      " Image prom/prometheus:v3.14.0 Pulled ",
    ].join("\n"),
    phase: "pulling",
    pct: 50,
    contains: "1 of 2 images ready",
  },
  {
    name: "up -d finished, last container line wins over the ones before it",
    output: [
      " Container immich-server Recreated ",
      " Container immich-db Starting ",
      " Container immich-db Waiting ",
      " Container immich-db Healthy ",
      " Container immich-server Starting ",
      " Container immich-server Started ",
    ].join("\n"),
    phase: "done",
    pct: 100,
  },
  {
    name: "still waiting on a healthcheck is not done",
    output: [" Container immich-server Recreated ", " Container immich-db Waiting "].join("\n"),
    phase: "restarting",
  },
  {
    name: "a failed pull is a failure, not a quiet success",
    output: [
      " Image nextcloud:34 Pulling ",
      "[WARN] nextcloud: pull failed, containers left on their current images",
    ].join("\n"),
    phase: "failed",
  },
  {
    name: "colour codes from the corex logger do not hide the state",
    output: ESC + "[0;34m[INFO]" + ESC + "[0m Updating adguard...\n Image adguard/adguardhome:latest Pulling ",
    phase: "pulling",
  },
  {
    name: "nothing yet",
    output: "",
    phase: "starting",
  },
]

let failures = 0
for (const c of CASES) {
  const got = updateProgress(c.output)
  const bad = []
  if (c.phase && got.phase !== c.phase) bad.push(`phase ${got.phase}, want ${c.phase}`)
  if (c.pct !== undefined && got.pct !== c.pct) bad.push(`pct ${got.pct}, want ${c.pct}`)
  if (c.contains && !got.detail.includes(c.contains)) {
    bad.push(`detail ${JSON.stringify(got.detail)} lacks ${JSON.stringify(c.contains)}`)
  }
  if (bad.length) {
    failures++
    console.error(`FAIL  ${c.name}\n      ${bad.join("\n      ")}`)
  }
}

// An "update all" run is one stream covering every service in turn. Without
// this the whole run is an opaque block and no card can show its own state.
const ALL = [
  "[STEP] Updating all installed services...",
  "[INFO] Updating adguard...",
  " Image adguard/adguardhome:latest Pulling ",
  " Image adguard/adguardhome:latest Pulled ",
  " Container adguard Started ",
  "[INFO] Updating nextcloud...",
  " Image nextcloud:34 Pulling ",
  " 17a39c0ba978 Downloading 1.049MB",
].join("\n")

if (currentTarget(ALL) !== "nextcloud") {
  failures++
  console.error(`FAIL  currentTarget = ${currentTarget(ALL)}, want nextcloud`)
}
const tail = sliceFor(ALL, "nextcloud")
if (tail.includes("adguard")) {
  failures++
  console.error("FAIL  sliceFor leaked the previous service's output into the next card")
}
if (updateProgress(tail).phase !== "pulling") {
  failures++
  console.error("FAIL  the sliced section does not report the service being worked on")
}
// The finished service must still read as finished from its own slice.
if (updateProgress(sliceFor(ALL, "adguard").split("[INFO] Updating nextcloud")[0]).phase !== "done") {
  failures++
  console.error("FAIL  a service that finished earlier in the run no longer reads as done")
}

if (failures) {
  console.error(`\nprogress-check: ${failures} failure(s)`)
  process.exit(1)
}
console.log(`progress-check: ${CASES.length + 4} checks passed`)
