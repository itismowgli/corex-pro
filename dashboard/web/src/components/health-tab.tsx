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
 * shutdown was not a shutdown at all. Those are here.
 *
 * Temperature leads because it is the measure this hardware actually fails by,
 * and it is the only thing on the page drawn rather than listed. "Disks and
 * packages" used to be one box holding two unrelated subjects, which is what a
 * grid of equal boxes quietly encourages: somewhere to put the leftovers.
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

  return (
    <div className="flex flex-col gap-6">
      <Section title="Temperature">
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
        <Rows>
          <Row
            label="Now"
            value={temp == null ? "no sensor" : `${temp.toFixed(1)}°C`}
            tone={temp == null ? undefined : temp >= shedAt ? "danger" : temp >= warnAt ? "warn" : "ok"}
            hint={
              m?.cpu.temp_source === "none"
                ? "lm-sensors is not installed. Without it a thermal trip looks exactly like someone pulling the plug."
                : `Warns at ${warnAt}°C, sheds load at ${shedAt}°C, the hardware cuts power around ${emergencyAt}°C.`
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
            hint="The CPU reducing its own clock is the last warning before it cuts power."
          />
          <Row
            label="Thermal guardian"
            value={!m?.thermal.enabled ? "off" : shed.length ? `${shed.length} shed` : "nothing shed"}
            tone={!m?.thermal.enabled || shed.length ? "warn" : "ok"}
            hint={
              shed.length
                ? `Stopped to save the machine: ${shed.join(", ")}. They come back as it cools.`
                : "Stops containers before the hardware decides to, worst first."
            }
          />
        </Rows>
      </Section>

      <Section title="Disks">
        {smart.length === 0 ? (
          <Empty>
            No self-test result was read. smartmontools may not be installed, and without it the
            most common hardware failure on this class of machine is invisible.
          </Empty>
        ) : (
          <Rows>
            {smart.map((d) => (
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
            ))}
          </Rows>
        )}
      </Section>

      <Section title="Package database">
        <Rows>
          <Row
            label="dpkg"
            value={m?.dpkg == null ? "not read" : m.dpkg.clean ? "clean" : "half configured"}
            tone={m?.dpkg == null ? undefined : m.dpkg.clean ? "ok" : "danger"}
            hint={
              m?.dpkg && !m.dpkg.clean
                ? `${m.dpkg.packages.join(", ")}. An upgrade interrupted by a power cut leaves this, and every boot retries and re-breaks it.`
                : "Nothing was left unpacked but unconfigured."
            }
          />
        </Rows>
      </Section>

      <Section
        title="Checks you can run"
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
          Everything above is read continuously. These run a command now: the hardware report
          re-reads sensors and SMART, the watchdog sweep looks for containers stopped against
          their restart policy, climbing restart counts and memory kills, and doctor repairs
          whatever it finds unhealthy.
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

      <Section title="What the watchdog has logged">
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
