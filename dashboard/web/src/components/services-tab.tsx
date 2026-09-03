import * as React from "react"
import {
  ExternalLinkIcon,
  Loader2Icon,
  PlayIcon,
  RefreshCwIcon,
  RotateCcwIcon,
  ScrollTextIcon,
  SquareIcon,
  WrenchIcon,
} from "lucide-react"

import { StatusBadge } from "@/components/status-badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import type { Service, ServiceAction } from "@/lib/api"

// Confirmation text per action. Only the ones that interrupt something ask;
// making every button ask trains people to click through the question.
const CONFIRM: Partial<Record<ServiceAction, (label: string) => string>> = {
  stop: (l) => `Stop ${l}? It stays stopped until you start it again.`,
  repair: (l) => `Regenerate config and recreate ${l}? No data is lost.`,
  update: (l) => `Pull the latest image for ${l} and restart it?`,
}

const ACTIONS: { action: ServiceAction; label: string; icon: typeof PlayIcon }[] = [
  { action: "start", label: "Start", icon: PlayIcon },
  { action: "stop", label: "Stop", icon: SquareIcon },
  { action: "restart", label: "Restart", icon: RotateCcwIcon },
  { action: "repair", label: "Repair", icon: WrenchIcon },
  { action: "update", label: "Update", icon: RefreshCwIcon },
]

export function ServicesTab({
  services,
  loading,
  busy,
  onAction,
  onLogs,
}: {
  services: Service[]
  loading: boolean
  busy: string | null
  onAction: (svc: Service, action: ServiceAction) => void
  onLogs: (svc: Service) => void
}) {
  if (loading) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-40" />
        ))}
      </div>
    )
  }

  if (!services.length) {
    return (
      <Card>
        <CardContent className="text-muted-foreground py-12 text-center text-sm">
          <p className="text-foreground mb-1 text-base">No services installed</p>
          <p>
            Install one with <code className="text-foreground">corex manage add &lt;service&gt;</code>
          </p>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {services.map((svc) => (
        <ServiceCard
          key={svc.name}
          svc={svc}
          busy={busy === svc.name}
          disabled={!!busy}
          onAction={onAction}
          onLogs={onLogs}
        />
      ))}
    </div>
  )
}

function ServiceCard({
  svc,
  busy,
  disabled,
  onAction,
  onLogs,
}: {
  svc: Service
  busy: boolean
  disabled: boolean
  onAction: (svc: Service, action: ServiceAction) => void
  onLogs: (svc: Service) => void
}) {
  const click = (action: ServiceAction) => {
    const ask = CONFIRM[action]
    if (ask && !window.confirm(ask(svc.label))) return
    onAction(svc, action)
  }

  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="flex items-start justify-between gap-2 text-sm">
          <span className="min-w-0 truncate" title={svc.label}>
            {svc.label}
          </span>
          {busy ? (
            <Loader2Icon className="text-muted-foreground size-4 shrink-0 animate-spin" />
          ) : (
            <StatusBadge status={svc.status} />
          )}
        </CardTitle>
        <div className="flex min-w-0 flex-col gap-0.5">
          {svc.urls.length ? (
            svc.urls.map((u) => (
              <a
                key={u}
                href={u}
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted-foreground hover:text-foreground inline-flex min-w-0 items-center gap-1 font-mono text-xs hover:underline"
              >
                <ExternalLinkIcon className="size-3 shrink-0" />
                <span className="truncate">{u}</span>
              </a>
            ))
          ) : (
            <span className="text-muted-foreground font-mono text-xs">no browsable address</span>
          )}
        </div>
      </CardHeader>
      <CardContent className="flex flex-wrap gap-1.5">
        {ACTIONS.map(({ action, label, icon: Icon }) => (
          <Button
            key={action}
            size="xs"
            variant={action === "stop" ? "outline" : "secondary"}
            disabled={disabled}
            onClick={() => click(action)}
          >
            <Icon />
            {label}
          </Button>
        ))}
        {svc.container && (
          <Button size="xs" variant="ghost" disabled={disabled} onClick={() => onLogs(svc)}>
            <ScrollTextIcon />
            Logs
          </Button>
        )}
      </CardContent>
    </Card>
  )
}
