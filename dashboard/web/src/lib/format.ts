/** Presentation helpers, in one place so every panel says it the same way. */

export function bytes(n: number | null | undefined, digits = 1): string {
  if (n == null || !Number.isFinite(n)) return "-"
  if (n < 1000) return `${n} B`
  const units = ["kB", "MB", "GB", "TB", "PB"]
  let v = n / 1000
  let i = 0
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000
    i++
  }
  return `${v.toFixed(v >= 100 ? 0 : digits)} ${units[i]}`
}

export function duration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return "-"
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (d) return `${d}d ${h}h`
  if (h) return `${h}h ${m}m`
  return `${m}m`
}

/**
 * A timestamp as "how long ago", which is what an operator actually wants
 * from a log line. Absolute times are kept in the title attribute.
 */
export function ago(iso: string | null | undefined): string {
  if (!iso) return "-"
  const t = Date.parse(iso.replace(" ", "T"))
  if (!Number.isFinite(t)) return iso
  const s = Math.max(0, (Date.now() - t) / 1000)
  if (s < 60) return "just now"
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

export function pct(v: number | null | undefined, digits = 0): string {
  if (v == null || !Number.isFinite(v)) return "-"
  return `${v.toFixed(digits)}%`
}
