import * as React from "react"
import {
  AlertTriangleIcon,
  GaugeIcon,
  HardDriveIcon,
  HeartPulseIcon,
  LayoutGridIcon,
  LogOutIcon,
  MonitorIcon,
  MoonIcon,
  NetworkIcon,
  RefreshCwIcon,
  ServerIcon,
  SunIcon,
  UserRoundIcon,
} from "lucide-react"

import { AccountTab } from "@/components/account-tab"
import { OverviewTab } from "@/components/overview-tab"
import { CatalogueTab } from "@/components/catalogue-tab"
import { HealthTab } from "@/components/health-tab"
import { JobPanel } from "@/components/job-panel"
import { LoginScreen } from "@/components/login-screen"
import { LogsDialog } from "@/components/logs-dialog"
import { NetworkTab } from "@/components/network-tab"
import { ServicesTab } from "@/components/services-tab"
import { StorageTab } from "@/components/storage-tab"
import { SystemTab } from "@/components/system-tab"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import {
  api,
  auth,
  UNAUTHENTICATED_EVENT,
  type Job,
  type Overview,
  type Me,
  type RunAction,
  type Service,
  type ServiceAction,
} from "@/lib/api"
import { usePoll } from "@/lib/use-poll"

const TABS = [
  { id: "overview", label: "Overview", icon: GaugeIcon },
  { id: "services", label: "Services", icon: ServerIcon },
  { id: "health", label: "Health", icon: HeartPulseIcon },
  { id: "storage", label: "Storage", icon: HardDriveIcon },
  { id: "network", label: "Network", icon: NetworkIcon },
  { id: "catalogue", label: "Catalogue", icon: LayoutGridIcon },
  { id: "system", label: "System", icon: MonitorIcon },
]

// Shown only once the dashboard has accounts of its own. Before that there is
// nothing to manage here: Traefik basic auth has no notion of who you are.
const ACCOUNT_TAB = { id: "account", label: "Account", icon: UserRoundIcon }

// Dark by default, because this is looked at in a terminal-shaped context and
// the previous dashboard was dark only. The choice is remembered per browser.
//
// Both halves are guarded. Reading localStorage throws, not returns null, in a
// browser with site data blocked, and this read is in a useState initialiser:
// an exception there happens during the first render, so React unmounts the
// tree and the page goes completely blank with no visible cause. A remembered
// theme is not worth a blank dashboard.
function readTheme(): boolean {
  try {
    return localStorage.getItem("corex-theme") !== "light"
  } catch {
    return true
  }
}

