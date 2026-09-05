import { AlertTriangleIcon, CheckIcon, CircleSlashIcon, MinusIcon, MoonIcon } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import type { ServiceStatus } from "@/lib/api"

// DISABLED is not a fault and must not read as one. A container stopped on
// purpose was reported as unhealthy for a long time, which trained everyone to
// ignore the colour.
const MAP: Record<ServiceStatus, { variant: "ok" | "destructive" | "secondary"; icon: typeof CheckIcon }> = {
  HEALTHY: { variant: "ok", icon: CheckIcon },
  UNHEALTHY: { variant: "destructive", icon: AlertTriangleIcon },
  MISSING: { variant: "secondary", icon: CircleSlashIcon },
  SLEEPING: { variant: "secondary", icon: MoonIcon },
  DISABLED: { variant: "secondary", icon: MinusIcon },
  UNKNOWN: { variant: "secondary", icon: MinusIcon },
}

export function StatusBadge({ status }: { status: ServiceStatus }) {
  const { variant, icon: Icon } = MAP[status] ?? MAP.UNKNOWN
  return (
    <Badge variant={variant} className="gap-1">
      <Icon />
      {status}
    </Badge>
  )
}
