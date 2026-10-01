import {
  AlertTriangleIcon,
  ArchiveIcon,
  Trash2Icon,
  HardDriveDownloadIcon,
  LoaderCircleIcon,
  PackageIcon,
  PlayIcon,
  SearchIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Empty, Row, Rows } from "@/components/ui/section"
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
 *
 * A task keeps its card, because each one is an object with its own action and
 * its own history, which is exactly what a card is for. The facts inside it
 * are rows.
 */

const ICON: Record<MaintenanceTaskName, typeof PlayIcon> = {
  backup: ArchiveIcon,
  cleanup: Trash2Icon,
  timemachine: HardDriveDownloadIcon,
  updates: SearchIcon,
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

/**
 * The schedule in one phrase. "*" is any hour, so there is no time of day to
 * name and saying "around 0:00" would be an invented one.
 */
function schedule(t: MaintenanceTask): string {
  if (!t.enabled) return "off"
  const at = typeof t.hour === "number" ? `, around ${t.hour}:00` : ", whenever it falls due"
  return `${every(t.interval_h)}${at}`
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
    return <Empty>Waiting for the agent to report the schedule.</Empty>
  }

  if (!data.installed) {
    return (
      <div className="border-warn/50 flex flex-col gap-2 rounded-lg border px-3 py-3">
        <p className="font-medium">Nothing is scheduled</p>
        <p className="text-muted-foreground text-small">
          Backups, Docker cleanup and the update check are not running on a schedule on this box.
          Install the hourly timer over SSH:
        </p>
        <pre className="term bg-muted/40 rounded-lg px-3 py-2">
          sudo corex manage maintenance setup
        </pre>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4">
      {!data.timer_active && (
        <div className="border-destructive/50 flex items-start gap-2 rounded-lg border px-3 py-2">
          <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
          <div>
            <p className="font-medium">The timer is installed but not running, so nothing is due.</p>
            <p className="text-muted-foreground text-small">
              Start it with{" "}
              <code className="text-foreground">
                sudo systemctl enable --now corex-maintenance.timer
              </code>
              .
            </p>
          </div>
        </div>
      )}

      {!data.enabled && (
        <div className="border-warn/50 flex flex-col gap-1 rounded-lg border px-3 py-2">
          <p className="font-medium">Maintenance is switched off in the config.</p>
          <p className="text-muted-foreground text-small">
            MAINTENANCE_ENABLED=false in /etc/corex/maintenance.conf. The timer still fires and
            does nothing. Buttons here still work.
          </p>
        </div>
      )}

      {data.tasks.map((t) => {
        const Icon = ICON[t.name] ?? PlayIcon
        const o = outcome(t)
        const busy = running === t.name
        const out = outputs[t.name]
        return (
          <Card key={t.name}>
            <CardHeader>
              <CardTitle className="flex flex-wrap items-center gap-2">
                <Icon className="size-4 shrink-0" />
                {t.label}
                <Badge variant={o.tone}>{o.text}</Badge>
                {!t.enabled && <Badge variant="outline">not scheduled</Badge>}
                <Button
                  size="xs"
                  variant="secondary"
                  className="ml-auto"
                  disabled={locked || busy}
                  onClick={() => onRun(t.name)}
                >
                  {busy ? <LoaderCircleIcon className="animate-spin" /> : <PlayIcon />}
                  {busy ? "Running" : "Run now"}
                </Button>
              </CardTitle>
              <p className="text-muted-foreground text-small">{t.description}</p>
            </CardHeader>
            <CardContent className="flex flex-col gap-2">
              <Rows>
                <Row label="Schedule" value={schedule(t)} />
                <Row label="Last run" value={when(t.last)} />
                {t.last > 0 && <Row label="Took" value={duration(t.elapsed)} />}
                {t.enabled && t.next > 0 && <Row label="Due next" value={when(t.next)} />}
              </Rows>

              {t.detail && (
                <p
                  className={
                    t.state === "failed"
                      ? "text-destructive text-small break-words"
                      : "text-muted-foreground text-small break-words"
                  }
                >
                  {t.detail}
                </p>
              )}

              {/* A refusal to start is its own thing, shown only when it is
                  the most recent event. It does not reset the clock, so the
                  rows above still describe the last time this really ran. */}
              {t.deferred_at > t.last && (
                <p className="text-warn text-small break-words">
                  Held back {when(t.deferred_at)}: {t.deferred_detail || "the machine was too hot"}
                </p>
              )}

              {out && (
                <div className="w-full overflow-x-auto">
                  <pre className="term bg-muted/40 rounded-lg px-3 py-2">
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
