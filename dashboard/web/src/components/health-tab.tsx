import { StethoscopeIcon, ThermometerIcon, WrenchIcon } from "lucide-react"

import { Ansi } from "@/lib/ansi"
import { BandGauge } from "@/components/ui/band-gauge"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, Row, Rows, Section } from "@/components/ui/section"
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
 * shutdown was not a shutdown at all.
 *
 * One scannable list answers "is anything wrong", because that is the only
 * question this page is opened with. It had five headings over eight facts,
 * one of them wrapping a single row, which is structure doing nothing: a
 * heading per fact is the same as no headings at all, with more to read.
 *
 * Explanation is kept where it changes what you would do and dropped where it
 * only says what a word already means. The sentence about lm-sensors stays,
 * because a missing sensor is a thing to fix; "the CPU reducing its own clock
 * is the last warning before it cuts power" went, because the row is already
 * amber and says Throttling.
 */

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
  const emergencyAt = m?.thermal.emergency_c ?? 97
  const series = m?.series ?? []
  const throttled = series.filter((s) => s.throttled).length
  const peak = series.length ? Math.max(...series.map((s) => s.temp)) : null
  const shed = m?.thermal.shed ?? []
  const smart = m?.smart ?? []
  const findings = m?.watchdog ?? []
  const dpkg = m?.dpkg

  return (
    <div className="flex flex-col gap-6">
      {/* No heading. This list is what the page is, and naming it "Status"
          would be a label on the only thing present. */}
      <Rows>
        <Row
          label="Temperature"
          value={temp == null ? "no sensor" : `${temp.toFixed(1)}°C`}
          tone={temp == null ? undefined : temp >= shedAt ? "danger" : temp >= warnAt ? "warn" : "ok"}
          hint={
            m?.cpu.temp_source === "none"
              ? "lm-sensors is not installed. Without it a thermal trip looks exactly like someone pulling the plug."
              : undefined
          }
        />
        <Row
          label="Peak in the last two hours"
          value={peak == null ? "not recorded" : `${peak.toFixed(1)}°C`}
          tone={peak != null && peak >= shedAt ? "warn" : "ok"}
        />
        <Row
          label="Throttling"
          value={throttled ? `${throttled} samples` : "none"}
          tone={throttled ? "warn" : "ok"}
        />
        <Row
          label="Thermal guardian"
          value={!m?.thermal.enabled ? "off" : shed.length ? `${shed.length} shed` : "nothing shed"}
          tone={!m?.thermal.enabled || shed.length ? "warn" : "ok"}
          hint={shed.length ? `Stopped to save the machine: ${shed.join(", ")}.` : undefined}
        />
        {smart.length === 0 ? (
          <Row
            label="Disks"
            value="not read"
            hint="smartmontools is not installed, so the most common hardware failure here is invisible."
          />
        ) : (
          smart.map((d) => (
            <Row
              key={d.device}
              label={d.device}
              value={d.status}
              tone={/PASSED|OK/i.test(d.status) ? "ok" : /FAIL/i.test(d.status) ? "danger" : undefined}
              hint={
                d.status === "not reported"
                  ? "A USB bridge usually will not pass SMART through, so this is unknown rather than bad."
                  : undefined
              }
            />
          ))
        )}
        <Row
          label="Package database"
          value={dpkg == null ? "not read" : dpkg.clean ? "clean" : "half configured"}
          tone={dpkg == null ? undefined : dpkg.clean ? "ok" : "danger"}
          hint={
            dpkg && !dpkg.clean
              ? `${dpkg.packages.join(", ")}. Every boot retries and re-breaks this until it is repaired.`
              : undefined
          }
        />
      </Rows>

      <Section title="Temperature over two hours">
        <Spark
          values={series.map((s) => s.temp)}
          height={72}
          warnAbove={warnAt}
          label="CPU temperature over the last two hours"
        />
        {temp != null && (
          <BandGauge
            value={temp}
            bands={[warnAt, shedAt, emergencyAt]}
            max={Math.max(100, emergencyAt)}
            title={`CPU ${temp.toFixed(1)}°C against the warn, shed and emergency thresholds`}
          />
        )}
        <p className="text-muted-foreground text-small">
          Warns at {warnAt}°C, sheds load at {shedAt}°C, the hardware cuts power around{" "}
          {emergencyAt}°C.
        </p>
      </Section>

      <Section
        title="Checks"
        action={
          <>
            <Button size="xs" variant="secondary" disabled={locked} onClick={() => onRun("health")}>
              <ThermometerIcon />
              {running === "health" ? "Running" : "Hardware"}
            </Button>
            <Button size="xs" variant="secondary" disabled={locked} onClick={() => onRun("watchdog")}>
              <WrenchIcon />
              {running === "watchdog" ? "Running" : "Watchdog"}
            </Button>
            <Button size="xs" variant="outline" disabled={locked} onClick={() => onRun("doctor")}>
              <StethoscopeIcon />
              {running === "doctor" ? "Running" : "Doctor"}
            </Button>
          </>
        }
      >
        <p className="text-muted-foreground text-small">
          Everything above is read continuously. These run now: hardware re-reads sensors and
          SMART, watchdog looks for containers stopped against their restart policy and memory
          kills, doctor repairs what it finds unhealthy.
        </p>
        {["health", "watchdog", "doctor"].map((k) =>
          outputs[k] ? (
            <div key={k} className="flex flex-col gap-1">
              <span className="text-muted-foreground text-small">{k}</span>
              <Ansi
                text={outputs[k]}
                className="term bg-muted/40 max-h-[45vh] overflow-auto rounded-lg px-3 py-2"
              />
            </div>
          ) : null
        )}
      </Section>

      <Section title="Watchdog log">
        {findings.length === 0 ? (
          <Empty>Nothing, which is the good case.</Empty>
        ) : (
          <Rows>
            {findings.map((f, i) => (
              <Row
                key={`${f.t}-${i}`}
                label={
                  <span className="flex items-center gap-2">
                    <Badge
                      variant={f.level === "down" ? "destructive" : f.level === "up" ? "ok" : "secondary"}
                    >
                      {f.level}
                    </Badge>
                    <span title={f.t}>{ago(f.t)}</span>
                  </span>
                }
                hint={f.text}
              />
            ))}
          </Rows>
        )}
      </Section>
    </div>
  )
}
