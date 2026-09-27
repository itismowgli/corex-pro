import { ArrowUpCircleIcon, Loader2Icon, PackageIcon, RefreshCwIcon, TagIcon } from "lucide-react"

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
  const unknown = services.filter((s) => {
    const st = updates?.services?.[s.name]?.state
    return (
      st !== "update" &&
      st !== "stale-tag" &&
      st !== "newer-release" &&
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
          <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
            <PackageIcon className="size-4 shrink-0" />
            Ubuntu
            {os && os.total > 0 && <Badge variant="warn">{os.total} package{os.total === 1 ? "" : "s"}</Badge>}
            {os?.reboot_required && <Badge variant="warn">Reboot needed</Badge>}
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {!os ? (
            <p className="text-muted-foreground text-sm">Checking...</p>
          ) : os.total === 0 ? (
            <p className="text-muted-foreground text-sm">Everything is current.</p>
          ) : (
            <div className="flex flex-col gap-1.5 text-sm">
              <p>
                {os.total} package{os.total === 1 ? "" : "s"} can be upgraded
                {os.security > 0 && `, ${os.security} of them security`}.
              </p>
              {os.held > 0 && (
                <p className="text-muted-foreground text-xs">
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
            <span className="text-muted-foreground text-xs">
              Refuses to start above 85C, on a half-finished package transaction, or
              in the first fifteen minutes after boot.
            </span>
          </div>
        </CardContent>
      </Card>

      {/* Services */}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-col">
          <h3 className="text-sm font-medium">
            Services
            {waiting.length > 0 && (
              <span className="text-muted-foreground ml-1.5 font-normal">{waiting.length}</span>
            )}
          </h3>
          <p className="text-muted-foreground text-xs">
            {updates?.checking
              ? "Checking the registries..."
              : !updates?.checked_at
                ? "No check has run yet."
                : `Checked ${ago(updates.checked_at)}.`}
          </p>
        </div>
        {waiting.length > 1 && (
          <Button size="sm" disabled={disabled} onClick={onUpdateAll}>
            <RefreshCwIcon />
            Update all {waiting.length}
          </Button>
        )}
      </div>

      {waiting.length === 0 ? (
        <p className="text-muted-foreground text-sm">
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
          <h3 className="text-sm font-medium">
            A newer release exists
            <span className="text-muted-foreground ml-1.5 font-normal">{behind.length}</span>
          </h3>
          <p className="text-muted-foreground text-xs">
            These are pinned to an exact version and are current for it, so pulling
            changes nothing. The version is set by the CoreX service module, so the
            way to move is to update CoreX itself with{" "}
            <code className="font-mono">corex update</code> and then repair the
            service.
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

      {/* An unreachable registry is not "up to date", and flattening it into
          one would be the same mistake as a check that cannot fail. */}
      {unknown.length > 0 && (
        <div className="flex flex-col gap-2">
          <h3 className="text-sm font-medium">
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
  // The version upstream published, carried per image because a stack can
  // have several and only some of them pinned.
  const newer = update?.images?.find((i) => i.newer)?.newer
  const behind = update?.state === "newer-release"
  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="flex min-w-0 items-start justify-between gap-2 text-sm">
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
        {svc.version && (
          <span className="text-muted-foreground inline-flex min-w-0 items-center gap-1 font-mono text-xs">
            <TagIcon className="size-3 shrink-0" />
            <span className="truncate" title="Image tag currently running">
              {svc.version}
            </span>
          </span>
        )}
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        {update?.note && !prog && (
          <p className="text-muted-foreground text-xs break-words">{update.note}</p>
        )}
        {prog && (
          <div className="flex flex-col gap-1">
            <div className="text-muted-foreground flex items-baseline justify-between gap-2 text-xs">
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
          {behind ? (
            // No Update button here on purpose. This image is pinned, so a
            // pull fetches the same thing it already has, and a button that
            // reports success while changing nothing is the fault in gotcha
            // #50. The version lives in the module, so CoreX has to move it.
            <p className="text-muted-foreground text-xs">
              Pinned, so pulling changes nothing. Run{" "}
              <code className="font-mono">corex update</code>, then{" "}
              <code className="font-mono">corex manage repair {svc.name}</code>.
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
