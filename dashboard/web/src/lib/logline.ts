/**
 * Turning a container log line into something readable.
 *
 * Every image writes its own format. Traefik emits logfmt with a three letter
 * level, Nextcloud writes a combined access line, AdGuard writes a
 * slash-separated date, Uptime Kuma writes a bracketed subsystem, and Cal.com
 * writes a task prefix with no timestamp at all. Rendered as one
 * undifferentiated monospace block they look equally important, which is the
 * same problem stripping colour out of a CoreX command would cause: the line
 * that matters looks exactly like the ones that do not.
 *
 * Each timestamp pattern knows how to remove itself, delimiters included. That
 * is not tidiness. A generic "strip anything bracket-shaped from the front"
 * pass turned "[MONITOR] WARN: ..." into "MONITOR] WARN: ..." and left a bare
 * "[]" where an access log's date had been. Guessing wrong and mangling a line
 * is worse than leaving it exactly as it came, so anything unrecognised is
 * passed through untouched.
 */

export type Level = "error" | "warn" | "info" | "debug" | "none"

export type ParsedLine = {
  raw: string
  /** Just the clock, because the date is nearly always today. */
  clock: string
  level: Level
  message: string
}

// Anchored and narrow on purpose. A loose pattern matches the word "error"
// inside a URL and paints a routine request red. WRN and ERR are here because
// Traefik writes those and the first version missed every warning it emitted.
const LEVEL_WORD =
  /(?:^|[\s[|"'=(])(EMERG|ALERT|CRIT|CRITICAL|FATAL|ERROR|ERRO|ERR|WARNING|WARN|WRN|NOTICE|INFO|INF|DEBUG|DBG|TRACE|TRC)(?:[\s\]|"':,)]|$)/i

type Matcher = { re: RegExp; clock: (m: RegExpMatchArray) => string }

// Ordered most specific first. The combined access-log form has to be tried
// before the bare ISO one, or "03/Sep/2026:16:18:09" yields "26:18:09" from
// the middle of the year.
const TIME_PATTERNS: Matcher[] = [
  // Combined access log: [03/Sep/2026:16:18:09 +0000], brackets included so
  // removing it does not leave "[]" behind.
  {
    re: /\[\d{2}\/\w{3}\/\d{4}:(\d{2}:\d{2}:\d{2})(?:\s[+-]\d{4})?\]\s?/,
    clock: (m) => m[1],
  },
  // ISO 8601, with or without a zone.
  {
    re: /\d{4}-\d{2}-\d{2}[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s?/,
    clock: (m) => m[1],
  },
  // Slash-separated, which is what AdGuard and nginx error logs write.
  {
    re: /\d{4}\/\d{2}\/\d{2}\s(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s?/,
    clock: (m) => m[1],
  },
  // A bare clock at the very start of the line, and only there.
  { re: /^(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s/, clock: (m) => m[1] },
]

function normaliseLevel(word: string): Level {
  const w = word.toUpperCase()
  if (["EMERG", "ALERT", "CRIT", "CRITICAL", "FATAL", "ERROR", "ERRO", "ERR"].includes(w))
    return "error"
  if (["WARNING", "WARN", "WRN"].includes(w)) return "warn"
  if (["NOTICE", "INFO", "INF"].includes(w)) return "info"
  if (["DEBUG", "DBG", "TRACE", "TRC"].includes(w)) return "debug"
  return "none"
}

/** The fields a JSON line carries besides the message, as short key=value pairs. */
function compact(o: Record<string, unknown>): string {
  const skip = new Set([
    "msg", "message", "level", "severity", "lvl", "time", "ts", "timestamp",
  ])
  return Object.entries(o)
    .filter(([k, v]) => !skip.has(k) && v !== null && v !== undefined && v !== "")
    .slice(0, 8)
    .map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : String(v)}`)
    .join(" ")
}

export function parseLine(raw: string): ParsedLine {
  const line = raw.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")

  // JSON first: a structured logger has already done this work, and guessing
  // at its text would only lose the fields.
  const trimmed = line.trim()
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    try {
      const o = JSON.parse(trimmed) as Record<string, unknown>
      const lvl = String(o.level ?? o.severity ?? o.lvl ?? "")
      const msg = String(o.msg ?? o.message ?? o.error ?? trimmed)
      const t = String(o.time ?? o.ts ?? o.timestamp ?? "")
      const clock = t.match(/(\d{2}:\d{2}:\d{2})/)?.[1] ?? ""
      const rest = compact(o)
      return {
        raw,
        clock,
        level: lvl ? normaliseLevel(lvl) : "none",
        // Keep the other fields. Dropping them hides the request id or the
        // status code, which is usually why the line was being read.
        message: rest ? `${msg}  ${rest}` : msg,
      }
    } catch {
      // Not JSON after all. Fall through and treat it as text.
    }
  }

  let clock = ""
  let message = line
  for (const { re, clock: pick } of TIME_PATTERNS) {
    const m = message.match(re)
    if (!m) continue
    clock = pick(m)
    message = (message.slice(0, m.index) + message.slice((m.index ?? 0) + m[0].length)).trimStart()
    break
  }

  return {
    raw,
    clock,
    level: normaliseLevel(line.match(LEVEL_WORD)?.[1] ?? ""),
    message: message.trimEnd(),
  }
}
