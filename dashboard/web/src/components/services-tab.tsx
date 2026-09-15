import * as React from "react"
import {
  ExternalLinkIcon,
  Loader2Icon,
  PlayIcon,
  RefreshCwIcon,
  RotateCcwIcon,
  ScrollTextIcon,
  SquareIcon,
  WrenchIcon,
} from "lucide-react"

import { StatusBadge } from "@/components/status-badge"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Switch } from "@/components/ui/switch"
import type { Service, ServiceAction, ServiceUpdate, Updates } from "@/lib/api"

// Confirmation text per action. Only the ones that interrupt something ask;
// making every button ask trains people to click through the question.
const CONFIRM: Partial<Record<ServiceAction, (label: string) => string>> = {
  stop: (l) => `Stop ${l}? It stays stopped until you start it again.`,
  repair: (l) => `Regenerate config and recreate ${l}? No data is lost.`,
  update: (l) => `Pull the latest image for ${l} and restart it?`,
}

// Start and Stop are not two actions, they are one piece of state, and a pair
// of buttons asks the reader to work out which one is currently true. The
// switch says it. What is left here are things that genuinely are verbs.
//
// The switch drives enable and disable rather than docker start and stop,
// which is the same pair it always drove: enable writes the restart policy and
// state.json, so the box comes back the way the operator left it. A bare
// docker stop looks identical and is undone by the next reboot (gotcha #30).
const ACTIONS: { action: ServiceAction; label: string; icon: typeof PlayIcon }[] = [
  { action: "restart", label: "Restart", icon: RotateCcwIcon },
  { action: "repair", label: "Repair", icon: WrenchIcon },
]

// How each service is filed. SLEEPING is Sablier cold mode: the container is
// stopped on purpose and wakes on the next request, so filing it under
// "stopped" would report a working service as a problem, which is the same
// mistake the monitoring module made for months.
type Group = "running" | "sleeping" | "stopped" | "disabled"

function groupOf(svc: Service): Group {
  if (!svc.enabled) return "disabled"
  if (svc.status === "SLEEPING") return "sleeping"
  if (svc.status === "HEALTHY") return "running"
  return "stopped"
}

const GROUPS: { key: Group; title: string; note: string }[] = [
  { key: "running", title: "Running", note: "" },
  { key: "sleeping", title: "Sleeping", note: "Stopped on purpose, started again by the next request." },
  { key: "stopped", title: "Needs attention", note: "Switched on, but not answering." },
  { key: "disabled", title: "Switched off", note: "Stays off across reboots until switched back on." },
]

const TABS: { key: Group | "all"; title: string }[] = [
  { key: "all", title: "All" },
  ...GROUPS.map(({ key, title }) => ({ key: key as Group | "all", title })),
]

/**
 * Whether to offer Update, and how the card describes the answer.
 *
 * Offering it on every card whether or not anything had changed is what made
 * this page read as a control panel rather than as something that tells you
 * the state of the box. It is hidden only when the check is confident nothing
 * has moved: an unreachable registry leaves the button exactly where it was,
 * because taking a working button away over a network blip is worse than an
 * extra button.
 */
function updateHint(u: ServiceUpdate | undefined): {
  offer: boolean
  badge?: { text: string; tone: "warn" | "secondary" }
  note?: string
} {
  if (!u) return { offer: true }
  switch (u.state) {
    case "update":
      return { offer: true, badge: { text: "Update available", tone: "warn" }, note: u.note }
    case "stale-tag":
      return { offer: true, badge: { text: "Tag has stopped moving", tone: "warn" }, note: u.note }
    case "current":
    case "pinned":
      return { offer: false, note: u.note }
    default:
      return { offer: true, note: u.note }
  }
}

