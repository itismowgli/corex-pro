import * as React from "react"
import {
  CheckIcon,
  CircleDashedIcon,
  ExternalLinkIcon,
  LayersIcon,
  SearchIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import type { CatalogueEntry } from "@/lib/api"
import { cn } from "@/lib/utils"

/**
 * Everything CoreX can install, not just what is installed.
 *
 * The metadata is read from the service modules themselves, so this cannot
 * drift from `corex manage list`: both read the same files, and a new module
 * appears here with no other change.
 *
 * Seventeen modules in one long scroll made the reader do the filtering, so
 * the categories are a sidebar and the state is a filter. The counts are on
 * the sidebar because "which of these do I not have" is the question this page
 * is usually open to answer.
 */

const CATEGORY_LABEL: Record<string, string> = {
  core: "Core infrastructure",
  storage: "Storage and media",
  security: "Security",
  productivity: "Productivity",
  ai: "AI",
  monitoring: "Monitoring",
  communication: "Communication",
  backup: "Backup",
}

const CATEGORY_ORDER = [
  "core",
  "security",
  "storage",
  "productivity",
  "communication",
  "monitoring",
  "ai",
  "backup",
]

type StateFilter = "all" | "installed" | "available"

function categoryLabel(key: string) {
  return CATEGORY_LABEL[key] ?? key
}

function EntryCard({ e }: { e: CatalogueEntry }) {
  return (
    <Card className="gap-2 py-3">
      <CardContent className="grid gap-2 px-3">
        <div className="flex items-start justify-between gap-2">
          <span className="text-sm leading-tight font-medium">{e.label || e.name}</span>
          {e.installed ? (
            <Badge variant={e.enabled ? "ok" : "secondary"}>
              <CheckIcon />
              {e.enabled ? "installed" : "stopped"}
            </Badge>
          ) : (
            <Badge variant="outline">
              <CircleDashedIcon />
              available
            </Badge>
          )}
        </div>

        {e.description && (
          <p className="text-muted-foreground text-xs leading-relaxed">{e.description}</p>
        )}

        {e.urls.length > 0 ? (
          <div className="grid gap-0.5">
            {e.urls.map((u) => (
              <a
                key={u}
                href={u}
                target="_blank"
                rel="noreferrer"
                className="text-muted-foreground hover:text-foreground flex items-center gap-1 font-mono text-xs"
              >
                <ExternalLinkIcon className="size-3 shrink-0" />
                <span className="truncate">{u}</span>
              </a>
            ))}
          </div>
        ) : (
          <p className="text-muted-foreground font-mono text-xs">
            {e.needs_domain ? "no address of its own" : "runs on the LAN, no web address"}
          </p>
        )}

        <div className="text-muted-foreground flex flex-wrap gap-2 text-xs">
          <span>{e.ram_mb} MB RAM</span>
          <span>·</span>
          <span>{e.disk_gb} GB disk</span>
        </div>

        {!e.installed && (
          <code className="bg-muted text-muted-foreground rounded px-1.5 py-1 text-xs">
            sudo corex manage add {e.name}
          </code>
        )}
      </CardContent>
    </Card>
  )
}

export function CatalogueTab({
  entries,
  loading,
}: {
  entries: CatalogueEntry[]
  loading: boolean
}) {
  const [category, setCategory] = React.useState<string>("all")
  const [state, setState] = React.useState<StateFilter>("all")
  const [query, setQuery] = React.useState("")

  const categories = React.useMemo(() => {
    const counts = new Map<string, number>()
    for (const e of entries) counts.set(e.category, (counts.get(e.category) ?? 0) + 1)
    const known = CATEGORY_ORDER.filter((c) => counts.has(c))
    const rest = [...counts.keys()].filter((c) => !CATEGORY_ORDER.includes(c)).sort()
    return [...known, ...rest].map((c) => ({ key: c, count: counts.get(c) ?? 0 }))
  }, [entries])

  const shown = React.useMemo(() => {
    const q = query.trim().toLowerCase()
    return entries.filter((e) => {
      if (category !== "all" && e.category !== category) return false
      if (state === "installed" && !e.installed) return false
      if (state === "available" && e.installed) return false
      if (!q) return true
      return (
        e.name.toLowerCase().includes(q) ||
        e.label.toLowerCase().includes(q) ||
        e.description.toLowerCase().includes(q)
      )
    })
  }, [entries, category, state, query])

  const installed = entries.filter((e) => e.installed).length

  if (loading && entries.length === 0) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {[0, 1, 2, 3, 4, 5].map((i) => (
          <Skeleton key={i} className="h-36" />
        ))}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-3 lg:flex-row">
      <aside className="lg:w-56 lg:shrink-0">
        <div className="flex flex-row flex-wrap gap-1 lg:sticky lg:top-20 lg:flex-col">
          <button
            onClick={() => setCategory("all")}
            className={cn(
              "flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-left text-sm transition-colors",
              category === "all" ? "bg-accent text-accent-foreground" : "hover:bg-accent/50"
            )}
          >
            <span className="flex items-center gap-1.5">
              <LayersIcon className="size-3.5" />
              Everything
            </span>
            <span className="text-muted-foreground font-mono text-xs">{entries.length}</span>
          </button>
          {categories.map(({ key, count }) => (
            <button
              key={key}
              onClick={() => setCategory(key)}
              className={cn(
                "flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-left text-sm transition-colors",
                category === key ? "bg-accent text-accent-foreground" : "hover:bg-accent/50"
              )}
            >
              <span className="truncate">{categoryLabel(key)}</span>
              <span className="text-muted-foreground font-mono text-xs">{count}</span>
            </button>
          ))}
          <p className="text-muted-foreground mt-2 hidden px-2.5 text-xs lg:block">
            {installed} of {entries.length} installed. A module is one file in
            lib/services/, so this list is the directory.
          </p>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-48 flex-1">
            <SearchIcon className="text-muted-foreground pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2" />
            <Input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search by name or what it replaces"
              className="h-8 pl-8"
              aria-label="Search the catalogue"
            />
          </div>
          {(["all", "installed", "available"] as StateFilter[]).map((s) => (
            <Button
              key={s}
              size="xs"
              variant={state === s ? "default" : "secondary"}
              onClick={() => setState(s)}
            >
              {s === "all" ? "Any state" : s}
            </Button>
          ))}
        </div>

        {shown.length === 0 ? (
          <Card>
            <CardContent className="text-muted-foreground text-sm">
              Nothing matches that. Clear the search or pick another category.
            </CardContent>
          </Card>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {shown.map((e) => (
              <EntryCard key={e.name} e={e} />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
