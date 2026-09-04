import * as React from "react"
import * as DialogPrimitive from "@radix-ui/react-dialog"
import { SearchIcon, type LucideIcon } from "lucide-react"

import { cn } from "@/lib/utils"

/**
 * Cmd+K over everything the dashboard can do.
 *
 * There are nine sections and twenty-odd services now, which is more than
 * fits anywhere comfortably, so the answer to "where is the button for X" has
 * to be a search rather than a hunt. The list is assembled by the app, not by
 * this file, because the palette should never be a second place where an
 * action is defined and therefore a second place it can be wrong.
 *
 * Written out rather than pulled from a package for the reason in gotcha #35:
 * this page is what you open when the box is in trouble, so it fetches
 * nothing and every dependency it has is one more thing to keep current.
 */
export type PaletteItem = {
  id: string
  group: string
  label: string
  hint?: string
  icon?: LucideIcon
  /** Extra words to match on, for things people call by another name. */
  keywords?: string
  disabled?: boolean
  run: () => void
}

/** Opens on Cmd+K or Ctrl+K, from anywhere that is not a text field. */
export function usePaletteHotkey(open: (v: boolean) => void) {
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "k" && e.key !== "K") return
      if (!e.metaKey && !e.ctrlKey) return
      e.preventDefault()
      open(true)
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [open])
}

function matches(item: PaletteItem, query: string) {
  if (!query) return true
  const hay = `${item.group} ${item.label} ${item.hint ?? ""} ${item.keywords ?? ""}`.toLowerCase()
  // Every word has to appear somewhere, in any order, so "restart next" finds
  // "Restart Nextcloud" without the typist knowing the wording.
  return query
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .every((word) => hay.includes(word))
}

export function CommandPalette({
  open,
  onOpenChange,
  items,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  items: PaletteItem[]
}) {
  const [query, setQuery] = React.useState("")
  const [active, setActive] = React.useState(0)
  const listRef = React.useRef<HTMLDivElement>(null)

  const shown = React.useMemo(
    () => items.filter((i) => !i.disabled && matches(i, query)),
    [items, query]
  )

  // A stale index selects the wrong row, or nothing, after the list narrows.
  React.useEffect(() => setActive(0), [query, open])

  React.useEffect(() => {
    if (!open) setQuery("")
  }, [open])

  React.useEffect(() => {
    listRef.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: "nearest" })
  }, [active, shown.length])

  const choose = (item: PaletteItem | undefined) => {
    if (!item) return
    onOpenChange(false)
    item.run()
  }

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault()
      setActive((i) => (shown.length ? (i + 1) % shown.length : 0))
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      setActive((i) => (shown.length ? (i - 1 + shown.length) % shown.length : 0))
    } else if (e.key === "Enter") {
      e.preventDefault()
      choose(shown[active])
    }
  }

  // Rendered as a flat list with a heading before each change of group, so
  // the arrow keys move through one sequence rather than a tree.
  let lastGroup = ""

  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/60" />
        <DialogPrimitive.Content
          onKeyDown={onKeyDown}
          className="bg-card data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed top-[12vh] left-1/2 z-50 flex w-full max-w-[calc(100vw-2rem)] -translate-x-1/2 flex-col overflow-hidden rounded-xl border shadow-lg sm:max-w-xl"
        >
          <DialogPrimitive.Title className="sr-only">Command palette</DialogPrimitive.Title>
          <DialogPrimitive.Description className="sr-only">
            Search the sections and the service actions, then press Enter.
          </DialogPrimitive.Description>

          <div className="flex items-center gap-2 border-b px-3">
            <SearchIcon className="text-muted-foreground size-4 shrink-0" />
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search sections and services"
              aria-label="Search sections and services"
              className="placeholder:text-muted-foreground h-11 w-full bg-transparent text-sm outline-none"
            />
            <kbd className="bg-muted text-muted-foreground hidden rounded px-1.5 py-0.5 font-mono text-[10px] sm:block">
              esc
            </kbd>
          </div>

          <div ref={listRef} className="max-h-[55vh] overflow-y-auto p-1.5">
            {shown.length === 0 && (
              <p className="text-muted-foreground px-2.5 py-6 text-center text-sm">
                Nothing matches that.
              </p>
            )}
            {shown.map((item, i) => {
              const heading = item.group !== lastGroup ? item.group : null
              lastGroup = item.group
              const Icon = item.icon
              return (
                <React.Fragment key={item.id}>
                  {heading && (
                    <p className="text-muted-foreground px-2.5 pt-3 pb-1 text-[11px] font-medium tracking-wide uppercase first:pt-1">
                      {heading}
                    </p>
                  )}
                  <button
                    type="button"
                    data-active={i === active}
                    onMouseMove={() => setActive(i)}
                    onClick={() => choose(item)}
                    className={cn(
                      "flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm",
                      i === active ? "bg-accent text-accent-foreground" : "text-foreground"
                    )}
                  >
                    {Icon && <Icon className="text-muted-foreground size-4 shrink-0" />}
                    <span className="truncate">{item.label}</span>
                    {item.hint && (
                      <span className="text-muted-foreground ml-auto hidden truncate pl-3 text-xs sm:block">
                        {item.hint}
                      </span>
                    )}
                  </button>
                </React.Fragment>
              )
            })}
          </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  )
}