export function ServicesTab({
  services,
  updates,
  loading,
  busy,
  locked,
  onAction,
  onLogs,
}: {
  services: Service[]
  updates: Updates | null
  loading: boolean
  busy: string | null
  locked: boolean
  onAction: (svc: Service, action: ServiceAction) => void
  onLogs: (svc: Service) => void
}) {
  // Above the early returns below, and it has to stay there. This component
  // returns early while loading and while the list is empty, so a hook placed
  // after those is skipped on the first render and called on the next one,
  // which is the "rendered more hooks than during the previous render" crash.
  const [group, setGroup] = React.useState<Group | "all">("all")

  const counts = React.useMemo(() => {
    const c: Record<Group, number> = { running: 0, sleeping: 0, stopped: 0, disabled: 0 }
    for (const svc of services) c[groupOf(svc)] += 1
    return c
  }, [services])

  // A selected group that empties out would otherwise leave the reader on a
  // blank page with no obvious way back, and the common case is exactly that:
  // you open "Needs attention", the thing repairs itself, and the group is
  // gone. Fall back to All rather than to nothing.
  React.useEffect(() => {
    if (group !== "all" && !counts[group]) setGroup("all")
  }, [group, counts])

  if (loading && !services.length) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-40" />
        ))}
      </div>
    )
  }

  if (!services.length) {
    return (
      <Card>
        <CardContent className="text-muted-foreground py-12 text-center text-sm">
          <p className="text-foreground mb-1 text-base">No services installed</p>
          <p>
            Install one with <code className="text-foreground">corex manage add &lt;service&gt;</code>
          </p>
        </CardContent>
      </Card>
    )
  }

  const waiting = services.filter(
    (s) => updates?.services?.[s.name]?.state === "update"
  ).length

  const shown = group === "all" ? services : services.filter((s) => groupOf(s) === group)
  const note = group === "all" ? "" : (GROUPS.find((g) => g.key === group)?.note ?? "")

  return (
    <div className="flex flex-col gap-3">
      {updates && (
        <p className="text-muted-foreground text-xs">
          {updates.checking
            ? "Asking the registries what has moved."
            : !updates.checked_at
              ? "No update check has run yet, so every card offers Update."
              : waiting === 0
                ? `Checked ${ago(updates.checked_at)}. Nothing has a new image, so Update is only offered where the check could not tell.`
                : `Checked ${ago(updates.checked_at)}. ${waiting} ${waiting === 1 ? "service has" : "services have"} a new image.`}
        </p>
      )}
      {/* One group at a time, chosen rather than scrolled past.
          Stacked sections meant the group you cared about could be three
          screens down, and on a phone that is most of them. Tabs on a wide
          screen because they are all visible at once and cost one click; a
          native select below that, because four tab targets side by side at
          360px are either too small to hit or wrap into two rows that push
          the cards off the fold. The select is also what a phone already
          knows how to render full-screen. */}
      <div className="flex flex-col gap-3">
        <div className="hidden flex-wrap gap-1 sm:flex" role="tablist" aria-label="Filter services">
          {TABS.map(({ key, title }) => {
            const n = key === "all" ? services.length : counts[key]
            if (key !== "all" && !n) return null
            const on = group === key
            return (
              <button
                key={key}
                role="tab"
                aria-selected={on}
                onClick={() => setGroup(key)}
                className={
                  "rounded-md px-2.5 py-1 text-sm transition-colors " +
                  (on
                    ? "bg-secondary text-secondary-foreground font-medium"
                    : "text-muted-foreground hover:text-foreground")
                }
              >
                {title}
                <span className="ml-1.5 tabular-nums opacity-60">{n}</span>
              </button>
            )
          })}
        </div>

        <select
          className="border-input bg-background w-full rounded-md border px-2 py-1.5 text-sm sm:hidden"
          value={group}
          aria-label="Filter services"
          onChange={(e) => setGroup(e.target.value as Group | "all")}
        >
          {TABS.map(({ key, title }) => {
            const n = key === "all" ? services.length : counts[key]
            if (key !== "all" && !n) return null
            return (
              <option key={key} value={key}>
                {title} ({n})
              </option>
            )
          })}
        </select>

        {note && <p className="text-muted-foreground text-xs">{note}</p>}

        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {shown.map((svc) => (
            <ServiceCard
              key={svc.name}
              svc={svc}
              update={updates?.services?.[svc.name]}
              busy={busy === svc.name}
              disabled={!!busy || locked}
              onAction={onAction}
              onLogs={onLogs}
            />
          ))}
        </div>

        {!shown.length && (
          <p className="text-muted-foreground text-sm">Nothing in this group.</p>
        )}
      </div>
    </div>
  )
}

