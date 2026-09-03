import * as React from "react"
import {
  AlertTriangleIcon,
  HardDriveIcon,
  MonitorIcon,
  MoonIcon,
  NetworkIcon,
  RefreshCwIcon,
  ServerIcon,
  SunIcon,
} from "lucide-react"

import { JobPanel } from "@/components/job-panel"
import { LogsDialog } from "@/components/logs-dialog"
import { NetworkTab } from "@/components/network-tab"
import { ServicesTab } from "@/components/services-tab"
import { StorageTab } from "@/components/storage-tab"
import { SystemTab } from "@/components/system-tab"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { api, type Job, type Service, type ServiceAction } from "@/lib/api"
import { usePoll } from "@/lib/use-poll"

const TABS = [
  { id: "services", label: "Services", icon: ServerIcon },
  { id: "storage", label: "Storage", icon: HardDriveIcon },
  { id: "network", label: "Network", icon: NetworkIcon },
  { id: "system", label: "System", icon: MonitorIcon },
]

// Dark by default, because this is looked at in a terminal-shaped context and
// the previous dashboard was dark only. The choice is remembered per browser.
function useTheme() {
  const [dark, setDark] = React.useState(() => localStorage.getItem("corex-theme") !== "light")
  React.useEffect(() => {
    document.documentElement.classList.toggle("dark", dark)
    try {
      localStorage.setItem("corex-theme", dark ? "dark" : "light")
    } catch {
      // A browser with site data blocked still gets a working page.
    }
  }, [dark])
  return { dark, toggle: () => setDark((d) => !d) }
}

