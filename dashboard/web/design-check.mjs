/**
 * Enforces DESIGN.md.
 *
 * A design system that is only written down lasts until the next hurried
 * change. This dashboard had grown six type sizes outside any scale, four
 * radii, and colours written as literals in three components, none of which
 * any check could see, because every one of them compiles and renders.
 *
 * It cannot check taste. It checks that the vocabulary stays small, which is
 * most of what a design system is.
 *
 * When changing a rule here, put a violation back and confirm it fails.
 */
import fs from "node:fs"
import path from "node:path"

const SRC = path.join(import.meta.dirname, "src")

// index.css is where the vocabulary is defined, so it is the one file allowed
// to contain colour literals. Everything else references a token.
const TOKEN_SOURCE = "index.css"

const RULES = [
  {
    name: "colour literal outside index.css",
    // A token reference, var(--ok), is not a literal and must not match.
    re: /#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(/g,
    why: "Use a token from index.css. DESIGN.md, Colour, rule 1.",
  },
  {
    name: "type size outside the scale",
    re: /\btext-(xs|sm|base|lg|xl|[0-9]xl)\b|\btext-\[[^\]]*(px|rem|em)\]/g,
    why: "Use text-micro, text-small, text-body, text-title or text-display. DESIGN.md, Type, rule 5.",
  },
  {
    name: "radius outside the three steps",
    re: /\brounded-(xl|[0-9]xl)\b|\brounded(-[a-z]+)?-\[[^\]]*\]/g,
    why: "Use rounded-sm, rounded-md, rounded-lg or rounded-full. DESIGN.md, Radius, rule 9.",
  },
  {
    name: "motion outside the tokens",
    // Tailwind's own duration-N and easing utilities. The tokens are
    // --dur-fast, --dur and --ease, applied through duration-(--dur) and
    // ease-(--ease), so a bare number or named easing is a new value.
    re: /\bduration-[0-9]+\b|\bease-(in|out|in-out|linear)\b|\banimate-(bounce|ping)\b/g,
    why: "Use duration-(--dur-fast), duration-(--dur) and ease-(--ease). DESIGN.md, Motion, rules 10 and 11.",
  },
  {
    name: "arbitrary spacing",
    // Only size and spacing. data-[state=open] and has-[>svg] are variant
    // syntax, not values, and transition-[width] names a property.
    re: /\b[pm][trblxy]?-\[[^\]]*\]|\bgap(-[xy])?-\[[^\]]*\]|\bspace-[xy]-\[[^\]]*\]/g,
    why: "Use the 4px scale. DESIGN.md, Space, rule 7.",
  },
]

function walk(dir) {
  const out = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...walk(p))
    else if (/\.(tsx?|css)$/.test(entry.name)) out.push(p)
  }
  return out
}

const failures = []
let scanned = 0

for (const file of walk(SRC)) {
  const rel = path.relative(SRC, file)
  const text = fs.readFileSync(file, "utf8")
  scanned++
  for (const rule of RULES) {
    // index.css defines the vocabulary, so its own colour literals and
    // --text-*/--radius-* declarations are the definitions, not uses of them.
    if (rel === TOKEN_SOURCE) continue
    rule.re.lastIndex = 0
    let m
    while ((m = rule.re.exec(text)) !== null) {
      const line = text.slice(0, m.index).split("\n").length
      failures.push(`${rel}:${line}  ${rule.name}: ${JSON.stringify(m[0])}\n      ${rule.why}`)
    }
  }
}

if (failures.length) {
  console.error(`design-check FAILED, ${failures.length} violation(s):\n`)
  for (const f of failures.slice(0, 40)) console.error("  " + f)
  if (failures.length > 40) console.error(`  ... and ${failures.length - 40} more`)
  process.exit(1)
}
console.log(`design-check ok: ${scanned} files follow DESIGN.md`)
