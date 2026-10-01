import * as React from "react"

import { cn } from "@/lib/utils"

/**
 * The screen-level patterns.
 *
 * This dashboard was 38 Card wrappers across ten screens: every screen a grid
 * of identical rounded boxes, the same radius and the same border whether the
 * content was a list of facts or a thing you act on. Uniform cards are the
 * default a generator reaches for, and they carry no information: a reader
 * learns nothing from the chrome, so hierarchy has to be rebuilt by reading
 * every title.
 *
 * So structure encodes the difference instead.
 *
 *   Section  a heading and its content. No chrome at all. This is the default.
 *   Rows     hairline separated facts. The natural form for anything
 *            enumerable: ports, host details, checks, disks.
 *   Card     kept for an object with its own actions, where the box really is
 *            around one thing: a service, an update, a passkey.
 *
 * Headings are sentence case. An all-caps tracked label above a block is
 * decoration pretending to be structure, and there were five of them.
 */

export function Section({
  title,
  action,
  children,
  className,
}: {
  title?: React.ReactNode
  /** Controls for this section, placed on the heading line rather than inside the content. */
  action?: React.ReactNode
  children: React.ReactNode
  className?: string
}) {
  return (
    <section className={cn("flex min-w-0 flex-col gap-2", className)}>
      {(title || action) && (
        <div className="flex min-w-0 items-center justify-between gap-3">
          {title && (
            <h2 className="text-title min-w-0 truncate font-medium tracking-tight">{title}</h2>
          )}
          {action && <div className="flex shrink-0 items-center gap-2">{action}</div>}
        </div>
      )}
      {children}
    </section>
  )
}

/**
 * A list of facts. The divider is the structure, so there is no box.
 *
 * `bordered` puts a hairline frame around the whole list, for a block that
 * needs to read as one object against a busy page. Most do not.
 */
export function Rows({
  children,
  bordered = false,
  className,
}: {
  children: React.ReactNode
  bordered?: boolean
  className?: string
}) {
  return (
    <div
      className={cn(
        "divide-border flex min-w-0 flex-col divide-y",
        bordered && "border-border rounded-lg border px-3",
        className
      )}
    >
      {children}
    </div>
  )
}

/**
 * One fact. The value is mono because it comes from the machine, and tabular
 * because a column of figures that jitters as it updates is unreadable.
 */
export function Row({
  label,
  value,
  hint,
  tone,
  className,
}: {
  label: React.ReactNode
  value?: React.ReactNode
  /** A second line, for the sentence that explains the value. */
  hint?: React.ReactNode
  tone?: "ok" | "warn" | "danger"
  className?: string
}) {
  const colour =
    tone === "ok"
      ? "text-ok"
      : tone === "warn"
        ? "text-warn"
        : tone === "danger"
          ? "text-destructive"
          : undefined
  return (
    <div className={cn("flex min-w-0 flex-col gap-0.5 py-2", className)}>
      <div className="flex min-w-0 items-baseline justify-between gap-3">
        <span className="text-muted-foreground min-w-0 truncate">{label}</span>
        {value !== undefined && (
          <span className={cn("num shrink-0 truncate font-mono text-small", colour)}>{value}</span>
        )}
      </div>
      {hint && <p className="text-muted-foreground text-small">{hint}</p>}
    </div>
  )
}

/**
 * Nothing here, and what to do about it.
 *
 * An empty screen is an invitation to act, so it names the action. A bare
 * "No data" tells the reader what the program knows rather than what they
 * can do, which on a control surface is the wrong half of the sentence.
 */
export function Empty({
  children,
  action,
  className,
}: {
  children: React.ReactNode
  action?: React.ReactNode
  className?: string
}) {
  return (
    <div
      className={cn(
        "border-border flex flex-col items-start gap-2 rounded-lg border border-dashed px-3 py-4",
        className
      )}
    >
      <p className="text-muted-foreground">{children}</p>
      {action}
    </div>
  )
}