export default function App() {
  const { dark, toggle } = useTheme()
  const [tab, setTab] = React.useState(() => location.hash.replace("#", "") || "services")
  const [job, setJob] = React.useState<Job | null>(null)
  const [busy, setBusy] = React.useState<string | null>(null)
  const [logs, setLogs] = React.useState<{ container: string; label: string } | null>(null)

  const state = usePoll(api.state, 30_000)
  // 15s while idle. An action refreshes it immediately when the job ends, so a
  // badge is never more than a moment behind what the box is doing.
  const services = usePoll(api.services, 15_000)
  const storage = usePoll(api.storage, 0)
  const ports = usePoll(api.ports, 0)

  React.useEffect(() => {
    location.hash = tab
  }, [tab])

  const svcList: Service[] = services.data ?? []
  const counts = React.useMemo(() => {
    const c = { healthy: 0, unhealthy: 0, other: 0 }
    for (const s of svcList) {
      if (s.status === "HEALTHY") c.healthy++
      else if (s.status === "UNHEALTHY") c.unhealthy++
      else c.other++
    }
    return c
  }, [svcList])

  const runAction = async (svc: Service, action: ServiceAction) => {
    setBusy(svc.name)
    setJob({ id: "", state: "running", label: `${action} ${svc.name}`, output: "" })
    try {
      const started = await api.act(svc.name, action)
      setJob(started)
      if (started.state !== "running") {
        setBusy(null)
        void services.refresh()
      }
    } catch (e) {
      setBusy(null)
      setJob({
        id: "",
        state: "failed",
        label: `${action} ${svc.name}`,
        output: e instanceof Error ? e.message : String(e),
      })
    }
  }

  const runCleanup = async (dryRun: boolean) => {
    setBusy("cleanup")
    setJob({
      id: "",
      state: "running",
      label: dryRun ? "cleanup --dry-run" : "cleanup",
      output: "",
    })
    try {
      const started = await api.cleanup(dryRun)
      setJob(started)
      if (started.state !== "running") {
        setBusy(null)
        void storage.refresh()
      }
    } catch (e) {
      setBusy(null)
      setJob({
        id: "",
        state: "failed",
        label: "cleanup",
        output: e instanceof Error ? e.message : String(e),
      })
    }
  }

  const onJobFinished = React.useCallback(() => {
    setBusy(null)
    void services.refresh()
    void storage.refresh()
  }, [services, storage])

  return (
    <div className="min-h-screen">
      <header className="bg-card/80 sticky top-0 z-40 border-b backdrop-blur">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3 px-4 py-3">
          <span className="text-base font-semibold tracking-tight">
            CoreX <span className="text-muted-foreground font-normal">Pro</span>
          </span>
          {state.data?.domain && (
            <span className="text-muted-foreground font-mono text-xs">{state.data.domain}</span>
          )}
          <div className="ml-auto flex items-center gap-2">
            {svcList.length > 0 && (
              <>
                <Badge variant="ok">{counts.healthy} healthy</Badge>
                {counts.unhealthy > 0 && (
                  <Badge variant="destructive">{counts.unhealthy} unhealthy</Badge>
                )}
                {counts.other > 0 && <Badge variant="secondary">{counts.other} stopped</Badge>}
              </>
            )}
            <Button
              size="icon"
              variant="ghost"
              onClick={() => {
                void services.refresh()
                void state.refresh()
                void storage.refresh()
              }}
              aria-label="Refresh"
            >
              <RefreshCwIcon />
            </Button>
            <Button size="icon" variant="ghost" onClick={toggle} aria-label="Toggle theme">
              {dark ? <SunIcon /> : <MoonIcon />}
            </Button>
          </div>
        </div>
      </header>

      <main className="mx-auto flex max-w-7xl flex-col gap-4 p-4">
        {state.data && !state.data.agent_ok && (
          <Card className="border-destructive/50">
            <CardContent className="flex items-start gap-2 text-sm">
              <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
              <div>
                <p className="font-medium">The action agent is unreachable, so the buttons cannot work.</p>
                <p className="text-muted-foreground mt-1 text-xs">
                  {state.data.agent_error || "no detail"}. Check it with{" "}
                  <code className="text-foreground">sudo corex manage agent test</code>, which also
                  reports whether this container can see the socket.
                </p>
              </div>
            </CardContent>
          </Card>
        )}

        {(services.error || state.error) && (
          <Card className="border-destructive/50">
            <CardContent className="text-sm">
              <p className="font-medium">Could not load the dashboard data.</p>
              <p className="text-muted-foreground mt-1 font-mono text-xs">
                {services.error || state.error}
              </p>
            </CardContent>
          </Card>
        )}

        <JobPanel job={job} setJob={setJob} onFinished={onJobFinished} />

        <Tabs value={tab} onValueChange={setTab}>
          <TabsList>
            {TABS.map(({ id, label, icon: Icon }) => (
              <TabsTrigger key={id} value={id}>
                <Icon />
                {label}
              </TabsTrigger>
            ))}
          </TabsList>

          <TabsContent value="services">
            <ServicesTab
              services={svcList}
              loading={services.loading}
              busy={busy}
              onAction={runAction}
              onLogs={(svc) => setLogs({ container: svc.container, label: svc.label })}
            />
          </TabsContent>
          <TabsContent value="storage">
            <StorageTab
              output={storage.data?.output ?? ""}
              loading={storage.loading}
              error={storage.error}
              busy={busy === "cleanup"}
              onCleanup={runCleanup}
            />
          </TabsContent>
          <TabsContent value="network">
            <NetworkTab services={svcList} state={state.data} />
          </TabsContent>
          <TabsContent value="system">
            <SystemTab state={state.data} ports={ports.data ?? []} />
          </TabsContent>
        </Tabs>

        <footer className="text-muted-foreground pb-6 text-center text-xs">
          {state.data?.version && <>CoreX Pro v{state.data.version} · </>}
          {state.data?.server_ip}
        </footer>
      </main>

      <LogsDialog
        container={logs?.container ?? null}
        label={logs?.label ?? ""}
        onClose={() => setLogs(null)}
      />
    </div>
  )
}
