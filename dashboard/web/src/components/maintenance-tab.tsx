import * as React from "react"
import {
  AlertTriangleIcon,
  ArchiveIcon,
  Trash2Icon,
  CalendarClockIcon,
  HardDriveDownloadIcon,
  LoaderCircleIcon,
  PackageIcon,
  PlayIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Ansi } from "@/lib/ansi"
import type { Maintenance, MaintenanceTask, MaintenanceTaskName } from "@/lib/api"
import { duration } from "@/lib/format"

/**
 * What is meant to happen on a schedule, and what actually happened.
 *
 * The second half is the point. A page that shows only the schedule reports a
 * backup as configured on a box whose Restic repository does not exist, which
 * is worse than showing nothing: it answers "am I backed up" with a lie. So
 * every row here reads the runner's own history, a task that has never run
 * says so, and a missing prerequisite is recorded as a failure rather than
 * skipped.
 */

const ICON: Record<MaintenanceTaskName, typeof PlayIcon> = {
  backup: ArchiveIcon,
  cleanup: Trash2Icon,
  timemachine: HardDriveDownloadIcon,
  "os-upgrade": PackageIcon,
}

/** How a run reads, and how alarming it is. */
function outcome(t: MaintenanceTask): { text: string; tone: "ok" | "warn" | "destructive" | "secondary" } {
  if (!t.last) return { text: "Never run", tone: "warn" }
  switch (t.state) {
    case "ok":
      return { text: "Last run worked", tone: "ok" }
    case "failed":
      return { text: "Last run failed", tone: "destructive" }
    default:
      return { text: "Outcome not recorded", tone: "secondary" }
  }
}

/** A unix second as a readable local time, and how long ago that was. */
function when(unix: number): string {
  if (!unix) return "never"
  const d = new Date(unix * 1000)
  const secs = Math.max(0, Date.now() / 1000 - unix)
  const rel =
    secs < 3600
      ? `${Math.floor(secs / 60)}m ago`
      : secs < 86400
        ? `${Math.floor(secs / 3600)}h ago`
        : `${Math.floor(secs / 86400)}d ago`
  return `${d.toLocaleString()} (${rel})`
}

function every(hours: number): string {
  if (!hours) return "no interval set"
  if (hours % 168 === 0) {
    const w = hours / 168
    return w === 1 ? "weekly" : `every ${w} weeks`
  }
  if (hours % 24 === 0) {
    const d = hours / 24
    return d === 1 ? "daily" : `every ${d} days`
  }
  return `every ${hours}h`
}

export function MaintenanceTab({
  data,
  outputs,
  running,
  locked,
  onRun,
}: {
  data: Maintenance | null
  outputs: Record<string, string>
  running: string | null
  locked: boolean
  onRun: (task: MaintenanceTaskName) => void
}) {
  if (!data) {
    return (
      <Card>
        <CardContent className="text-muted-foreground text-sm">
          Waiting for the agent to report the schedule.
        </CardContent>
      </Card>
    )
  }

  if (!data.installed) {
    return (
      <Card className="border-warn/50">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <CalendarClockIcon className="size-4" />
            Nothing is scheduled
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 text-sm">
          <p>
            Backups, Docker cleanup and the Time Machine check are not running on a schedule on this
            box. Install the hourly timer over SSH:
          </p>
          <pre className="term bg-background rounded-md border p-3">
            sudo corex manage maintenance setup
          </pre>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      {!data.timer_active && (
        <Card className="border-destructive/50">
          <CardContent className="flex items-start gap-2 text-sm">
            <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
            <div>
              <p className="font-medium">The timer is installed but not running, so nothing is due.</p>
              <p className="text-muted-foreground mt-1 text-xs">
                Start it with{" "}
                <code className="text-foreground">
                  sudo systemctl enable --now corex-maintenance.timer
                </code>
                .
              </p>
            </div>
          </CardContent>
        </Card>
      )}

      {!data.enabled && (
        <Card className="border-warn/50">
          <CardContent className="text-sm">
            <p className="font-medium">Maintenance is switched off in the config.</p>
            <p className="text-muted-foreground mt-1 text-xs">
              MAINTENANCE_ENABLED=false in /etc/corex/maintenance.conf. The timer still fires and
              does nothing. Buttons here still work.
            </p>
          </CardContent>
        </Card>
      )}

      {data.tasks.map((t) => {
        const Icon = ICON[t.name] ?? PlayIcon
        const o = outcome(t)
        const busy = running === t.name
        const out = outputs[t.name]
        return (
          <Card key={t.name}>
            <CardHeader>
              <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
                <Icon className="size-4 shrink-0" />
                {t.label}
                <Badge variant={o.tone}>{o.text}</Badge>
                {!t.enabled && <Badge variant="outline">not scheduled</Badge>}
              </CardTitle>
              <p className="text-muted-foreground text-xs">{t.description}</p>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              <div className="grid gap-1 text-sm sm:grid-cols-2">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-muted-foreground text-xs">Schedule</span>
                  <span className="text-xs">
                    {t.enabled ? `${every(t.interval_h)}, around ${t.hour}:00` : "off"}
                  </span>
                </div>
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-muted-foreground text-xs">Last run</span>
                  <span className="text-xs">{when(t.last)}</span>
                </div>
                {t.last > 0 && (
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="text-muted-foreground text-xs">Took</span>
                    <span className="text-xs">{duration(t.elapsed)}</span>
                  </div>
                )}
                {t.enabled && t.next > 0 && (
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="text-muted-foreground text-xs">Due next</span>
                    <span className="text-xs">{when(t.next)}</span>
                  </div>
                )}
              </div>

              {t.detail && (
                <p
                  className={
                    t.state === "failed"
                      ? "text-destructive text-xs break-words"
                      : "text-muted-foreground text-xs break-words"
                  }
                >
                  {t.detail}
                </p>
              )}

              {/* A refusal to start is its own thing, shown only when it is
                  the most recent event. It does not reset the clock, so the
                  row above still describes the last time this really ran. */}
              {t.deferred_at > t.last && (
                <p className="text-warn text-xs break-words">
                  Held back {when(t.deferred_at)}: {t.deferred_detail || "the machine was too hot"}
                </p>
              )}

              <div>
                <Button size="sm" variant="secondary" disabled={locked || busy} onClick={() => onRun(t.name)}>
                  {busy ? <LoaderCircleIcon className="animate-spin" /> : <PlayIcon />}
                  {busy ? "Running" : "Run now"}
                </Button>
              </div>

              {out && (
                <div className="w-full overflow-x-auto">
                  <pre className="term bg-background rounded-md border p-3">
                    <Ansi text={out} />
                  </pre>
                </div>
              )}
            </CardContent>
          </Card>
        )
      })}
    </div>
  )
}
