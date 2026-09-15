import * as React from "react"

import { cn } from "@/lib/utils"

/**
 * A two-state control, written rather than pulled in.
 *
 * Radix is not a dependency of this app and adding one for a control this
 * small would put a package between the operator and a button that stops
 * their file server. It is a checkbox underneath, so it is focusable, it
 * toggles on space, and a screen reader already knows what it is.
 *
 * `busy` matters more here than it looks. The action behind this switch takes
 * several seconds (it rewrites a compose file and recreates containers), and
 * without a visibly pending state the natural reading of "nothing happened
 * yet" is that the click was missed, so it gets clicked again.
 */
function Switch({
  checked,
  onCheckedChange,
  disabled,
  busy,
  label,
  className,
}: {
  checked: boolean
  onCheckedChange: (next: boolean) => void
  disabled?: boolean
  busy?: boolean
  label: string
  className?: string
}) {
  return (
    <label
      className={cn(
        "inline-flex cursor-pointer items-center gap-2",
        (disabled || busy) && "cursor-not-allowed opacity-60",
        className,
      )}
    >
      <input
        type="checkbox"
        role="switch"
        className="peer sr-only"
        checked={checked}
        disabled={disabled || busy}
        aria-label={label}
        onChange={(e) => onCheckedChange(e.target.checked)}
      />
      <span
        aria-hidden
        className={cn(
          "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors",
          "peer-focus-visible:ring-ring peer-focus-visible:ring-2 peer-focus-visible:ring-offset-2",
          checked ? "bg-primary" : "bg-input",
        )}
      >
        <span
          className={cn(
            "bg-background pointer-events-none inline-block size-4 rounded-full shadow transition-transform",
            checked ? "translate-x-[1.125rem]" : "translate-x-0.5",
          )}
        />
      </span>
    </label>
  )
}

export { Switch }
