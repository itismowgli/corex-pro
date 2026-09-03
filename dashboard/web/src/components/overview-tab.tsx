import * as React from "react"
import {
  ActivityIcon,
  AlertTriangleIcon,
  CpuIcon,
  HardDriveIcon,
  MemoryStickIcon,
  ThermometerIcon,
  TrashIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Meter, Spark } from "@/components/ui/spark"
import type { Overview } from "@/lib/api"
import { ago, bytes, duration, pct } from "@/lib/format"

/**
 * The whole box on one screen.
 *
 * The ordering is deliberate and it is not alphabetical: temperature first,
 * because this hardware trips at TjMax with no warning in any log and that is
 * the failure that takes the machine down; then memory and disk, which fill
 * slowly enough to be caught if anyone looks; then what is actually consuming
 * the machine; then the checks and the findings. Anything already wrong is
 * pulled to the top as a banner, so a problem is never something you have to
 * scroll to find.
 */

function Vital({
  icon: Icon,
  label,
  value,
  sub,
  tone,
  children,
}: {
  icon: React.ComponentType<{ className?: string }>
  label: string
  value: React.ReactNode
  sub?: React.ReactNode
  tone?: "ok" | "warn" | "danger"
  children?: React.ReactNode
}) {
  const color =
    tone === "danger" ? "text-destructive" : tone === "warn" ? "text-warn" : "text-foreground"
  return (
    <Card className="gap-2 py-3">
      <CardContent className="grid gap-1.5 px-3">
        <div className="text-muted-foreground flex items-center gap-1.5 text-xs">
          <Icon className="size-3.5" />
          {label}
        </div>
        <div className={`font-mono text-2xl leading-none ${color}`}>{value}</div>
        {sub && <div className="text-muted-foreground text-xs">{sub}</div>}
        {children}
      </CardContent>
    </Card>
  )
}

