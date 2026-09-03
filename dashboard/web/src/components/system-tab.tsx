import { CpuIcon, DownloadIcon, KeyRoundIcon, PlugIcon, TerminalIcon } from "lucide-react"

import { CommandPanel } from "@/components/command-panel"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableRow } from "@/components/ui/table"
import type { Port, State } from "@/lib/api"

const COMMANDS: [string, string][] = [
  ["Service health", "corex manage status"],
  ["Host hardware, temperature, SMART", "corex manage health"],
  ["Add a service", "corex manage add <name>"],
  ["Regenerate config and recreate", "corex manage repair <name>"],
  ["Storage report", "corex manage storage"],
  ["Update every service", "corex manage update --all"],
  ["LAN fast path", "corex manage lan-setup"],
  ["Update CoreX itself", "corex update --force"],
]

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4 text-sm">
      <span className="text-muted-foreground">{k}</span>
      <span className="truncate font-mono text-xs" title={v}>
        {v || "unknown"}
      </span>
    </div>
  )
}

export function SystemTab({
  state,
  ports,
  outputs,
  running,
  locked,
  onUpdateAll,
}: {
  state: State | null
  ports: Port[]
  outputs: Record<string, string>
  running: string | null
  locked: boolean
  onUpdateAll: () => void
}) {
  const port = state?.ssh_port || "22"
  return (
    <div className="flex flex-col gap-3">
      <div className="grid gap-3 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              <CpuIcon className="size-4" />
              Host
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            <Row k="Hostname" v={state?.hostname ?? ""} />
            <Row k="Server IP" v={state?.server_ip ?? ""} />
            <Row k="Kernel" v={state?.kernel ?? ""} />
            <Row k="Uptime" v={state?.uptime ?? ""} />
            <Row k="Timezone" v={state?.timezone ?? ""} />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-sm">
              <PlugIcon className="size-4" />
              Software
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            <Row k="CoreX" v={state?.version ? `v${state.version}` : ""} />
            <Row k="Docker" v={state?.docker ?? ""} />
            <Row k="Domain" v={state?.domain ?? ""} />
            <Row k="Action agent" v={state?.agent_ok ? "reachable" : state?.agent_error || "unreachable"} />
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <KeyRoundIcon className="size-4" />
            SSH access
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {port !== "22" && (
            <p className="text-warn text-xs">
              SSH listens on {port}, not 22. Port 22 is closed, including in Portainer environments.
            </p>
          )}
          <pre className="term bg-background rounded-md border p-3">
            ssh YOUR_USERNAME@{state?.server_ip || "SERVER_IP"} -p {port}
          </pre>
        </CardContent>
      </Card>

      {ports.length > 0 && (
        <Card className="gap-0 py-0">
          <CardHeader className="py-4">
            <CardTitle className="text-sm">Direct ports</CardTitle>
            <p className="text-muted-foreground text-xs">
              Bypass Traefik. Useful before DNS is set up, or when a certificate is the problem.
            </p>
          </CardHeader>
          <CardContent className="px-0 pb-2">
            <Table>
              <TableBody>
                {ports.map((p) => (
                  <TableRow key={p.service + p.url}>
                    <TableCell className="w-40 font-medium">{p.service}</TableCell>
                    <TableCell>
                      {p.url.startsWith("http") ? (
                        <a
                          href={p.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="font-mono text-xs hover:underline"
                        >
                          {p.url}
                        </a>
                      ) : (
                        <span className="font-mono text-xs">{p.url}</span>
                      )}
                    </TableCell>
                    <TableCell className="text-muted-foreground text-xs">{p.note}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      <CommandPanel
        title="Update every service"
        description={
          <>
            Pulls new images for all installed services and recreates what changed. It reports
            which images actually moved, because a tag that has stopped moving upstream is
            otherwise invisible: one image here sat ten months behind while every update run
            reported success. Run Doctor afterwards.
          </>
        }
        action="update-all"
        icon={DownloadIcon}
        buttonLabel="Update all"
        variant="outline"
        confirm="Pull new images for every installed service and recreate the ones that changed?"
        output={outputs["update-all"]}
        running={running === "update-all"}
        locked={locked}
        onRun={onUpdateAll}
      />

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <TerminalIcon className="size-4" />
            Commands worth knowing
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-2 sm:grid-cols-2">
          {COMMANDS.map(([label, cmd]) => (
            <div key={cmd} className="flex flex-col gap-1">
              <span className="text-muted-foreground text-xs">{label}</span>
              <code className="bg-background rounded-md border px-2 py-1 font-mono text-xs">
                {cmd}
              </code>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}
