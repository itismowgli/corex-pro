/**
 * Checks the log parser against lines real containers actually emit.
 *
 * Every case below is a line taken off the running box, and every one of them
 * was parsed wrongly by the first version: Traefik's WRN was read as having no
 * level at all, an access log's clock came out as "26:18:09" from the middle
 * of the year, removing that timestamp left a bare "[]", and a generic
 * leading-bracket strip turned "[MONITOR]" into "MONITOR]". None of that is
 * visible in a type check or a render check, because the output is still a
 * string and the page still draws it.
 *
 * The parser is TypeScript, so it is compiled to a temp directory and imported
 * rather than duplicated here. Duplicating it would test the copy.
 */
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const out = fs.mkdtempSync(path.join(os.tmpdir(), "logline-"))
// skipLibCheck and an empty typeRoots: a one-off tsc invocation outside the
// project's tsconfig otherwise type-checks every @types package in
// node_modules and fails on their own unresolved imports, which has nothing to
// do with this file.
execFileSync(
  "npx",
  [
    "tsc", "src/lib/logline.ts",
    "--outDir", out,
    "--module", "esnext",
    "--target", "es2022",
    "--moduleResolution", "bundler",
    "--skipLibCheck",
    "--typeRoots", path.join(out, "no-types"),
  ],
  { cwd: import.meta.dirname, stdio: "inherit" }
)
const { parseLine } = await import(path.join(out, "logline.js"))

const CASES = [
  {
    name: "Traefik warning, three letter level",
    line: '2026-09-03T15:54:56Z WRN A new release of Traefik has been found: 3.7.12.',
    level: "warn",
    clock: "15:54:56",
  },
  {
    name: "Traefik error, quoted logfmt",
    line: '2026-09-03T16:49:43Z ERR error="middleware \\"dash-lan@file\\" does not exist" routerName=dashboard@docker',
    level: "error",
    clock: "16:49:43",
  },
  {
    name: "combined access log, clock must not come from the year",
    line: '172.18.0.7 - - [03/Sep/2026:18:09:57 +0000] "GET /login HTTP/1.1" 200 8268',
    level: "none",
    clock: "18:09:57",
    notIn: "[]",
  },
  {
    name: "bracketed subsystem keeps its bracket",
    line: "2026-09-03T23:31:59.123Z [MONITOR] WARN: Monitor #10 'CPU Temperature': Failing",
    level: "warn",
    clock: "23:31:59",
    contains: "[MONITOR]",
  },
  {
    name: "slash separated date, as AdGuard writes",
    line: "2026/09/03 17:18:09.216239 [error] dnsproxy: exchange failed upstream=https://dns10.quad9.net",
    level: "error",
    clock: "17:18:09",
  },
  {
    name: "no timestamp at all is left alone",
    line: "@calcom/web:start: Processing 0 tasks []",
    level: "none",
    clock: "",
    contains: "@calcom/web:start:",
  },
  {
    name: "structured JSON keeps its extra fields",
    line: '{"level":"error","msg":"upstream failed","time":"2026-09-03T10:11:12Z","status":502}',
    level: "error",
    clock: "10:11:12",
    contains: "status=502",
  },
  {
    name: "the word error inside a URL is not a level",
    line: '172.18.0.7 - - [03/Sep/2026:18:09:57 +0000] "GET /docs/error-handling HTTP/1.1" 200 12',
    level: "none",
  },
]

let failed = 0
for (const c of CASES) {
  const p = parseLine(c.line)
  const problems = []
  if (c.level !== undefined && p.level !== c.level)
    problems.push(`level ${JSON.stringify(p.level)}, expected ${JSON.stringify(c.level)}`)
  if (c.clock !== undefined && p.clock !== c.clock)
    problems.push(`clock ${JSON.stringify(p.clock)}, expected ${JSON.stringify(c.clock)}`)
  if (c.contains && !p.message.includes(c.contains))
    problems.push(`message is missing ${JSON.stringify(c.contains)}: ${JSON.stringify(p.message)}`)
  if (c.notIn && p.message.includes(c.notIn))
    problems.push(`message still contains ${JSON.stringify(c.notIn)}: ${JSON.stringify(p.message)}`)
  if (problems.length) {
    failed++
    console.error("logline-check FAILED: " + c.name)
    for (const x of problems) console.error("  - " + x)
  } else {
    console.error("  ok  " + c.name)
  }
}

fs.rmSync(out, { recursive: true, force: true })
if (failed) process.exit(1)
console.error("logline-check ok: " + CASES.length + " real log shapes parse correctly")
