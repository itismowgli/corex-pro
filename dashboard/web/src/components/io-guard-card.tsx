import * as React from "react"
import { HardDriveIcon } from "lucide-react"

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Row, Rows } from "@/components/ui/section"
import { Segmented } from "@/components/ui/segmented"
import { Switch } from "@/components/ui/switch"
import type { IoGuard, IoGuardSettings } from "@/lib/api"

/**
 * The guard that reboots the machine when its system disk stops answering.
 *
 * A card rather than a section because it is an object with its own controls,
 * and it sits beside Power because it is the other thing on this page that can
 * restart the machine. Every change asks for the same proof a reboot does:
 * turning it off or lengthening the limit decides how long the house goes
 * without its services the next time the disk hangs.
 *
 * The state line is the part worth reading. "Watching" is the normal answer,
 * and a stall shows its seconds counting up, so a slow disk is visible before
 * it becomes a reboot.
 */

const STALL = [
  { value: "60", label: "1 min" },
  { value: "120", label: "2 min" },
  { value: "300", label: "5 min" },
  { value: "600", label: "10 min" },
]
const GRACE = [
  { value: "300", label: "5 min" },
  { value: "600", label: "10 min" },
  { value: "1200", label: "20 min" },
]
const ACTION = [
  { value: "power-cycle", label: "Power cycle" },
  { value: "reboot", label: "Restart" },
  { value: "alert", label: "Alert only" },
]

function nearest(options: { value: string }[], n: number) {
  return options.reduce((a, o) =>
    Math.abs(Number(o.value) - n) < Math.abs(Number(a.value) - n) ? o : a
  ).value
}

function when(at: string) {
  const d = new Date(at.replace(/([+-]\d\d)(\d\d)$/, "$1:$2"))
  return Number.isNaN(d.getTime()) ? at : d.toLocaleString()
}

/** Seconds as the largest unit that reads naturally. */
function span(sec: number): string {
  if (sec < 90) return `${sec} seconds`
  if (sec < 5400) return `${Math.round(sec / 60)} minutes`
  if (sec < 172800) return `${Math.round(sec / 3600)} hours`
  return `${(sec / 86400).toFixed(1)} days`
}

export function IoGuardCard({
  data,
  busy,
  onSave,
}: {
  data: IoGuard | null
  busy: boolean
  onSave: (settings: IoGuardSettings) => void
}) {
  const s = data?.status ?? null

  if (!data?.installed) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-body">
            <HardDriveIcon className="size-4" />
            Automatic restart
          </CardTitle>
        </CardHeader>
        <CardContent className="text-muted-foreground text-body">
          Not installed. Install it with{" "}
          <code className="text-foreground">sudo corex manage io-guard setup</code>.
        </CardContent>
      </Card>
    )
  }

  const devices = Object.entries(s?.devices ?? {})
  const worst = devices.reduce((m, [, d]) => Math.max(m, d.stalled_sec || 0), 0)
  const state = !data.running
    ? { text: "Not running", tone: "danger" as const }
    : !s?.enabled
      ? { text: "Off", tone: "warn" as const }
      : s.state === "stuck" || s.state === "stalling"
        ? { text: `Disk stalled for ${worst}s`, tone: "danger" as const }
        : s.in_boot_grace
          ? { text: "Watching, waiting out the first minutes after boot", tone: "ok" as const }
          : { text: "Watching", tone: "ok" as const }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-body">
          <HardDriveIcon className="size-4" />
          Automatic restart
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <p className="text-muted-foreground text-body">
          When the system disk stops answering, nothing that needs it can run and the hardware
          watchdog never fires. This restarts the machine instead of waiting for someone to reach
          the power button. Each change asks you to confirm who you are.
        </p>

        <Rows>
          <Row label="State" value={state.text} tone={state.tone} />
          <Row
            label="Disks watched"
            value={devices.length ? devices.map(([d]) => d).join(", ") : "none found"}
            hint={
              s?.devices_setting === "auto"
                ? "Chosen automatically: everything on the disk that holds the system."
                : undefined
            }
          />
          {s?.action === "power-cycle" && s.rtc_alarm === false && (
            <Row
              label="Wake alarm"
              value="not available"
              tone="warn"
              hint="This board has no wake alarm the guard can set, so it will reboot instead of power cycling."
            />
          )}
          {s && !s.memory_locked && (
            <Row
              label="Memory lock"
              value="not held"
              tone="warn"
              hint="The guard could be paged out and stall with the disk it is watching."
            />
          )}
        </Rows>

        <div className="flex items-center justify-between gap-3">
          <span className="text-body">Restart automatically when the disk is stuck</span>
          <Switch
            checked={!!s?.enabled}
            disabled={busy || !s}
            busy={busy}
            label="Automatic restart"
            onCheckedChange={(on) => onSave({ enabled: on })}
          />
        </div>

        {s && (
          <div className="grid gap-3 sm:grid-cols-3">
            <div className="flex flex-col gap-1.5">
              <span className="text-muted-foreground text-small">When it is stuck</span>
              <Segmented
                label="Action"
                size="sm"
                options={ACTION}
                value={s.action}
                onChange={(v) => !busy && onSave({ action: v as IoGuardSettings["action"] })}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <span className="text-muted-foreground text-small">Stuck for at least</span>
              <Segmented
                label="Stall limit"
                size="sm"
                options={STALL}
                value={nearest(STALL, s.stall_sec)}
                onChange={(v) => !busy && onSave({ stall_sec: Number(v) })}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <span className="text-muted-foreground text-small">Not in the first</span>
              <Segmented
                label="Boot grace"
                size="sm"
                options={GRACE}
                value={nearest(GRACE, s.boot_grace_sec)}
                onChange={(v) => !busy && onSave({ boot_grace_sec: Number(v) })}
              />
            </div>
          </div>
        )}

        {data.events.some((e) => e.event !== "start") && (
          <div className="border-t pt-3">
            <p className="text-body font-medium">Times it acted</p>
            <Rows>
              {data.events
                .filter((e) => e.event !== "start")
                .slice(0, 6)
                .map((e) => (
                  <Row
                    key={e.at + e.event}
                    label={when(e.at)}
                    value={
                      e.event === "reboot"
                        ? "Restarted"
                        : e.event === "power-cycle"
                          ? "Power cycled"
                          : e.event === "returned"
                            ? e.unattended
                              ? `Back on its own after ${span(e.after_sec ?? 0)}`
                              : `Down for ${span(e.after_sec ?? 0)}`
                            : "Alerted"
                    }
                    tone={
                      e.event === "alert" || (e.event === "returned" && e.unattended)
                        ? undefined
                        : "warn"
                    }
                    hint={
                      e.event === "returned" && !e.unattended
                        ? "The automatic recovery did not bring it back. Someone had to."
                        : e.device
                          ? `${e.device}: ${e.in_flight ?? "?"} requests waiting, ${e.stalled_sec ?? "?"}s with none completing`
                          : undefined
                    }
                  />
                ))}
            </Rows>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
