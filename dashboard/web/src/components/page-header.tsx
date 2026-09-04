import * as React from "react"

/**
 * The heading every section opens with.
 *
 * The sidebar says where you are; this says what the page is for and gives
 * the section's own controls a place to sit that is not inside a card title.
 * It is rendered once, in `App.tsx`, from the same list the navigation and
 * the command palette read, so a section cannot be described one way in the
 * palette and another way at the top of its own page.
 */
export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string
  description?: React.ReactNode
  actions?: React.ReactNode
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
      <div className="grid min-w-0 gap-1">
        <h1 className="truncate text-lg font-semibold tracking-tight sm:text-xl">{title}</h1>
        {description && (
          <p className="text-muted-foreground text-sm leading-relaxed">{description}</p>
        )}
      </div>
      {actions && <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>}
    </div>
  )
}
