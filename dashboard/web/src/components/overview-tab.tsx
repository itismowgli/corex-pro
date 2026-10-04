import * as React from "react"
import {
  ActivityIcon,
  AlertTriangleIcon,
  CpuIcon,
  MemoryStickIcon,
  RadioIcon,
  ThermometerIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Segmented } from "@/components/ui/segmented"
import { Button } from "@/components/ui/button"
import { Empty, Row, Rows, Section } from "@/components/ui/section"
import { Skeleton } from "@/components/ui/skeleton"
import { Meter, Spark } from "@/components/ui/spark"
import { StatTile } from "@/components/stat-tile"
import type { Consumer } from "@/components/consumers-dialog"
import type { Overview, Vitals } from "@/lib/api"
import { usePageVisible } from "@/lib/use-page-visible"
import { bytes, duration, pct } from "@/lib/format"

/**
 * The whole box on one screen.
 *
 * The ordering is deliberate and it is not alphabetical: temperature first,
 * because this hardware trips at TjMax with no warning in any log and that is
 * the failure that takes the machine down; then load, memory and containers;
 * then what is actually consuming the machine. Anything already wrong is
 * pulled to the top as a banner, so a problem is never something you have to
 * scroll to find.
 *
 * The four tiles are the one loud thing on the page, and everything under them
 * is quiet by design. This is the page you open when something is wrong, so
 * the live numbers have to win the moment it loads.
 *
 * "Recent findings" used to sit at the bottom repeating the watchdog log that
 * Health already owns in full. The banner above carries anything urgent, so
 * the copy here was a second, shorter, staler version of a list that lives
 * somewhere else.
 */

const RANGES = { "30m": 90, "1h": 180, all: 0 } as const
type RangeKey = keyof typeof RANGES
const RANGE_LABEL: Record<RangeKey, string> = {
  "30m": "30 min",
  "1h": "1 hour",
  all: "2 hours",
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
  const pageVisible = usePageVisible()
  const [range, setRange] = React.useState<RangeKey>("all")

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
      <Empty className="border-destructive/50">
        Could not read the box. <span className="font-mono">{error}</span>
      </Empty>
    )
  }

  const m = data?.metrics ?? null
  const series = m?.series ?? []
  // The charts follow the chosen window; the alarms below never do. An alarm
  // that quietly narrows with the chart would answer "did this box throttle"
  // with whichever window happened to be selected.
  const shown = range === "all" ? series : series.slice(-RANGES[range])
  const temps = shown.map((s) => s.temp)
  const loads = shown.map((s) => s.load)
  const mems = shown.map((s) => s.mem_used_mb)
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

  const monitors = m?.monitors ?? []
  const monitorsDown = monitors.filter((x) => x.active && x.status === "down")
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
    <div className="flex flex-col gap-6">
      {alarms.length > 0 && (
        <div className="border-destructive/50 flex items-start gap-2 rounded-lg border px-3 py-2">
          <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
          <ul className="flex flex-col gap-0.5">
            {alarms.map((a) => (
              <li key={a}>{a}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex flex-col gap-3">
        <div className="text-muted-foreground flex items-center gap-1.5 text-small">
          <RadioIcon className={`size-3 ${live ? "text-ok" : "text-muted-foreground"}`} />
          {!pageVisible
            ? "Paused while this page is hidden"
            : live
              ? "Host vitals live, containers every 30 seconds"
              : "Connecting to the live feed"}
          <div className="ml-auto flex items-center gap-1">
            <span className="mr-1 hidden lg:inline">Tap a tile to see what is using it</span>
            <Segmented
              label="How far back the charts go"
              size="sm"
              value={range}
              onChange={setRange}
              options={(Object.keys(RANGES) as RangeKey[]).map((k) => ({
                value: k,
                label: RANGE_LABEL[k],
              }))}
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-2 sm:gap-3 lg:grid-cols-4">
          <StatTile
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
            <Spark values={temps} warnAbove={warnAt} label={`CPU temperature, last ${RANGE_LABEL[range]}`} />
          </StatTile>

          <StatTile
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
            <Spark values={loads} color="var(--chart-load)" label={`Load average, last ${RANGE_LABEL[range]}`} />
          </StatTile>

          <StatTile
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
            <Spark values={mems} color="var(--chart-mem)" label={`Memory used, last ${RANGE_LABEL[range]}`} />
          </StatTile>

          <StatTile
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
              {(data?.services.sleeping ?? 0) > 0 && (
                <Badge variant="secondary">{data?.services.sleeping} sleeping</Badge>
              )}
              {(data?.services.stopped ?? 0) > 0 && (
                <Badge variant="secondary">{data?.services.stopped} stopped</Badge>
              )}
            </div>
          </StatTile>
        </div>
      </div>

      <Section
        title="Heaviest containers"
        action={
          <Button size="xs" variant="ghost" onClick={() => onDrill("containers")}>
            See all
          </Button>
        }
      >
        {top.length === 0 ? (
          <Empty>No container is reporting usage. Docker may still be starting.</Empty>
        ) : (
          <div className="flex flex-col gap-2">
            {top.map((c) => (
              <Meter
                key={c.name}
                value={c.mem_bytes}
                max={c.mem_limit || c.mem_bytes || 1}
                tone={c.mem_percent >= 90 ? "danger" : "neutral"}
                caption={c.name}
                right={`${c.cpu_percent.toFixed(1)}% CPU, ${bytes(c.mem_bytes)}`}
              />
            ))}
          </div>
        )}
      </Section>

      <Section
        title="Disks"
        action={
          <Button size="xs" variant="ghost" onClick={() => onDrill("disk")}>
            What is using it
          </Button>
        }
      >
        {(m?.disks ?? []).length === 0 ? (
          <Empty>No filesystem was reported.</Empty>
        ) : (
          <div className="flex flex-col gap-3">
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
                right={`${bytes(d.used_b)} of ${bytes(d.total_b)}, ${d.pct}%`}
              />
            ))}
          </div>
        )}
      </Section>

      <Section title="Uptime checks">
        {monitors.length === 0 ? (
          <Empty>
            No monitors yet. Create them with{" "}
            <code className="text-foreground">sudo corex manage kuma-seed</code>.
          </Empty>
        ) : (
          <Rows>
            {monitors.map((mon) => (
              <Row
                key={mon.name}
                label={mon.name}
                value={
                  <span className="flex items-center gap-2">
                    {mon.ping_ms != null && <span>{Math.round(mon.ping_ms)} ms</span>}
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
                }
              />
            ))}
          </Rows>
        )}
      </Section>
    </div>
  )
}
