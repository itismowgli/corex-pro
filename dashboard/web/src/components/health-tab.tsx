import {
  ActivityIcon,
  HardDriveIcon,
  PackageIcon,
  StethoscopeIcon,
  ThermometerIcon,
  WrenchIcon,
} from "lucide-react"

import { Ansi } from "@/lib/ansi"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Spark } from "@/components/ui/spark"
import type { Metrics } from "@/lib/api"
import { ago } from "@/lib/format"

/**
 * The half of monitoring an HTTP check cannot see.
 *
 * A reachability check says a hostname answered. It cannot say the CPU is
 * three degrees below the point where this hardware cuts its own power with
 * nothing in any log, that a disk is failing its self-test, that dpkg was left
 * half configured by an upgrade interrupted mid-transaction, or that the last
 * shutdown was not a shutdown at all. Those are here.
 */

function Row({
  label,
  value,
  tone = "ok",
  detail,
}: {
  label: string
  value: string
  tone?: "ok" | "warn" | "destructive" | "secondary"
  detail?: React.ReactNode
}) {
  return (
    <div className="flex items-start justify-between gap-3 border-b py-2 text-sm last:border-0">
      <div className="grid gap-0.5">
        <span>{label}</span>
        {detail && <span className="text-muted-foreground text-xs">{detail}</span>}
      </div>
      <Badge variant={tone}>{value}</Badge>
    </div>
  )
}

export function HealthTab({
  metrics,
  outputs,
  running,
  locked,
  onRun,
}: {
  metrics: Metrics | null
  outputs: Record<string, string>
  running: string | null
  locked: boolean
  onRun: (action: string) => void
}) {
  const m = metrics
  const temp = m?.cpu.temp_c ?? null
  const warnAt = m?.thermal.warn_c ?? 80
  const shedAt = m?.thermal.shed_c ?? 85
  const series = m?.series ?? []
  const throttled = series.filter((s) => s.throttled).length
  const peak = series.length ? Math.max(...series.map((s) => s.temp)) : null
  const shed = m?.thermal.shed ?? []

  return (
    <div className="flex flex-col gap-3">
      <div className="grid gap-3 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              <ThermometerIcon className="size-4" />
              Heat
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-3">
            <Spark
              values={series.map((s) => s.temp)}
              height={64}
              warnAbove={warnAt}
              label="CPU temperature over the last two hours"
            />
            <Row
              label="Now"
              value={temp == null ? "no sensor" : `${temp.toFixed(1)}°C`}
              tone={
                temp == null
                  ? "secondary"
                  : temp >= shedAt
                    ? "destructive"
                    : temp >= warnAt
                      ? "warn"
                      : "ok"
              }
              detail={
                m?.cpu.temp_source === "none"
                  ? "lm-sensors is not installed. Without it a thermal trip looks exactly like someone pulling the plug."
                  : `Warns at ${warnAt}°C, sheds load at ${shedAt}°C, hardware cuts power around ${m?.thermal.emergency_c ?? 97}°C.`
              }
            />
            <Row
              label="Peak in the last two hours"
              value={peak == null ? "-" : `${peak.toFixed(1)}°C`}
              tone={peak != null && peak >= shedAt ? "warn" : "ok"}
            />
            <Row
              label="Throttling"
              value={throttled ? `${throttled} sample(s)` : "none"}
              tone={throttled ? "warn" : "ok"}
              detail="The CPU reducing its own clock is the last warning before it cuts power."
            />
            <Row
              label="Thermal guardian"
              value={
                !m?.thermal.enabled
                  ? "off"
                  : shed.length
                    ? `${shed.length} shed`
                    : "nothing shed"
              }
              tone={!m?.thermal.enabled ? "warn" : shed.length ? "warn" : "ok"}
              detail={
                shed.length
                  ? `Stopped to save the machine: ${shed.join(", ")}. They come back as it cools.`
                  : "Stops containers before the hardware decides to, worst first."
              }
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              <HardDriveIcon className="size-4" />
              Disks and packages
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-1">
            {(m?.smart ?? []).map((d) => (
              <Row
                key={d.device}
                label={d.device}
                value={d.status}
                tone={
                  /PASSED|OK/i.test(d.status)
                    ? "ok"
                    : /FAIL/i.test(d.status)
                      ? "destructive"
                      : "secondary"
                }
                detail={
                  d.status === "not reported"
                    ? "A USB bridge often will not pass SMART through, so this is unknown rather than bad."
                    : undefined
                }
              />
            ))}
            {(m?.smart ?? []).length === 0 && (
              <Row label="SMART" value="not read" tone="secondary" detail="smartmontools may not be installed." />
            )}
            <Row
              label="Package database"
              value={m?.dpkg == null ? "not read" : m.dpkg.clean ? "clean" : "half configured"}
              tone={m?.dpkg == null ? "secondary" : m.dpkg.clean ? "ok" : "destructive"}
              detail={
                m?.dpkg && !m.dpkg.clean
                  ? `${m.dpkg.packages.join(", ")}. An upgrade interrupted by a power cut leaves this, and every boot retries and re-breaks it.`
                  : "No package was left unpacked but unconfigured."
              }
            />
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
            <ActivityIcon className="size-4" />
            Deeper checks
            <span className="ml-auto flex flex-wrap gap-2">
              <Button size="xs" variant="secondary" disabled={locked} onClick={() => onRun("health")}>
                <ThermometerIcon />
                {running === "health" ? "Running..." : "Hardware report"}
              </Button>
              <Button size="xs" variant="secondary" disabled={locked} onClick={() => onRun("watchdog")}>
                <PackageIcon />
                {running === "watchdog" ? "Running..." : "Watchdog sweep"}
              </Button>
              <Button size="xs" variant="outline" disabled={locked} onClick={() => onRun("doctor")}>
                <StethoscopeIcon />
                {running === "doctor" ? "Running..." : "Doctor"}
              </Button>
            </span>
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3">
          <p className="text-muted-foreground text-xs">
            The panels above are read continuously. These run a command now: the hardware
            report re-reads sensors and SMART, the watchdog sweep looks for containers stopped
            against their restart policy, climbing restart counts and memory kills, and doctor
            repairs whatever it finds unhealthy.
          </p>
          {["health", "watchdog", "doctor"].map((k) =>
            outputs[k] ? (
              <div key={k} className="grid gap-1">
                <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
                  <WrenchIcon className="size-3" />
                  {k}
                </span>
                <Ansi
                  text={outputs[k]}
                  className="term bg-background max-h-[45vh] overflow-auto rounded-md border p-3"
                />
              </div>
            ) : null
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">What the watchdog has logged</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-1.5">
          {(m?.watchdog ?? []).length === 0 && (
            <p className="text-muted-foreground text-xs">Nothing, which is the good case.</p>
          )}
          {(m?.watchdog ?? []).map((f, i) => (
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
  )
}
