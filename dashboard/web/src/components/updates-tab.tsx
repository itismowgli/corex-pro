import {
  ArrowUpCircleIcon,
  Loader2Icon,
  PackageIcon,
  RefreshCwIcon,
  SearchIcon,
  TagIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Meter } from "@/components/ui/spark"
import type { Job, OsUpdates, Service, ServiceAction, ServiceUpdate, Updates } from "@/lib/api"
import { currentTarget, sliceFor, updateProgress } from "@/lib/progress"

/**
 * What has a new version, in one place.
 *
 * The information existed already, spread one badge at a time across the
 * service cards, which answers "is this one current" and never answers "what
 * needs my attention today". That second question is the one people actually
 * open a dashboard with, so it gets a page.
 *
 * Deliberately not a count of everything that could be pressed. A service
 * whose registry could not be reached is not an update, and saying so is the
 * difference between a number you trust and a badge you learn to ignore.
 */

/** Only a confident "there is a newer image" counts toward the badge. */
export function updateCount(services: Service[], updates: Updates | null): number {
  if (!updates) return 0
  return services.filter((s) => {
    const st = updates.services?.[s.name]?.state
    return st === "update" || st === "stale-tag" || st === "newer-release"
  }).length
}

function ago(unix: number): string {
  const s = Math.max(0, Date.now() / 1000 - unix)
  if (s < 3600) return `${Math.floor(s / 60)} minutes ago`
  if (s < 86400) return `${Math.floor(s / 3600)} hours ago`
  return `${Math.floor(s / 86400)} days ago`
}

