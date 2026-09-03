import { GlobeIcon, InfoIcon, RouteIcon, ShieldCheckIcon } from "lucide-react"

import { CommandPanel } from "@/components/command-panel"
import { StatusBadge } from "@/components/status-badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import type { Service, State } from "@/lib/api"

export function NetworkTab({
  services,
  state,
  outputs,
  running,
  locked,
  onRun,
}: {
  services: Service[]
  state: State | null
  outputs: Record<string, string>
  running: string | null
  locked: boolean
  onRun: (action: string) => void
}) {
  return (
    <div className="flex flex-col gap-3">
      <Card className="gap-0 py-0">
        <CardHeader className="py-4">
          <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
            <GlobeIcon className="size-4" />
            Where each service answers
            {state?.domain && (
              <span className="text-muted-foreground ml-auto font-mono text-xs">
                *.{state.domain} to {state.server_ip}
              </span>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent className="px-0 pb-2">
          <div className="w-full overflow-x-auto">
              <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-1/3">Service</TableHead>
                <TableHead>Address</TableHead>
                <TableHead className="w-32">Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {services.map((svc) => (
                <TableRow key={svc.name}>
                  <TableCell className="font-medium">{svc.label}</TableCell>
                  <TableCell>
                    {svc.urls?.length ? (
                      svc.urls.map((u) => (
                        <a
                          key={u}
                          href={u}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="block font-mono text-xs hover:underline"
                        >
                          {u}
                        </a>
                      ))
                    ) : (
                      <span className="text-muted-foreground font-mono text-xs">
                        not reachable over the web
                      </span>
                    )}
                  </TableCell>
                  <TableCell>
                    <StatusBadge status={svc.status} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
              </div>
        </CardContent>
      </Card>

      <CommandPanel
        title="Reachability and certificates"
        description={
          <>
            Requests every hostname and reports the HTTP status, the certificate expiry, and
            whether DNS resolves to the server or out to Cloudflare. The table above says what a
            hostname should be; this says what it actually does. It requests each one in turn, so
            it takes a couple of minutes; the panel updates itself when it finishes.
          </>
        }
        action="network-check"
        icon={ShieldCheckIcon}
        buttonLabel="Check every hostname"
        output={outputs["network-check"]}
        running={running === "network-check"}
        locked={locked}
        onRun={onRun}
      />

      <CommandPanel
        title="Extra Traefik routes"
        description={
          <>
            Routes written into Traefik's file-provider directory, for containers CoreX did not
            deploy. A service CoreX manages routes itself by Docker label and does not appear
            here; a Coolify app needs an entry.
          </>
        }
        action="route-list"
        icon={RouteIcon}
        buttonLabel="List routes"
        output={outputs["route-list"]}
        running={running === "route-list"}
        locked={locked}
        onRun={onRun}
      />

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <InfoIcon className="size-4" />
            LAN fast path
          </CardTitle>
        </CardHeader>
        <CardContent className="text-muted-foreground space-y-2 text-xs leading-relaxed">
          <p>
            Only the addresses above exist. A hostname works because a Traefik rule declares it, so
            anything else resolves to nothing.
          </p>
          <p>
            To reach these at full LAN speed instead of going out to Cloudflare and back, run{" "}
            <code className="text-foreground">sudo corex manage lan-setup</code>. It sets the
            AdGuard DNS rewrite and prints the browser settings that otherwise bypass it.
          </p>
        </CardContent>
      </Card>
    </div>
  )
}