export function OverviewTab({
  data,
  loading,
  error,
}: {
  data: Overview | null
  loading: boolean
  error: string | null
}) {
  if (loading && !data) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[0, 1, 2, 3].map((i) => (
          <Skeleton key={i} className="h-28" />
        ))}
      </div>
    )
  }

  if (error && !data) {
    return (
      <Card className="border-destructive/50">
        <CardContent className="text-sm">
          <p className="font-medium">Could not read the box.</p>
          <p className="text-muted-foreground mt-1 font-mono text-xs">{error}</p>
        </CardContent>
      </Card>
    )
  }

  const m = data?.metrics ?? null
  const series = m?.series ?? []
  const temps = series.map((s) => s.temp)
  const loads = series.map((s) => s.load)
  const mems = series.map((s) => s.mem_used_mb)
  const throttled = series.some((s) => s.throttled)

  const temp = m?.cpu.temp_c ?? null
  const warnAt = m?.thermal.warn_c ?? 80
  const shedAt = m?.thermal.shed_c ?? 85
  const tempTone = temp == null ? undefined : temp >= shedAt ? "danger" : temp >= warnAt ? "warn" : "ok"

  const memUsed = m?.memory.used_mb ?? 0
  const memTotal = m?.memory.total_mb ?? 0
  const swapUsed = m?.memory.swap_used_mb ?? 0

  const reclaimable = Object.values(m?.docker ?? {}).reduce(
    (a, d) => a + (d?.reclaimable_b ?? 0),
    0
  )

  const monitorsDown = (m?.monitors ?? []).filter((x) => x.active && x.status === "down")
  const shed = m?.thermal.shed ?? []
  const badSmart = (m?.smart ?? []).filter((d) => /FAIL/i.test(d.status))
  const dpkgDirty = m?.dpkg && !m.dpkg.clean

  // Anything already wrong, gathered so it cannot be missed.
  const alarms: string[] = []
  if (temp != null && temp >= shedAt) alarms.push(`CPU at ${temp.toFixed(1)}C, at or past the shed threshold`)
  if (throttled) alarms.push("the CPU throttled within the last two hours")
  if (shed.length) alarms.push(`the thermal guardian has ${shed.length} container(s) shed`)
  if (monitorsDown.length) alarms.push(`${monitorsDown.length} uptime check(s) down: ${monitorsDown.map((x) => x.name).join(", ")}`)
  if (badSmart.length) alarms.push(`SMART failure on ${badSmart.map((d) => d.device).join(", ")}`)
  if (dpkgDirty) alarms.push(`dpkg has half-configured packages: ${m?.dpkg?.packages.join(", ")}`)
  if (data && !data.agent_ok) alarms.push("the action agent is unreachable, so no button here can work")
  for (const d of m?.disks ?? []) {
    if (d.pct >= 90) alarms.push(`${d.label} is ${d.pct}% full`)
  }
  if ((data?.containers.restarting ?? 0) > 0) {
    alarms.push(`${data?.containers.restarting} container(s) are restarting in a loop`)
  }

  return (
    <div className="flex flex-col gap-3">
      {alarms.length > 0 && (
        <Card className="border-destructive/50">
          <CardContent className="flex items-start gap-2 text-sm">
            <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
            <ul className="grid gap-0.5">
              {alarms.map((a) => (
                <li key={a}>{a}</li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Vital
          icon={ThermometerIcon}
          label="CPU temperature"
          value={temp == null ? "no sensor" : `${temp.toFixed(1)}°C`}
          tone={tempTone}
          sub={
            m?.cpu.temp_source === "none"
              ? "lm-sensors is not installed, so the most common failure here is invisible"
              : `warns at ${warnAt}°C, sheds load at ${shedAt}°C`
          }
        >
          <Spark values={temps} warnAbove={warnAt} label="CPU temperature, last two hours" />
        </Vital>

        <Vital
          icon={CpuIcon}
          label="Load"
          value={m?.cpu.load?.[0]?.toFixed(2) ?? "-"}
          sub={`${m?.cpu.cores ?? "?"} cores, 5 and 15 minute: ${
            m?.cpu.load?.slice(1).map((v) => v.toFixed(2)).join(" and ") ?? "-"
          }`}
        >
          <Spark values={loads} color="oklch(0.62 0.14 250)" label="Load average, last two hours" />
        </Vital>

        <Vital
          icon={MemoryStickIcon}
          label="Memory"
          value={`${pct(memTotal ? (memUsed / memTotal) * 100 : 0)}`}
          sub={`${(memUsed / 1024).toFixed(1)} of ${(memTotal / 1024).toFixed(0)} GB${
            swapUsed > 64 ? `, swapping ${swapUsed} MB` : ""
          }`}
        >
          <Spark values={mems} color="oklch(0.65 0.18 320)" label="Memory used, last two hours" />
        </Vital>

        <Vital
          icon={ActivityIcon}
          label="Running"
          value={`${data?.containers.running ?? 0}`}
          sub={`of ${data?.containers.total ?? 0} containers, up ${duration(m?.uptime_s)}`}
        >
          <div className="mt-1 flex flex-wrap gap-1">
            <Badge variant="ok">{data?.services.healthy ?? 0} healthy</Badge>
            {(data?.services.unhealthy ?? 0) > 0 && (
              <Badge variant="destructive">{data?.services.unhealthy} unhealthy</Badge>
            )}
            {(data?.services.stopped ?? 0) > 0 && (
              <Badge variant="secondary">{data?.services.stopped} stopped</Badge>
            )}
          </div>
        </Vital>
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              <HardDriveIcon className="size-4" />
              Disks
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-3">
            {(m?.disks ?? []).map((d) => (
              <Meter
                key={d.path}
                value={d.used_b}
                max={d.total_b}
                caption={
                  <>
                    {d.label} <span className="text-muted-foreground">{d.path}</span>
                  </>
                }
                right={`${bytes(d.used_b)} of ${bytes(d.total_b)} · ${d.pct}%`}
              />
            ))}
            {reclaimable > 0 && (
              <div className="mt-1 flex items-center gap-2 border-t pt-3 text-xs">
                <TrashIcon className="text-muted-foreground size-3.5 shrink-0" />
                <span>
                  <span className="font-mono">{bytes(reclaimable)}</span> is purgeable: unused
                  images and build cache. The Storage tab removes it without touching service
                  data.
                </span>
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Heaviest containers</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            {(data?.top ?? []).length === 0 && (
              <p className="text-muted-foreground text-xs">
                No container is reporting usage. Docker may still be starting.
              </p>
            )}
            {(data?.top ?? []).map((c) => (
              <div key={c.name} className="grid gap-1">
                <div className="flex items-baseline justify-between gap-2 text-xs">
                  <span className="truncate font-medium">{c.name}</span>
                  <span className="text-muted-foreground shrink-0 font-mono">
                    {c.cpu_percent.toFixed(1)}% CPU · {bytes(c.mem_bytes)}
                  </span>
                </div>
                <Meter
                  value={c.mem_bytes}
                  max={c.mem_limit || c.mem_bytes || 1}
                  tone={c.mem_percent >= 90 ? "danger" : "neutral"}
                />
              </div>
            ))}
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              Uptime checks
              <span className="text-muted-foreground text-xs font-normal">
                from Uptime Kuma
              </span>
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-1">
            {(m?.monitors ?? []).length === 0 && (
              <p className="text-muted-foreground text-xs">
                No monitors yet. Create them with{" "}
                <code className="text-foreground">sudo corex manage kuma-seed</code>.
              </p>
            )}
            {(m?.monitors ?? []).map((mon) => (
              <div
                key={mon.name}
                className="flex items-center justify-between gap-2 border-b py-1 text-xs last:border-0"
              >
                <span className="truncate">{mon.name}</span>
                <span className="flex shrink-0 items-center gap-2">
                  <span className="text-muted-foreground font-mono">
                    {mon.ping_ms != null ? `${Math.round(mon.ping_ms)} ms` : ""}
                  </span>
                  <Badge
                    variant={
                      !mon.active
                        ? "secondary"
                        : mon.status === "up"
                          ? "ok"
                          : mon.status === "down"
                            ? "destructive"
                            : "warn"
                    }
                  >
                    {mon.active ? mon.status : "paused"}
                  </Badge>
                </span>
              </div>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Recent findings</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-1.5">
            {(m?.watchdog ?? []).length === 0 && (
              <p className="text-muted-foreground text-xs">
                The resource watchdog has logged nothing. That is the good case.
              </p>
            )}
            {(m?.watchdog ?? []).slice(0, 10).map((f, i) => (
              <div key={`${f.t}-${i}`} className="grid gap-0.5 border-b pb-1.5 text-xs last:border-0">
                <div className="flex items-center gap-2">
                  <Badge variant={f.level === "down" ? "destructive" : f.level === "up" ? "ok" : "secondary"}>
                    {f.level}
                  </Badge>
                  <span className="text-muted-foreground" title={f.t}>
                    {ago(f.t)}
                  </span>
                </div>
                <span className="text-muted-foreground">{f.text}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