export function UpdatesTab({
  services,
  updates,
  os,
  busy,
  job,
  locked,
  onAction,
  onUpdateAll,
  onCheck,
  onOsUpgrade,
}: {
  services: Service[]
  updates: Updates | null
  os: OsUpdates | null
  busy: string | null
  job: Job | null
  locked: boolean
  onAction: (svc: Service, action: ServiceAction) => void
  onUpdateAll: () => void
  onCheck: () => void
  onOsUpgrade: () => void
}) {
  /**
   * Which card the running job belongs to.
   *
   * A single update sets busy to that service. "Update all" is one job
   * covering every service in turn, so the service is read from the output
   * instead, which is the only thing that knows where the run has got to.
   */
  const running = job?.state === "running" ? job : null
  const named = busy && services.some((s) => s.name === busy) ? busy : null
  const activeName = named ?? (running ? currentTarget(running.output) : null)

  const waiting = services.filter((s) => {
    const st = updates?.services?.[s.name]?.state
    return st === "update" || st === "stale-tag"
  })
  // Its own group. A pull will not deliver these, so they must not sit beside
  // cards whose Update button works, which is gotcha #50's rule: a control
  // that offers something has to be the control that delivers it.
  const behind = services.filter(
    (s) => updates?.services?.[s.name]?.state === "newer-release",
  )
  // A decision already taken, so it is not news and offers nothing to press.
  const held = services.filter((s) => updates?.services?.[s.name]?.state === "held")
  const unknown = services.filter((s) => {
    const st = updates?.services?.[s.name]?.state
    return (
      st !== "update" &&
      st !== "stale-tag" &&
      st !== "newer-release" &&
      st !== "held" &&
      st !== "current" &&
      st !== "pinned"
    )
  })
  const disabled = !!busy || locked

  return (
    <div className="flex flex-col gap-4">
      {/* The machine first. A kernel behind is worth more of the reader's
          attention than a container behind, and it is also the one that
          cannot be undone by pulling a different image. */}
      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2 text-body">
            <PackageIcon className="size-4 shrink-0" />
            Ubuntu
            {os && os.total > 0 && <Badge variant="warn">{os.total} package{os.total === 1 ? "" : "s"}</Badge>}
            {os?.reboot_required && <Badge variant="warn">Reboot needed</Badge>}
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {!os ? (
            <p className="text-muted-foreground text-body">Checking...</p>
          ) : os.total === 0 ? (
            <p className="text-muted-foreground text-body">Everything is current.</p>
          ) : (
            <div className="flex flex-col gap-1.5 text-body">
              <p>
                {os.total} package{os.total === 1 ? "" : "s"} can be upgraded
                {os.security > 0 && `, ${os.security} of them security`}.
              </p>
              {os.held > 0 && (
                <p className="text-muted-foreground text-small">
                  {os.held} {os.held === 1 ? "is" : "are"} held back from automatic
                  upgrades on purpose. The kernel, libc and systemd are only upgraded
                  here, supervised, because an upgrade interrupted part way can leave
                  the machine unable to boot.
                </p>
              )}
            </div>
          )}
          <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" disabled={disabled || !os || os.total === 0} onClick={onOsUpgrade}>
              <ArrowUpCircleIcon />
              Upgrade Ubuntu
            </Button>
            <span className="text-muted-foreground text-small">
              Refuses to start above 85C, on a half-finished package transaction, or
              in the first fifteen minutes after boot.
            </span>
          </div>
        </CardContent>
      </Card>

      {/* Services */}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-col">
          <h3 className="text-body font-medium">
            Services
            {waiting.length > 0 && (
              <span className="text-muted-foreground ml-1.5 font-normal">{waiting.length}</span>
            )}
          </h3>
          {/* The page draws from a cache, which is why it is instant. That
              makes how old the answer is part of the answer, so it is stated
              plainly rather than left for the reader to wonder about. */}
          <p className="text-muted-foreground text-small">
            {updates?.checking
              ? "Checking the registries now..."
              : !updates?.checked_at
                ? "Not checked yet."
                : `Last checked ${ago(updates.checked_at)}.`}
          </p>
        </div>
        {/* Two controls, and the distinction is the one every OS makes:
            looking is safe and changes nothing, applying is the commitment.
            Conflating them is why the old single button felt risky to press. */}
        <div className="flex shrink-0 items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={!!updates?.checking}
            onClick={onCheck}
          >
            {updates?.checking ? <Loader2Icon className="animate-spin" /> : <SearchIcon />}
            Check now
          </Button>
          {/* Always offered, not only when more than one thing is waiting.
              It updates CoreX and then every service, so it is also how a
              version CoreX pins arrives: pressing it is never wrong, and
              hiding it whenever the count was 0 or 1 made the one control
              that fixes everything the hardest one to find. */}
          <Button size="sm" disabled={disabled} onClick={onUpdateAll}>
            <RefreshCwIcon />
            Update everything
          </Button>
        </div>
      </div>

      {waiting.length === 0 ? (
        <p className="text-muted-foreground text-body">
          Nothing has a newer image.
          {unknown.length > 0 &&
            ` ${unknown.length} could not be checked, so ${unknown.length === 1 ? "it is" : "they are"} listed below.`}
        </p>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {waiting.map((svc) => (
            <UpdateCard
              key={svc.name}
              svc={svc}
              update={updates?.services?.[svc.name]}
              busy={activeName === svc.name}
              output={running && activeName === svc.name ? sliceFor(running.output, svc.name) : ""}
              disabled={disabled}
              onAction={onAction}
            />
          ))}
        </div>
      )}

      {behind.length > 0 && (
        <div className="flex flex-col gap-2">
          <h3 className="text-body font-medium">
            A newer release exists
            <span className="text-muted-foreground ml-1.5 font-normal">{behind.length}</span>
          </h3>
          <p className="text-muted-foreground text-small">
            Pinned to an exact version by CoreX, and current for it. Update
            everything is what moves these, because it updates CoreX first.
          </p>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {behind.map((svc) => (
              <UpdateCard
                key={svc.name}
                svc={svc}
                update={updates?.services?.[svc.name]}
                busy={activeName === svc.name}
                output={running && activeName === svc.name ? sliceFor(running.output, svc.name) : ""}
                disabled={disabled}
                onAction={onAction}
              />
            ))}
          </div>
        </div>
      )}

      {/* Deliberately not offered. The module names the version it will not
          take and why, so this reads as a decision rather than as something
          the reader has to chase. Advertising these asked the operator to
          break a working service: keeper 2.21.7 crash-looped here, and the
          whiteboard v2.0.0 needs a Nextcloud app version that is not
          installed. */}
      {held.length > 0 && (
        <div className="flex flex-col gap-2">
          <h3 className="text-body font-medium">
            Held back on purpose
            <span className="text-muted-foreground ml-1.5 font-normal">{held.length}</span>
          </h3>
          <p className="text-muted-foreground text-small">
            Upstream is ahead and CoreX does not follow it here. Nothing to do.
          </p>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {held.map((svc) => (
              <UpdateCard
                key={svc.name}
                svc={svc}
                update={updates?.services?.[svc.name]}
                busy={activeName === svc.name}
                output=""
                disabled={disabled}
                onAction={onAction}
              />
            ))}
          </div>
        </div>
      )}

      {/* An unreachable registry is not "up to date", and flattening it into
          one would be the same mistake as a check that cannot fail. */}
      {unknown.length > 0 && (
        <div className="flex flex-col gap-2">
          <h3 className="text-body font-medium">
            Could not be checked
            <span className="text-muted-foreground ml-1.5 font-normal">{unknown.length}</span>
          </h3>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {unknown.map((svc) => (
              <UpdateCard
                key={svc.name}
                svc={svc}
                update={updates?.services?.[svc.name]}
                busy={activeName === svc.name}
                output={running && activeName === svc.name ? sliceFor(running.output, svc.name) : ""}
                disabled={disabled}
                onAction={onAction}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function UpdateCard({
  svc,
  update,
  busy,
  output,
  disabled,
  onAction,
}: {
  svc: Service
  update: ServiceUpdate | undefined
  busy: boolean
  output: string
  disabled: boolean
  onAction: (svc: Service, action: ServiceAction) => void
}) {
  // Read from the job's own output rather than timed or guessed, so the bar
  // cannot disagree with what the command is actually doing (gotcha #50).
  const prog = busy ? updateProgress(output) : null
  // The image the note is actually about, which in a stack is usually not
  // the service's main container. Monitoring showed the tag "latest" beside a
  // note about prom/prometheus, and Nextcloud showed "34" beside a note about
  // the whiteboard: three different things on one card.
  const row = update?.images?.find((i) => i.state === "newer-release" || i.state === "held")
  const newer = row?.newer
  const behind = update?.state === "newer-release"
  const isHeld = update?.state === "held"
  // "whiteboard:v1.5.9" rather than the whole registry path.
  const rowName = row ? row.image.split("/").pop() : null
  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="flex min-w-0 items-start justify-between gap-2 text-body">
          <span className="min-w-0 flex-1 truncate" title={svc.label}>
            {svc.label}
          </span>
          {busy ? (
            <Loader2Icon className="text-muted-foreground size-4 shrink-0 animate-spin" />
          ) : (
            <>
              {update?.state === "update" && <Badge variant="warn">New image</Badge>}
              {behind && newer && <Badge variant="warn">{newer}</Badge>}
            </>
          )}
        </CardTitle>
        {/* The version in hand. The registry can say a newer image exists but
            not what it will call itself, so this states where you are rather
            than inventing a "to" half it would have to guess at. */}
        {(rowName || svc.version) && (
          <span className="text-muted-foreground inline-flex min-w-0 items-center gap-1 font-mono text-small">
            <TagIcon className="size-3 shrink-0" />
            <span className="truncate" title={row ? row.image : "Image tag currently running"}>
              {rowName ?? svc.version}
              {newer && <span className="text-foreground"> {"->"} {newer}</span>}
            </span>
          </span>
        )}
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        {/* Not on a held card. The service note for a hold is already
            "<image> is held at this version. <reason>", and the body below
            prints the reason, so both together said the same thing twice with
            a redundant prefix: the version line above this has just named the
            image. */}
        {update?.note && !prog && !isHeld && (
          <p className="text-muted-foreground text-small break-words">{update.note}</p>
        )}
        {prog && (
          <div className="flex flex-col gap-1">
            <div className="text-muted-foreground flex items-baseline justify-between gap-2 text-small">
              <span className="truncate">{prog.detail}</span>
              {prog.pct !== null && <span className="shrink-0 font-mono">{prog.pct}%</span>}
            </div>
            {prog.pct !== null ? (
              <Meter
                value={prog.pct}
                max={100}
                tone={prog.phase === "failed" ? "danger" : "neutral"}
              />
            ) : (
              // Docker has not said how many layers there are yet, so a
              // determinate bar here would be a number with nothing behind it.
              <div className="bg-muted h-1.5 w-full overflow-hidden rounded-full">
                <div className="bg-muted-foreground/40 h-full w-1/3 animate-pulse rounded-full" />
              </div>
            )}
          </div>
        )}
        <div>
          {isHeld ? (
            // A decision already taken. Nothing to press, and the reason is
            // the only thing worth saying.
            <p className="text-muted-foreground text-small break-words">{row?.reason}</p>
          ) : behind ? (
            // No per-card button: this image is pinned, so a pull fetches
            // what it already has and would report success while changing
            // nothing (gotcha #50). Update everything is the control that
            // can move it, because it updates CoreX first.
            <p className="text-muted-foreground text-small">
              Pinned by CoreX. Update everything is what can move it.
            </p>
          ) : (
            <Button
              size="xs"
              variant={update?.state === "update" ? "default" : "secondary"}
              disabled={disabled}
              onClick={() => {
                if (!window.confirm(`Pull the latest image for ${svc.label} and restart it?`)) return
                onAction(svc, "update")
              }}
            >
              <RefreshCwIcon />
              Update
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  )
}
