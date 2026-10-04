import * as React from "react"

import { cn } from "@/lib/utils"

/**
 * One way to show a choice between a few options.
 *
 * There were three. The catalogue filter and the log level filter rendered the
 * chosen option with the button's `default` variant, which is `--primary`, so
 * on the dark theme a chosen filter was a near-white slab, brighter and larger
 * than any reading on the page. The services groups used a grey fill. The
 * overview range used a third thing. None of them agreed, and the loudest of
 * them was attached to the least important decision on the screen.
 *
 * Selection is not an action. It never borrows the accent: a chosen filter
 * that renders as the one accent on the page reads as the thing to press next,
 * which is exactly backwards. It is a quiet raised surface inside a recessed
 * track, which is the oldest and most legible way to say "this one of these".
 *
 * The count beside a label is the reason this is not a row of plain tabs: on a
 * status panel the useful part of a filter is usually how many are in it.
 */
export type SegmentedOption<T extends string> = {
  value: T
  label: string
  /** Shown after the label, dimmed. Omit rather than passing zero. */
  count?: number
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
  label,
  size = "default",
  className,
}: {
  options: SegmentedOption<T>[]
  value: T
  onChange: (next: T) => void
  /** Names the group for a screen reader. Required: a bare row of buttons is unlabelled. */
  label: string
  size?: "default" | "sm"
  className?: string
}) {
  return (
    <div
      role="tablist"
      aria-label={label}
      className={cn(
        "bg-muted/70 inline-flex w-fit max-w-full items-center gap-0.5 overflow-x-auto rounded-lg p-0.5",
        className
      )}
    >
      {options.map((o) => {
        const on = o.value === value
        return (
          <button
            key={o.value}
            type="button"
            role="tab"
            aria-selected={on}
            onClick={() => onChange(o.value)}
            className={cn(
              "focus-visible:ring-ring inline-flex shrink-0 items-center gap-1.5 rounded-md font-medium whitespace-nowrap transition-colors duration-(--dur-fast) ease-(--ease) focus-visible:ring-2 focus-visible:outline-none",
              size === "sm" ? "h-6 px-2 text-small" : "h-7 px-2.5 text-body",
              on
                ? "bg-selected text-selected-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground"
            )}
          >
            {o.label}
            {o.count !== undefined && (
              <span className={cn("num font-mono text-micro", on ? "opacity-60" : "opacity-50")}>
                {o.count}
              </span>
            )}
          </button>
        )
      })}
    </div>
  )
}
