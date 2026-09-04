import * as React from "react"
import { PanelLeftIcon, SearchIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { navGroups } from "@/lib/nav"

/**
 * The primary navigation.
 *
 * The same body is rendered twice: as a fixed column on a wide screen, and
 * inside a drawer on a phone. Two copies of the list would drift, and the one
 * that drifts is always the phone.
 *
 * Collapsed it keeps the icons and drops the words, so the sections stay in
 * the same order and the same place. A rail that reorders itself is a rail
 * nobody builds muscle memory for.
 */
export function SidebarBody({
  tab,
  onSelect,
  authEnabled,
  collapsed = false,
  onToggleCollapse,
  onOpenPalette,
  version,
  serverIp,
}: {
  tab: string
  onSelect: (id: string) => void
  authEnabled: boolean | undefined
  collapsed?: boolean
  onToggleCollapse?: () => void
  onOpenPalette: () => void
  version?: string
  serverIp?: string
}) {
  const groups = navGroups(authEnabled)
  return (
    <div className="flex h-full min-h-0 flex-col gap-3 py-3">
      <div className={cn("flex items-center gap-2 px-3", collapsed && "justify-center px-2")}>
        {!collapsed && (
          <span className="truncate text-base font-semibold tracking-tight">
            CoreX <span className="text-muted-foreground font-normal">Pro</span>
          </span>
        )}
        {onToggleCollapse && (
          <Button
            size="icon"
            variant="ghost"
            className={cn("size-8", !collapsed && "ml-auto")}
            onClick={onToggleCollapse}
            aria-label={collapsed ? "Expand the sidebar" : "Collapse the sidebar"}
            title={collapsed ? "Expand the sidebar" : "Collapse the sidebar"}
          >
            <PanelLeftIcon />
          </Button>
        )}
      </div>

      <div className={cn("px-3", collapsed && "px-2")}>
        <button
          type="button"
          onClick={onOpenPalette}
          title="Search or jump to a section"
          className={cn(
            "border-input bg-background text-muted-foreground hover:border-ring focus-visible:ring-ring/50 flex h-9 w-full items-center gap-2 rounded-lg border px-2.5 text-sm transition-colors focus-visible:ring-[3px] focus-visible:outline-none",
            collapsed && "justify-center px-0"
          )}
        >
          <SearchIcon className="size-4 shrink-0" />
          {!collapsed && (
            <>
              <span className="truncate">Search or jump to</span>
              <kbd className="bg-muted text-muted-foreground ml-auto rounded px-1.5 py-0.5 font-mono text-[10px]">
                ⌘K
              </kbd>
            </>
          )}
        </button>
      </div>

      <nav
        aria-label="Sections"
        className={cn("flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-3", collapsed && "px-2")}
      >
        {groups.map((group) => (
          <div key={group.title} className="grid gap-1">
            {!collapsed && (
              <p className="text-muted-foreground px-2 text-[11px] font-medium tracking-wide uppercase">
                {group.title}
              </p>
            )}
            {group.items.map(({ id, label, icon: Icon }) => {
              const active = id === tab
              return (
                <button
                  key={id}
                  type="button"
                  onClick={() => onSelect(id)}
                  aria-current={active ? "page" : undefined}
                  title={collapsed ? label : undefined}
                  className={cn(
                    "focus-visible:ring-ring/50 flex h-9 items-center gap-2.5 rounded-lg px-2.5 text-sm transition-colors focus-visible:ring-[3px] focus-visible:outline-none",
                    collapsed && "justify-center px-0",
                    active
                      ? "bg-accent text-accent-foreground font-medium"
                      : "text-muted-foreground hover:bg-accent/60 hover:text-foreground"
                  )}
                >
                  <Icon className="size-4 shrink-0" />
                  {!collapsed && <span className="truncate">{label}</span>}
                </button>
              )
            })}
          </div>
        ))}
      </nav>

      {!collapsed && (version || serverIp) && (
        <div className="text-muted-foreground grid gap-0.5 px-5 text-[11px]">
          {version && <span>CoreX Pro v{version}</span>}
          {serverIp && <span className="font-mono">{serverIp}</span>}
        </div>
      )}
    </div>
  )
}
