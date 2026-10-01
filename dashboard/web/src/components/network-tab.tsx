import { RouteIcon, ShieldCheckIcon } from "lucide-react"

import { CommandPanel } from "@/components/command-panel"
import { StatusBadge } from "@/components/status-badge"
import { Empty, Row, Rows, Section } from "@/components/ui/section"
import type { Service, State } from "@/lib/api"

/**
 * Where everything answers, and whether it really does.
 *
 * The list is what a hostname is declared to be; the checks below it are what
 * the hostname actually does, which is a different question and the one worth
 * running when something is unreachable.
 *
 * It was a three column table inside a card. A table earns its columns when
 * they are compared down the page, and these are not: nobody scans a column
 * of addresses. A row per service, with the address under the name, reads at
 * a glance and survives a phone, which the table did by scrolling sideways.
 */

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
    <div className="flex flex-col gap-6">
      <Section
        title="Where each service answers"
        action={
          state?.domain && (
            <span className="text-muted-foreground num font-mono text-small">
              *.{state.domain} to {state.server_ip}
            </span>
          )
        }
      >
        {services.length === 0 ? (
          <Empty>Nothing is installed yet, so no hostname is routed.</Empty>
        ) : (
          <Rows>
            {services.map((svc) => (
              <Row
                key={svc.name}
                label={
                  <span className="flex min-w-0 items-center gap-2">
                    <span className="text-foreground truncate">{svc.label}</span>
                    <StatusBadge status={svc.status} />
                  </span>
                }
                hint={
                  svc.urls?.length ? (
                    <span className="flex flex-col">
                      {svc.urls.map((u) => (
                        <a
                          key={u}
                          href={u}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="hover:text-foreground truncate font-mono hover:underline"
                        >
                          {u}
                        </a>
                      ))}
                    </span>
                  ) : (
                    "not reachable over the web"
                  )
                }
              />
            ))}
          </Rows>
        )}
        <p className="text-muted-foreground text-small">
          Only these addresses exist. A hostname works because a Traefik rule declares it, so
          anything else resolves to nothing. To reach them at LAN speed rather than going out to
          Cloudflare and back, run <code className="text-foreground">sudo corex manage lan-setup</code>:
          it sets the AdGuard rewrite and prints the browser settings that otherwise bypass it.
        </p>
      </Section>

      <CommandPanel
        title="Reachability and certificates"
        description={
          <>
            Requests every hostname and reports the HTTP status, the certificate expiry, and
            whether DNS resolves to the server or out to Cloudflare. It requests each one in
            turn, so it takes a couple of minutes and updates itself when it finishes.
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
    </div>
  )
}
