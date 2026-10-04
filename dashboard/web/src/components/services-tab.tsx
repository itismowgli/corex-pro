import * as React from "react"
import {
  ChevronRightIcon,
  ExternalLinkIcon,
  Loader2Icon,
  PlayIcon,
  RefreshCwIcon,
  RotateCcwIcon,
  ScrollTextIcon,
  WrenchIcon,
} from "lucide-react"

import { StatusBadge } from "@/components/status-badge"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, Rows } from "@/components/ui/section"
import { Skeleton } from "@/components/ui/skeleton"
import { Switch } from "@/components/ui/switch"
import { cn } from "@/lib/utils"
import type { Service, ServiceAction, ServiceStatus, ServiceUpdate, Updates } from "@/lib/api"

/**
 * Every service on the box, as a list rather than a wall of boxes.
 *
 * This was twenty cards in a three column grid, each carrying four buttons and
 * a switch whether or not there was anything to do, so the page resting state
 * was roughly a hundred controls. A grid of identical boxes also forces every
 * service to occupy the same area, which means the one that is broken looks
 * exactly like the nineteen that are fine, and the reader has to find it by
 * reading rather than by looking.
 *
 * So the list is the resting state and the actions are one disclosure in. A
 * row carries what answers "is this alright": a status mark, the name, the tag
 * it is running, where it answers, and whether an update is waiting. Opening a
 * row brings its actions, and only one is open at a time, so the page cannot
 * grow back into the thing it was.
 *
 * Nothing was taken away. Restart, Repair, Update and Logs are all still one
 * click from the row, and the switch stays on the row because it is state and
 * not a verb: it reads as the answer to "is this on", which is a thing you
 * scan for, not a thing you go looking for.
 */

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
 * Whether to offer Update, and how the row describes the answer.
 *
 * Offering it on every service whether or not anything had changed is what
 * made this page read as a control panel rather than as something that tells
 * you the state of the box. It is hidden only when the check is confident
 * nothing has moved: an unreachable registry leaves the button exactly where
 * it was, because taking a working button away over a network blip is worse
 * than an extra button.
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

/**
 * The status, as a mark rather than a word.
 *
 * Twenty rows each labelled HEALTHY is twenty words that say the same thing,
 * and a column of identical text is what the eye learns to skip. A healthy
 * service gets a dot; anything else keeps the full badge, because the whole
 * point of the dot is that the exceptions stand out against it. Colour is
 * never the only carrier: the dot has a title and a screen reader gets the
 * word.
 */
