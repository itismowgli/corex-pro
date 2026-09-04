import * as React from "react"
import { ChevronRightIcon } from "lucide-react"

import { Card, CardContent } from "@/components/ui/card"
import { Meter } from "@/components/ui/spark"

/**
 * One headline number, written as a value against the capacity it is measured
 * in: 71.6C of 85C, 4.6 GB of 30.8 GB, 22 of 39 containers.
 *
 * A bare number needs the reader to know the machine before it means anything,
 * and a load of 4.0 is idle on sixteen cores and a queue on two. The bar and
 * the colour come from the ratio, so the tile is legible at a glance and the
 * same shape on every page that has a headline number.
 */
export function StatTile({
  icon: Icon,
  label,
  value,
  of,
  ratio,
  sub,
  tone,
  onOpen,
  children,
}: {
  icon: React.ComponentType<{ className?: string }>
  label: string
  value: React.ReactNode
  /** The capacity the value is measured against, written as it is read. */
  of?: React.ReactNode
  /** Where the value sits in that capacity, 0 to 1, drawn as the bar. */
  ratio?: number
  sub?: React.ReactNode
  tone?: "ok" | "warn" | "danger"
  /** Clicking the tile answers "which app is doing this". */
  onOpen?: () => void
  children?: React.ReactNode
}) {
  const color =
    tone === "danger" ? "text-destructive" : tone === "warn" ? "text-warn" : "text-foreground"
  const body = (
    <CardContent className="grid gap-2 px-4">
      <div className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Icon className="size-3.5 shrink-0" />
        <span className="truncate">{label}</span>
        {onOpen && <ChevronRightIcon className="ml-auto size-3.5 shrink-0 opacity-50" />}
      </div>
      <div className="flex flex-wrap items-baseline gap-x-1.5">
        <span className={`font-mono text-xl leading-none sm:text-2xl ${color}`}>{value}</span>
        {of && <span className="text-muted-foreground text-xs">of {of}</span>}
      </div>
      {ratio !== undefined && (
        <Meter value={Math.max(0, ratio)} max={1} tone={tone ?? "auto"} />
      )}
      {sub && <div className="text-muted-foreground text-xs">{sub}</div>}
      {children}
    </CardContent>
  )
  if (!onOpen) return <Card className="gap-2 py-4">{body}</Card>
  return (
    <button
      type="button"
      onClick={onOpen}
      aria-label={`${label}, see what is using it`}
      className="focus-visible:ring-ring/50 rounded-xl text-left focus-visible:ring-[3px] focus-visible:outline-none"
    >
      <Card className="hover:border-ring h-full gap-2 py-4 transition-colors">{body}</Card>
    </button>
  )
}
