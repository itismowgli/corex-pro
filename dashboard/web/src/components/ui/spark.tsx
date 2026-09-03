import * as React from "react"

import { cn } from "@/lib/utils"

/**
 * Small time-series charts, drawn as inline SVG.
 *
 * No charting library on purpose. This dashboard embeds everything it needs
 * in one binary and fetches nothing at runtime, because it is the page you
 * open when the box is in trouble, and a stylesheet on a CDN is unavailable
 * exactly then. A line, an area and a threshold band is the whole requirement,
 * and that is thirty lines of path arithmetic against three hundred kilobytes
 * of dependency.
 */

export type Point = { x: number; y: number }

function path(points: Point[], w: number, h: number, min: number, max: number) {
  if (points.length < 2) return { line: "", area: "" }
  const span = max - min || 1
  const step = w / (points.length - 1)
  const xy = points.map((p, i) => {
    const x = i * step
    const y = h - ((p.y - min) / span) * h
    return [x, Number.isFinite(y) ? y : h] as const
  })
  const line = xy.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ")
  const area = `${line} L${w},${h} L0,${h} Z`
  return { line, area }
}

export function Spark({
  values,
  height = 44,
  color = "var(--ok)",
  // Above this the line is drawn in the warning colour, so a chart that spent
  // ten minutes over the shed threshold says so without needing a legend.
  warnAbove,
  warnColor = "var(--warn)",
  min: forceMin,
  max: forceMax,
  className,
  label,
}: {
  values: number[]
  height?: number
  color?: string
  warnAbove?: number
  warnColor?: string
  min?: number
  max?: number
  className?: string
  label?: string
}) {
  const id = React.useId()
  const w = 100
  const clean = values.filter((v) => Number.isFinite(v))
  if (clean.length < 2) {
    return (
      <div
        className={cn("text-muted-foreground flex items-center justify-center text-xs", className)}
        style={{ height }}
      >
        not enough history yet
      </div>
    )
  }
  const min = forceMin ?? Math.min(...clean)
  const max = forceMax ?? Math.max(...clean)
  const pts = clean.map((y, x) => ({ x, y }))
  const { line, area } = path(pts, w, height, min, max)
  const last = clean[clean.length - 1]
  const stroke = warnAbove !== undefined && last >= warnAbove ? warnColor : color

  return (
    <svg
      viewBox={`0 0 ${w} ${height}`}
      preserveAspectRatio="none"
      className={cn("w-full", className)}
      style={{ height }}
      role="img"
      aria-label={label}
    >
      <defs>
        <linearGradient id={`g${id}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={stroke} stopOpacity="0.28" />
          <stop offset="100%" stopColor={stroke} stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill={`url(#g${id})`} />
      <path
        d={line}
        fill="none"
        stroke={stroke}
        strokeWidth="1.4"
        vectorEffect="non-scaling-stroke"
        strokeLinejoin="round"
      />
    </svg>
  )
}

/**
 * A labelled proportion bar. Used for disks, memory and per-service size, so
 * those three read the same way instead of each inventing a presentation.
 */
export function Meter({
  value,
  max,
  caption,
  right,
  tone = "auto",
  className,
}: {
  value: number
  max: number
  caption?: React.ReactNode
  right?: React.ReactNode
  tone?: "auto" | "ok" | "warn" | "danger" | "neutral"
  className?: string
}) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0
  const resolved =
    tone === "auto" ? (pct >= 90 ? "danger" : pct >= 75 ? "warn" : "ok") : tone
  const color = {
    ok: "var(--ok)",
    warn: "var(--warn)",
    danger: "var(--destructive)",
    neutral: "var(--muted-foreground)",
  }[resolved]

  return (
    <div className={cn("grid gap-1", className)}>
      {(caption || right) && (
        <div className="flex items-baseline justify-between gap-2 text-xs">
          <span className="truncate">{caption}</span>
          <span className="text-muted-foreground shrink-0 font-mono">{right}</span>
        </div>
      )}
      <div className="bg-muted h-1.5 w-full overflow-hidden rounded-full">
        <div
          className="h-full rounded-full transition-[width]"
          style={{ width: `${pct}%`, backgroundColor: color }}
        />
      </div>
    </div>
  )
}
