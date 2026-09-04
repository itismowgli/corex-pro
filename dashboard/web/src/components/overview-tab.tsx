import * as React from "react"
import {
  ActivityIcon,
  AlertTriangleIcon,
  ChevronRightIcon,
  CpuIcon,
  HardDriveIcon,
  MemoryStickIcon,
  RadioIcon,
  ThermometerIcon,
  TrashIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Meter, Spark } from "@/components/ui/spark"
import type { Consumer } from "@/components/consumers-dialog"
import type { Overview, Vitals } from "@/lib/api"
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

export function OverviewTab({
  data,
  vitals,
  live,
  loading,
  error,
  onDrill,
}: {
  data: Overview | null
  /** Pushed every five seconds. The polled payload fills in the rest. */
  vitals: Vitals | null
  live: boolean
  loading: boolean
  error: string | null
  onDrill: (what: Consumer) => void
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

  // The stream wins where it has an answer: it is five seconds old at worst,
  // and the polled payload can be half a minute behind.
  const temp = vitals?.temp_c ?? m?.cpu.temp_c ?? null
  const load0 = vitals?.load?.[0] ?? m?.cpu.load?.[0] ?? null
  const loadRest = vitals?.load?.slice(1) ?? m?.cpu.load?.slice(1) ?? []
  const cores = vitals?.cores ?? m?.cpu.cores ?? null
  const running = vitals?.containers_running ?? data?.containers.running ?? 0
  const totalContainers = vitals?.containers_total ?? data?.containers.total ?? 0
  const restarting = vitals?.containers_restarting ?? data?.containers.restarting ?? 0
  const top = vitals?.top ?? data?.top ?? []
  const warnAt = m?.thermal.warn_c ?? 80
  const shedAt = m?.thermal.shed_c ?? 85
  const tempTone = temp == null ? undefined : temp >= shedAt ? "danger" : temp >= warnAt ? "warn" : "ok"
  // A load average is only legible against the core count, so the tone is the
  // ratio and not the number: 4.0 is idle on sixteen cores and a queue on two.
  const loadRatio = load0 != null && cores ? load0 / cores : null
  const loadTone =
    loadRatio == null ? undefined : loadRatio >= 1 ? "danger" : loadRatio >= 0.7 ? "warn" : "ok"

  const memUsed = vitals?.mem_used_mb ?? m?.memory.used_mb ?? 0
  const memTotal = vitals?.mem_total_mb ?? m?.memory.total_mb ?? 0
  const swapUsed = vitals?.swap_used_mb ?? m?.memory.swap_used_mb ?? 0

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
  if (restarting > 0) {
    alarms.push(`${restarting} container(s) are restarting in a loop`)
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

      <div className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <RadioIcon className={`size-3 ${live ? "text-ok" : "text-muted-foreground"}`} />
        {live ? "Live, updating every five seconds" : "Reconnecting to the live feed"}
        <span className="ml-auto hidden sm:inline">Tap a tile to see what is using it</span>
      </div>

      <div className="grid grid-cols-2 gap-2 sm:gap-3 lg:grid-cols-4">
        <Vital
          onOpen={() => onDrill("cpu")}
          icon={ThermometerIcon}
          label="CPU temperature"
          value={temp == null ? "no sensor" : `${temp.toFixed(1)}°C`}
          of={temp == null ? undefined : `${shedAt}°C`}
          ratio={temp == null ? undefined : temp / shedAt}
          tone={tempTone}
          sub={
            m?.cpu.temp_source === "none"
              ? "lm-sensors is not installed, so the most common failure here is invisible"
              : `the guardian warns at ${warnAt}°C and sheds load at ${shedAt}°C`
          }
        >
          <Spark values={temps} warnAbove={warnAt} label="CPU temperature, last two hours" />
        </Vital>

        <Vital
          onOpen={() => onDrill("cpu")}
          icon={CpuIcon}
          label="Load"
          value={load0?.toFixed(2) ?? "-"}
          of={cores ? `${cores} cores` : undefined}
          ratio={load0 != null && cores ? load0 / cores : undefined}
          tone={loadTone}
          sub={`five and fifteen minutes: ${
            loadRest.map((v) => v.toFixed(2)).join(" and ") || "-"
          }`}
        >
          <Spark values={loads} color="oklch(0.62 0.14 250)" label="Load average, last two hours" />
        </Vital>

        <Vital
          onOpen={() => onDrill("memory")}
          icon={MemoryStickIcon}
          label="Memory"
          value={`${(memUsed / 1024).toFixed(1)} GB`}
          of={memTotal ? `${(memTotal / 1024).toFixed(0)} GB` : undefined}
          ratio={memTotal ? memUsed / memTotal : undefined}
          sub={`${pct(memTotal ? (memUsed / memTotal) * 100 : 0)} used${
            swapUsed > 64 ? `, swapping ${swapUsed} MB` : ""
          }`}
        >
          <Spark values={mems} color="oklch(0.65 0.18 320)" label="Memory used, last two hours" />
        </Vital>

        <Vital
          onOpen={() => onDrill("containers")}
          icon={ActivityIcon}
          label="Containers running"
          value={`${running}`}
          of={totalContainers ? `${totalContainers}` : undefined}
          ratio={totalContainers ? running / totalContainers : undefined}
          tone="ok"
          sub={`up ${duration(m?.uptime_s)}`}
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
            <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
              <HardDriveIcon className="size-4" />
              Disks
              <Button
                size="xs"
                variant="ghost"
                className="ml-auto"
                onClick={() => onDrill("disk")}
              >
                What is using it
              </Button>
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
            <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
              Heaviest containers
              <Button
                size="xs"
                variant="ghost"
                className="ml-auto"
                onClick={() => onDrill("containers")}
              >
                See all
              </Button>
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            {top.length === 0 && (
              <p className="text-muted-foreground text-xs">
                No container is reporting usage. Docker may still be starting.
              </p>
            )}
            {top.map((c) => (
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