/** A unix second as "how long ago", which is what the header wants. */
function ago(unix: number): string {
  const s = Math.max(0, Date.now() / 1000 - unix)
  if (s < 3600) return `${Math.floor(s / 60)} minutes ago`
  if (s < 86400) return `${Math.floor(s / 3600)} hours ago`
  return `${Math.floor(s / 86400)} days ago`
}

function ServiceCard({
  svc,
  update,
  busy,
  disabled,
  onAction,
  onLogs,
}: {
  svc: Service
  update: ServiceUpdate | undefined
  busy: boolean
  disabled: boolean
  onAction: (svc: Service, action: ServiceAction) => void
  onLogs: (svc: Service) => void
}) {
  const click = (action: ServiceAction) => {
    const ask = CONFIRM[action]
    if (ask && !window.confirm(ask(svc.label))) return
    onAction(svc, action)
  }
  const hint = updateHint(update)

  return (
    <Card className="gap-3">
      <CardHeader>
        {/* min-w-0 on the title itself, not only on the span inside it.
            CardHeader is a grid, so CardTitle is a grid item and defaults to
            min-width:auto, which refuses to shrink below its content. The
            longest label, "Monitoring, Uptime Kuma + Grafana + Prometheus",
            therefore pushed the status badge out past the edge of the card
            and it was rendered clipped. */}
        <CardTitle className="flex min-w-0 items-start justify-between gap-2 text-sm">
          <span className="min-w-0 flex-1 truncate" title={svc.label}>
            {svc.label}
          </span>
          <span className="flex shrink-0 items-center gap-1.5">
            {hint.badge && !busy && <Badge variant={hint.badge.tone}>{hint.badge.text}</Badge>}
            {busy ? (
              <Loader2Icon className="text-muted-foreground size-4 animate-spin" />
            ) : (
              <StatusBadge status={svc.status} />
            )}
            <Switch
              checked={svc.enabled}
              busy={busy}
              disabled={disabled}
              label={`${svc.enabled ? "Switch off" : "Switch on"} ${svc.label}`}
              onCheckedChange={(next) => click(next ? "start" : "stop")}
            />
          </span>
        </CardTitle>
        <div className="flex min-w-0 flex-col gap-0.5">
          {svc.urls?.length ? (
            svc.urls.map((u) => (
              <a
                key={u}
                href={u}
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted-foreground hover:text-foreground inline-flex min-w-0 items-center gap-1 font-mono text-xs hover:underline"
              >
                <ExternalLinkIcon className="size-3 shrink-0" />
                <span className="truncate">{u}</span>
              </a>
            ))
          ) : (
            <span className="text-muted-foreground font-mono text-xs">not reachable over the web</span>
          )}
        </div>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        {hint.note && <p className="text-muted-foreground text-xs break-words">{hint.note}</p>}
        <div className="flex flex-wrap gap-1.5">
          {ACTIONS.map(({ action, label, icon: Icon }) => (
            <Button
              key={action}
              size="xs"
              variant={action === "stop" ? "outline" : "secondary"}
              disabled={disabled}
              onClick={() => click(action)}
            >
              <Icon />
              {label}
            </Button>
          ))}
          {hint.offer && (
            <Button
              size="xs"
              variant={hint.badge ? "default" : "secondary"}
              disabled={disabled}
              onClick={() => click("update")}
            >
              <RefreshCwIcon />
              Update
            </Button>
          )}
          {svc.container && (
            <Button size="xs" variant="ghost" disabled={disabled} onClick={() => onLogs(svc)}>
              <ScrollTextIcon />
              Logs
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  )
}
