/**
 * Structural invariants for small screens.
 *
 * jsdom does no layout, so it cannot tell you a table pushed the page sideways
 * on a phone. What it can do is nothing, which is why this is a source check
 * rather than a render one: each rule below is a mistake that was actually in
 * the tree, and each is visible in the markup without measuring anything.
 *
 * Deliberately a short list. A long one becomes a style guide nobody reads,
 * and these four are the ones that make a page unusable at 360px rather than
 * merely untidy.
 */
import fs from "node:fs"
import path from "node:path"

const root = path.join(import.meta.dirname, "src")

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name)
    return e.isDirectory() ? walk(p) : p.endsWith(".tsx") ? [p] : []
  })
}

const files = walk(root)
const problems = []
const rel = (f) => path.relative(import.meta.dirname, f)

for (const f of files) {
  const src = fs.readFileSync(f, "utf8")
  const lines = src.split("\n")

  // 1. A wide table has to scroll inside its own box, or the whole page does.
  lines.forEach((line, i) => {
    if (!line.includes("<Table>")) return
    const before = lines.slice(Math.max(0, i - 3), i).join(" ")
    if (!/overflow-(x-)?auto/.test(before)) {
      problems.push(`${rel(f)}:${i + 1} a <Table> with no overflow-x-auto around it`)
    }
  })

  // 2. A dialog wider than the viewport cannot be closed on a phone, because
  //    the close control ends up off screen.
  lines.forEach((line, i) => {
    if (!line.includes("<DialogContent")) return
    if (/sm:max-w-(xl|2xl|3xl|4xl|5xl|6xl|7xl)/.test(line) && !line.includes("max-w-[calc(100vw")) {
      problems.push(`${rel(f)}:${i + 1} a wide DialogContent with no viewport cap`)
    }
  })

  // 3. A multi-column grid with no breakpoint stays multi-column at 360px.
  lines.forEach((line, i) => {
    const m = line.match(/className="[^"]*\bgrid-cols-([2-9])\b[^"]*"/)
    if (!m) return
    if (!/\b(sm|md|lg|xl):grid-cols-/.test(line) && !/\bgrid-cols-1\b/.test(line)) {
      problems.push(`${rel(f)}:${i + 1} grid-cols-${m[1]} with no smaller breakpoint`)
    }
  })

  // 4. A fixed pixel width that exceeds a narrow phone.
  lines.forEach((line, i) => {
    const m = line.match(/\bw-\[(\d{3,})px\]/)
    if (m && Number(m[1]) > 320) {
      problems.push(`${rel(f)}:${i + 1} a fixed ${m[1]}px width, wider than a small phone`)
    }
  })
}

if (problems.length) {
  console.error("responsive-check FAILED")
  for (const p of problems) console.error("  - " + p)
  process.exit(1)
}
console.error(`responsive-check ok: ${files.length} components hold the small-screen rules`)
