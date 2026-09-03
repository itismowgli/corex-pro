import * as React from "react"
import { CheckIcon, CircleDashedIcon, GlobeIcon } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import type { CatalogueEntry } from "@/lib/api"

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

/**
 * Everything CoreX can install, not just what is installed.
 *
 * The metadata comes from the service modules themselves, so this cannot
 * drift from `corex manage list`: both read the same files, and adding a
 * module makes it appear here with no other change.
 */
export function CatalogueTab({
  entries,
  loading,
}: {
  entries: CatalogueEntry[]
  loading: boolean
}) {
  const groups = React.useMemo(() => {
    const g = new Map<string, CatalogueEntry[]>()
    for (const e of entries) {
      const list = g.get(e.category) ?? []
      list.push(e)
      g.set(e.category, list)
    }
    return [...g.entries()]
  }, [entries])

  if (loading) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-32" />
        ))}
      </div>
    )
  }

  const installed = entries.filter((e) => e.installed).length

  return (
    <div className="flex flex-col gap-5">
      <p className="text-muted-foreground text-xs">
        {entries.length} service modules, {installed} installed. A module can start more than one
        container: monitoring, ai and calcom each start three.
      </p>
      {groups.map(([category, list]) => (
        <div key={category} className="flex flex-col gap-2">
          <h3 className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
            {CATEGORY_LABEL[category] ?? category}
          </h3>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {list.map((e) => (
              <Card key={e.name} className="gap-2">
                <CardHeader>
                  <CardTitle className="flex items-start justify-between gap-2 text-sm">
                    <span className="truncate font-mono">{e.name}</span>
                    {e.installed ? (
                      <Badge variant="ok">
                        <CheckIcon />
                        installed
                      </Badge>
                    ) : (
                      <Badge variant="secondary">
                        <CircleDashedIcon />
                        available
                      </Badge>
                    )}
                  </CardTitle>
                  <p className="text-xs">{e.label}</p>
                </CardHeader>
                <CardContent className="flex flex-col gap-2">
                  <p className="text-muted-foreground text-xs leading-relaxed">{e.description}</p>
                  <div className="text-muted-foreground flex flex-wrap gap-1.5 text-xs">
                    {e.ram_mb > 0 && <Badge variant="outline">{e.ram_mb} MB RAM</Badge>}
                    {e.disk_gb > 0 && <Badge variant="outline">{e.disk_gb} GB disk</Badge>}
                    {e.needs_domain && (
                      <Badge variant="outline">
                        <GlobeIcon />
                        needs a domain
                      </Badge>
                    )}
                    {e.installed && !e.enabled && <Badge variant="warn">disabled</Badge>}
                  </div>
                  {!e.installed && (
                    <code className="bg-background rounded-md border px-2 py-1 font-mono text-xs">
                      corex manage add {e.name}
                    </code>
                  )}
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}
