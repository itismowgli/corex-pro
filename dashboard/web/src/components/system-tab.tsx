import { PowerCard } from "@/components/power-card"
import { Empty, Row, Rows, Section } from "@/components/ui/section"
import type { Metrics, Port, PowerMode, State } from "@/lib/api"

/**
 * What this machine is.
 *
 * Almost everything here is a fact with a name, so it is a list of facts and
 * not a grid of boxes. The one framed thing on the page is the power card,
 * because it is the only control that cannot be undone from here: the
 * dashboard runs on the machine it would be switching off.
 *
 * "Update every service" used to sit here as well as on Updates, offering the
 * same action from two places under two names. Updates owns it.
 */

const COMMANDS: [string, string][] = [
  ["Service health", "corex manage status"],
  ["Host hardware, temperature, SMART", "corex manage health"],
  ["Add a service", "corex manage add <name>"],
  ["Regenerate config and recreate", "corex manage repair <name>"],
  ["Storage report", "corex manage storage"],
  ["Update CoreX and every service", "corex manage update-everything"],
  ["LAN fast path", "corex manage lan-setup"],
  ["Wake-on-LAN state", "corex manage power"],
]

export function SystemTab({
  state,
  ports,
  metrics,
  powerBusy,
  onPower,
}: {
  state: State | null
  ports: Port[]
  metrics: Metrics | null
  powerBusy: PowerMode | null
  onPower: (mode: PowerMode) => void
}) {
  const port = state?.ssh_port || "22"
  const v = (s: string | undefined) => s || "unknown"

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-6 lg:grid-cols-2">
        <Section title="Host">
          <Rows>
            <Row label="Hostname" value={v(state?.hostname)} />
            <Row label="Address" value={v(state?.server_ip)} />
            <Row label="Kernel" value={v(state?.kernel)} />
            <Row label="Uptime" value={v(state?.uptime)} />
            <Row label="Timezone" value={v(state?.timezone)} />
          </Rows>
        </Section>

        <Section title="Software">
          <Rows>
            <Row label="CoreX" value={state?.version ? `v${state.version}` : "unknown"} />
            <Row label="Docker" value={v(state?.docker)} />
            <Row label="Domain" value={v(state?.domain)} />
            <Row
              label="Action agent"
              value={state?.agent_ok ? "reachable" : state?.agent_error || "unreachable"}
              tone={state?.agent_ok ? "ok" : "danger"}
              hint={
                state?.agent_ok
                  ? undefined
                  : "Every button on this page goes through the agent, so none of them can work until it is."
              }
            />
          </Rows>
        </Section>
      </div>

      <Section title="SSH">
        {port !== "22" && (
          <p className="text-warn text-small">
            SSH listens on {port}, not 22. Port 22 is closed, including inside Portainer.
          </p>
        )}
        <pre className="term bg-muted/40 rounded-lg px-3 py-2">
          ssh YOUR_USERNAME@{state?.server_ip || "SERVER_IP"} -p {port}
        </pre>
      </Section>

      <PowerCard metrics={metrics} busy={powerBusy} onPower={onPower} />

      <Section title="Direct ports">
        <p className="text-muted-foreground text-small">
          These bypass Traefik, which is what makes them useful before DNS is set up or when a
          certificate is the problem.
        </p>
        {ports.length === 0 ? (
          <Empty>No service publishes a port of its own.</Empty>
        ) : (
          <Rows>
            {ports.map((p) => (
              <Row
                key={p.service + p.url}
                label={p.service}
                value={
                  p.url.startsWith("http") ? (
                    <a
                      href={p.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="hover:text-foreground hover:underline"
                    >
                      {p.url}
                    </a>
                  ) : (
                    p.url
                  )
                }
                hint={p.note}
              />
            ))}
          </Rows>
        )}
      </Section>

      <Section title="On the command line">
        <div className="grid gap-x-6 gap-y-2 sm:grid-cols-2">
          {COMMANDS.map(([label, cmd]) => (
            <div key={cmd} className="flex min-w-0 flex-col gap-0.5">
              <span className="text-muted-foreground text-small">{label}</span>
              <code className="text-foreground truncate font-mono text-small">{cmd}</code>
            </div>
          ))}
        </div>
      </Section>
    </div>
  )
}
