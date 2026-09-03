import * as React from "react"
import { ArrowDownIcon } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Meter } from "@/components/ui/spark"
import { api, type ContainerRow, type Metrics } from "@/lib/api"
import { bytes, pct } from "@/lib/format"

/**
 * What is actually using the machine, the way Activity Monitor or Task Manager
 * answers it: a sorted list, biggest first, with a bar you can read at a
 * glance.
 *
 * Opened by clicking the vital you are asking about, so "why is it hot" leads
 * straight to the containers burning CPU and "what filled the disk" leads to
 * the services holding the space. A number on its own only tells you there is
 * a problem; this says whose.
 */

export type Consumer = "cpu" | "memory" | "disk" | "containers"

const TITLE: Record<Consumer, string> = {
  cpu: "What is using the processor",
  memory: "What is using the memory",
  disk: "What is using the disk",
  containers: "Every container",
}

const NOTE: Record<Consumer, string> = {
  cpu: "Sampled live from Docker. Percentages are of one core, so a container using two cores fully reads as 200%.",
  memory: "Resident memory, against each container's own limit where one is set.",
  disk: "Measured by walking each service's data directory, which is why it is refreshed every fifteen minutes rather than live.",
  containers: "Everything Docker knows about, running or not, sorted by processor use.",
}

function Rows({ rows, mode }: { rows: ContainerRow[]; mode: Consumer }) {
  const sorted = React.useMemo(() => {
    const copy = rows.slice()
    copy.sort((a, b) =>
      mode === "memory" ? b.mem_bytes - a.mem_bytes : b.cpu_percent - a.cpu_percent
    )
    return copy
  }, [rows, mode])

  const peak =
    mode === "memory"
      ? Math.max(1, ...sorted.map((r) => r.mem_bytes))
      : Math.max(1, ...sorted.map((r) => r.cpu_percent))

  return (
    <div className="grid gap-2">
      {sorted.map((c) => (
        <div key={c.name} className="grid gap-1">
          <div className="flex flex-wrap items-baseline justify-between gap-x-2 gap-y-0.5">
            <span className="flex min-w-0 items-center gap-1.5">
              <span className="truncate text-sm">{c.name}</span>
              {c.service && c.service !== c.name && (
                <span className="text-muted-foreground shrink-0 text-xs">{c.service}</span>
              )}
              {c.status !== "running" && (
                <Badge variant="secondary" className="shrink-0">
                  {c.status}
                </Badge>
              )}
              {c.restarts > 3 && (
                <Badge variant="warn" className="shrink-0">
                  {c.restarts} restarts
                </Badge>
              )}
              {c.oom_killed && (
                <Badge variant="destructive" className="shrink-0">
                  killed for memory
                </Badge>
              )}
            </span>
            <span className="text-muted-foreground shrink-0 font-mono text-xs">
              {mode === "memory"
                ? `${bytes(c.mem_bytes)}${c.mem_limit ? ` of ${bytes(c.mem_limit)}` : ""}`
                : pct(c.cpu_percent, 1)}
            </span>
          </div>
          <Meter
            value={mode === "memory" ? c.mem_bytes : c.cpu_percent}
            max={peak}
            tone={
              mode === "memory" && c.mem_percent >= 90
                ? "danger"
                : mode === "memory" && c.mem_percent >= 75
                  ? "warn"
                  : "neutral"
            }
          />
        </div>
      ))}
      {sorted.length === 0 && (
        <p className="text-muted-foreground text-xs">Nothing is reporting usage.</p>
      )}
    </div>
  )
}

function DiskRows({ metrics }: { metrics: Metrics | null }) {
  const sizes = metrics?.service_sizes ?? []
  const biggest = sizes.length ? sizes[0].bytes : 1
  const reclaimable = Object.values(metrics?.docker ?? {}).reduce(
    (a, d) => a + (d?.reclaimable_b ?? 0),
    0
  )
  return (
    <div className="grid gap-3">
      {(metrics?.disks ?? []).map((d) => (
        <Meter
          key={d.path}
          value={d.used_b}
          max={d.total_b}
          caption={
            <>
              {d.label} <span className="text-muted-foreground">{d.path}</span>
            </>
          }
          right={`${bytes(d.used_b)} of ${bytes(d.total_b)}`}
        />
      ))}
      {reclaimable > 0 && (
        <p className="text-warn text-xs">
          {bytes(reclaimable)} of that is unused images and build cache, and the Storage tab
          can reclaim it without touching service data.
        </p>
      )}
      <div className="border-t pt-3">
        {sizes.length === 0 ? (
          <p className="text-muted-foreground text-xs">
            Still measuring. Walking a photo library takes a while, so it runs in the
            background and refreshes every fifteen minutes.
          </p>
        ) : (
          <div className="grid gap-2">
            {sizes.map((s) => (
              <Meter
                key={s.name}
                value={s.bytes}
                max={biggest}
                tone="neutral"
                caption={s.name}
                right={bytes(s.bytes)}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

export function ConsumersDialog({
  mode,
  metrics,
  onClose,
}: {
  mode: Consumer | null
  metrics: Metrics | null
  onClose: () => void
}) {
  const [rows, setRows] = React.useState<ContainerRow[]>([])
  const [error, setError] = React.useState<string | null>(null)

  // Refreshed while the dialog is open, because the question being asked is
  // "what is doing this right now" and a frozen list answers a different one.
  React.useEffect(() => {
    if (!mode || mode === "disk") return
    let alive = true
    const load = async () => {
      try {
        const next = await api.containers()
        if (alive) {
          setRows(next)
          setError(null)
        }
      } catch (e) {
        if (alive) setError(e instanceof Error ? e.message : String(e))
      }
    }
    void load()
    const t = window.setInterval(load, 5000)
    return () => {
      alive = false
      window.clearInterval(t)
    }
  }, [mode])

  return (
    <Dialog open={!!mode} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-[calc(100vw-1.5rem)] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base">
            <ArrowDownIcon className="size-4" />
            {mode ? TITLE[mode] : ""}
          </DialogTitle>
        </DialogHeader>
        <p className="text-muted-foreground text-xs">{mode ? NOTE[mode] : ""}</p>
        {error && (
          <p className="text-destructive text-xs" role="alert">
            {error}
          </p>
        )}
        <div className="max-h-[60vh] overflow-auto pr-1">
          {mode === "disk" ? (
            <DiskRows metrics={metrics} />
          ) : (
            <Rows rows={rows} mode={mode ?? "cpu"} />
          )}
        </div>
        <div>
          <Button size="xs" variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