function useTheme() {
  const [dark, setDark] = React.useState(readTheme)
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

/**
 * The gate.
 *
 * Nothing that talks to the box is mounted until /api/auth/me says there is a
 * session, which is what stops the whole dashboard polling six endpoints into
 * a wall of 401s behind the login form. It also means signing out unmounts
 * every panel rather than leaving stale service state on the screen.
 *
 * A login that is not configured yet is not an error: auth_enabled is false
 * until the first account exists, and until then Traefik basic auth is still
 * in front and the dashboard behaves exactly as it did before.
 */
export default function App() {
  const { dark, toggle } = useTheme()
  const me = usePoll(auth.me, 5 * 60_000)

  // Any request can be the one that discovers the session has gone: it can
  // expire mid-poll, and a password change from SSH revokes it outright.
  // Depends on refresh, not on the poll object: usePoll returns a fresh
  // object every render, so listing it here would tear down and re-add the
  // listener on every state change in the app.
  const refreshMe = me.refresh
  React.useEffect(() => {
    const onGone = () => void refreshMe()
    window.addEventListener(UNAUTHENTICATED_EVENT, onGone)
    return () => window.removeEventListener(UNAUTHENTICATED_EVENT, onGone)
  }, [refreshMe])

  if (me.loading && !me.data && !me.error) {
    return (
      <div className="text-muted-foreground flex min-h-screen items-center justify-center text-sm">
        CoreX Pro
      </div>
    )
  }

  // An unreadable /api/auth/me is treated as signed out on purpose. The other
  // reading, carry on and hope, produces a dashboard whose every panel has
  // failed and whose buttons all do nothing, which is worse than a login form
  // saying what went wrong.
  const signedIn = !!me.data && (!me.data.auth_enabled || me.data.authenticated)
  if (!signedIn) {
    return <LoginScreen me={me.data} error={me.error} onSignedIn={() => void refreshMe()} />
  }

  return (
    <Dashboard
      me={me.data}
      refreshMe={() => void refreshMe()}
      dark={dark}
      toggleTheme={toggle}
    />
  )
}

function Dashboard({
  me,
  refreshMe,
  dark,
  toggleTheme,
}: {
  me: Me | null
  refreshMe: () => void
  dark: boolean
  toggleTheme: () => void
}) {
  const [tab, setTab] = React.useState(() => location.hash.replace("#", "") || "overview")
  const [job, setJob] = React.useState<Job | null>(null)
  // Which service is mid-action, so its own card shows it, and which box-wide
  // command is running, so its panel does.
  const [busy, setBusy] = React.useState<string | null>(null)
  const [runningAction, setRunningAction] = React.useState<string | null>(null)
  // Command output kept per action, so switching tabs does not throw away the
  // health report you just ran.
  const [outputs, setOutputs] = React.useState<Record<string, string>>({})
  const [logs, setLogs] = React.useState<{ container: string; label: string } | null>(null)

  const state = usePoll(api.state, 30_000)
  // 15s while idle. An action refreshes it immediately when the job ends, so a
  // badge is never more than a moment behind what the box is doing.
  const services = usePoll(api.services, 15_000)
  const storage = usePoll(api.storage, 0)
  // 20s, matching the blackbox sampler: polling faster shows the same numbers
  // twice, and this call walks both disks and Kuma's database.
  const overview = usePoll(api.overview, 20_000)
  const ports = usePoll(api.ports, 0)
  const catalogue = usePoll(api.catalogue, 0)

  React.useEffect(() => {
    location.hash = tab
  }, [tab])

  const tabs = React.useMemo(
    () => (me?.auth_enabled ? [...TABS, ACCOUNT_TAB] : TABS),
    [me?.auth_enabled]
  )

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

  const fail = (label: string, e: unknown) => {
    setBusy(null)
    setRunningAction(null)
    setJob({
      id: "",
      state: "failed",
      label,
      output: e instanceof Error ? e.message : String(e),
    })
  }

  const runService = async (svc: Service, action: ServiceAction) => {
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
      fail(`${action} ${svc.name}`, e)
    }
  }

  // Box-wide commands: health, watchdog, network-check, route-list, doctor,
  // cleanup and update-all. Their output lands in the panel that asked.
  const runBox = async (action: string) => {
    setRunningAction(action)
    setJob({ id: "", state: "running", label: action, output: "" })
    try {
      const started =
        action === "update-all"
          ? await api.updateAll()
          : action === "cleanup" || action === "cleanup-preview"
            ? await api.cleanup(action === "cleanup-preview")
            : await api.run(action as RunAction)
      setJob(started)
      if (started.state !== "running") {
        setRunningAction(null)
        setOutputs((o) => ({ ...o, [action]: started.output }))
        if (action.startsWith("cleanup")) void storage.refresh()
      }
    } catch (e) {
      fail(action, e)
    }
  }

  const onJobFinished = React.useCallback(
    (finished: Job) => {
      setBusy(null)
      if (runningAction) {
        setOutputs((o) => ({ ...o, [runningAction]: finished.output }))
        setRunningAction(null)
      }
      void services.refresh()
      void state.refresh()
      void catalogue.refresh()
      void overview.refresh()
      if (runningAction?.startsWith("cleanup")) void storage.refresh()
    },
    [runningAction, services, state, catalogue, storage, overview]
  )

  // The agent serialises jobs, so one running action locks the rest.
  const locked = job?.state === "running"

  const refreshAll = () => {
    void services.refresh()
    void state.refresh()
    void storage.refresh()
    void ports.refresh()
    void catalogue.refresh()
    void overview.refresh()
  }

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
            <Button size="icon" variant="ghost" onClick={refreshAll} aria-label="Refresh">
              <RefreshCwIcon />
            </Button>
            <Button size="icon" variant="ghost" onClick={toggleTheme} aria-label="Toggle theme">
              {dark ? <SunIcon /> : <MoonIcon />}
            </Button>
            {me?.auth_enabled && (
              <>
                <span className="text-muted-foreground hidden text-xs sm:inline">
                  {me.display_name || me.username}
                </span>
                <Button
                  size="icon"
                  variant="ghost"
                  aria-label="Sign out"
                  title="Sign out"
                  onClick={async () => {
                    try {
                      await auth.logout()
                    } finally {
                      // Refresh either way. A logout call that failed to
                      // reach the server still has to be reflected here, or
                      // the page claims a session it may not have.
                      refreshMe()
                    }
                  }}
                >
                  <LogOutIcon />
                </Button>
              </>
            )}
          </div>
        </div>
      </header>

      <main className="mx-auto flex max-w-7xl flex-col gap-4 p-4">
        {state.data && !state.data.agent_ok && (
          <Card className="border-destructive/50">
            <CardContent className="flex items-start gap-2 text-sm">
              <AlertTriangleIcon className="text-destructive mt-0.5 size-4 shrink-0" />
              <div>
                <p className="font-medium">
                  The action agent is unreachable, so no button here can work.
                </p>
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
          <TabsList className="flex-wrap">
            {tabs.map(({ id, label, icon: Icon }) => (
              <TabsTrigger key={id} value={id}>
                <Icon />
                {label}
              </TabsTrigger>
            ))}
          </TabsList>

          <TabsContent value="overview">
            <OverviewTab
              data={overview.data as Overview | null}
              loading={overview.loading}
              error={overview.error}
            />
          </TabsContent>
          <TabsContent value="services">
            <ServicesTab
              services={svcList}
              loading={services.loading}
              busy={busy}
              locked={locked}
              onAction={runService}
              onLogs={(svc) => setLogs({ container: svc.container, label: svc.label })}
            />
          </TabsContent>
          <TabsContent value="health">
            <HealthTab
              metrics={overview.data?.metrics ?? null}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runBox}
            />
          </TabsContent>
          <TabsContent value="storage">
            <StorageTab
              metrics={overview.data?.metrics ?? null}
              raw={storage.data?.output ?? ""}
              loading={overview.loading}
              error={storage.error}
              busy={!!runningAction?.startsWith("cleanup")}
              locked={locked}
              onCleanup={(dryRun) => runBox(dryRun ? "cleanup-preview" : "cleanup")}
            />
          </TabsContent>
          <TabsContent value="network">
            <NetworkTab
              services={svcList}
              state={state.data}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runBox}
            />
          </TabsContent>
          <TabsContent value="catalogue">
            <CatalogueTab entries={catalogue.data ?? []} loading={catalogue.loading} />
          </TabsContent>
          <TabsContent value="account">
            <AccountTab me={me} refresh={refreshMe} />
          </TabsContent>
          <TabsContent value="system">
            <SystemTab
              state={state.data}
              ports={ports.data ?? []}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onUpdateAll={() => runBox("update-all")}
            />
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
