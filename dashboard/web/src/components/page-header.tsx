import * as React from "react"

/**
 * The line every section opens with.
 *
 * Title and the section's own controls, on one row. It used to carry a
 * description under the title as well, on every screen, which is the
 * "unnecessary label above content" habit: the sidebar already says where you
 * are, and a sentence explaining the page is read once and then skipped
 * forever. The same sentence still appears in the command palette, where
 * there is no surrounding page to explain the name.
 */
export function PageHeader({
  title,
  actions,
}: {
  title: string
  actions?: React.ReactNode
}) {
  return (
    <div className="flex min-w-0 flex-wrap items-center justify-between gap-x-4 gap-y-2">
      <h1 className="text-display min-w-0 truncate font-semibold tracking-tight">{title}</h1>
      {actions && <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>}
    </div>
  )
}