function StatusMark({ status, busy }: { status: ServiceStatus; busy: boolean }) {
  if (busy) {
    return <Loader2Icon className="text-muted-foreground size-3.5 shrink-0 animate-spin" />
  }
  if (status !== "HEALTHY") return <StatusBadge status={status} />
  return (
    <span className="inline-flex shrink-0 items-center" title="HEALTHY">
      <span className="bg-ok size-2 rounded-full" aria-hidden />
      <span className="sr-only">HEALTHY</span>
    </span>
  )
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
  // Above the early returns below, and they have to stay there. This component
  // returns early while loading and while the list is empty, so a hook placed
  // after those is skipped on the first render and called on the next one,
  // which is the "rendered more hooks than during the previous render" crash.
  const [group, setGroup] = React.useState<Group | "all">("all")
  const [open, setOpen] = React.useState<string | null>(null)

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
      <Rows>
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} className="py-2">
            <Skeleton className="h-6" />
          </div>
        ))}
      </Rows>
    )
  }

  if (!services.length) {
    return (
      <Empty>
        Nothing is installed yet. Add one with{" "}
        <code className="text-foreground">corex manage add &lt;service&gt;</code>, or pick one from
        the catalogue.
      </Empty>
    )
  }

  const waiting = services.filter((s) => updates?.services?.[s.name]?.state === "update").length

  const shown = group === "all" ? services : services.filter((s) => groupOf(s) === group)
  const note = group === "all" ? "" : (GROUPS.find((g) => g.key === group)?.note ?? "")

  return (
    <div className="flex flex-col gap-3">
      {updates && (
        <p className="text-muted-foreground text-small">
          {updates.checking
            ? "Asking the registries what has moved."
            : !updates.checked_at
              ? "No update check has run yet, so every service offers Update."
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
          the list off the fold. The select is also what a phone already
          knows how to render full-screen. */}
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
                "rounded-md px-2.5 py-1 text-body transition-colors duration-(--dur-fast) ease-(--ease) " +
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
        className="border-input bg-background w-full rounded-md border px-2 py-1.5 text-body sm:hidden"
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

      {note && <p className="text-muted-foreground text-small">{note}</p>}

      {shown.length ? (
        <Rows>
          {shown.map((svc) => (
            <ServiceRow
              key={svc.name}
              svc={svc}
              update={updates?.services?.[svc.name]}
              busy={busy === svc.name}
              disabled={!!busy || locked}
              open={open === svc.name}
              onToggle={() => setOpen((cur) => (cur === svc.name ? null : svc.name))}
              onAction={onAction}
              onLogs={onLogs}
            />
          ))}
        </Rows>
      ) : (
        <Empty>Nothing in this group.</Empty>
      )}
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

function ServiceRow({
  svc,
  update,
  busy,
  disabled,
  open,
  onToggle,
  onAction,
  onLogs,
}: {
  svc: Service
  update: ServiceUpdate | undefined
  busy: boolean
  disabled: boolean
  open: boolean
  onToggle: () => void
  onAction: (svc: Service, action: ServiceAction) => void
  onLogs: (svc: Service) => void
}) {
  const click = (action: ServiceAction) => {
    const ask = CONFIRM[action]
    if (ask && !window.confirm(ask(svc.label))) return
    onAction(svc, action)
  }
  const hint = updateHint(update)
  const urls = svc.urls ?? []

  return (
    <div className="flex min-w-0 flex-col">
      <div className="flex min-w-0 items-center gap-2 py-1">
        {/* The disclosure is its own button rather than the whole row, because
            the row also holds a link and a switch, and an interactive element
            inside a button is invalid and unreachable by keyboard. */}
        <button
          type="button"
          aria-expanded={open}
          onClick={onToggle}
          className="hover:text-foreground focus-visible:ring-ring flex min-w-0 flex-1 items-center gap-2 rounded-md py-1.5 text-left transition-colors duration-(--dur-fast) ease-(--ease) focus-visible:ring-2 focus-visible:outline-none"
        >
          <ChevronRightIcon
            aria-hidden
            className={cn(
              "text-muted-foreground size-3.5 shrink-0 transition-transform duration-(--dur-fast) ease-(--ease)",
              open && "rotate-90"
            )}
          />
          <StatusMark status={svc.status} busy={busy} />
          <span className="min-w-0 truncate font-medium" title={svc.label}>
            {svc.label}
          </span>
          {/* The image tag, which is the only version this box can state as
              fact. "latest" is shown as itself rather than resolved: a moving
              tag is exactly the case where the name and the thing it points at
              are different questions (gotcha #26). */}
          {svc.version && (
            <span
              className="text-muted-foreground num shrink-0 font-mono text-micro"
              title={
                svc.version === "latest"
                  ? "Image tag. A moving tag, so what it points at can change without this changing."
                  : "Image tag the container was created from"
              }
            >
              {svc.version}
            </span>
          )}
        </button>

        {/* The address on a wide screen only. On a phone it would take the
            whole row from the name, and it is one disclosure away below. */}
        {urls[0] && (
          <a
            href={urls[0]}
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted-foreground hover:text-foreground hidden min-w-0 max-w-64 items-center gap-1 truncate font-mono text-small hover:underline lg:inline-flex"
          >
            <span className="truncate">{urls[0].replace(/^https?:\/\//, "")}</span>
            <ExternalLinkIcon className="size-3 shrink-0" aria-hidden />
          </a>
        )}

        {hint.badge && !busy && (
          <Badge variant={hint.badge.tone} className="shrink-0">
            {hint.badge.text}
          </Badge>
        )}

        <Switch
          checked={svc.enabled}
          busy={busy}
          disabled={disabled}
          label={`${svc.enabled ? "Switch off" : "Switch on"} ${svc.label}`}
          onCheckedChange={(next) => click(next ? "start" : "stop")}
        />
      </div>

      {open && (
        <div className="flex flex-col gap-2 pb-3 pl-6">
          {urls.length ? (
            <div className="flex min-w-0 flex-col">
              {urls.map((u) => (
                <a
                  key={u}
                  href={u}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-muted-foreground hover:text-foreground inline-flex min-w-0 items-center gap-1 font-mono text-small hover:underline"
                >
                  <ExternalLinkIcon className="size-3 shrink-0" aria-hidden />
                  <span className="truncate">{u}</span>
                </a>
              ))}
            </div>
          ) : (
            <p className="text-muted-foreground text-small">Not reachable over the web.</p>
          )}

          {hint.note && <p className="text-muted-foreground text-small break-words">{hint.note}</p>}

          {/* Restart, Repair and Update all start the thing they act on, so on
              a service that is deliberately off they would quietly undo the
              decision that switched it off. The switch is the way back. */}
          {svc.enabled ? (
            <div className="flex flex-wrap gap-1.5">
              {ACTIONS.map(({ action, label, icon: Icon }) => (
                <Button
                  key={action}
                  size="xs"
                  variant="secondary"
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
          ) : (
            <p className="text-muted-foreground text-small">
              Switched off, so there is nothing to restart, repair or update. Switch it on first.
            </p>
          )}
        </div>
      )}
    </div>
  )
}
