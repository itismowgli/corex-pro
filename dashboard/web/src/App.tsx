import * as React from "react"
import {
  AlertTriangleIcon,
  ChevronDownIcon,
  GaugeIcon,
  HardDriveIcon,
  HeartPulseIcon,
  LayoutGridIcon,
  CalendarClockIcon,
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
import { ConsumersDialog, type Consumer } from "@/components/consumers-dialog"
import { LoginScreen } from "@/components/login-screen"
import { LogsDialog } from "@/components/logs-dialog"
import { NetworkTab } from "@/components/network-tab"
import { ServicesTab } from "@/components/services-tab"
import { StorageTab } from "@/components/storage-tab"
import { MaintenanceTab } from "@/components/maintenance-tab"
import { useStepup } from "@/components/stepup-dialog"
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
  type MaintenanceTaskName,
  type Overview,
  type Me,
  type PowerMode,
  type RunAction,
  type Service,
  type ServiceAction,
  type Vitals,
} from "@/lib/api"
import { usePoll } from "@/lib/use-poll"
import { useStream } from "@/lib/use-stream"

const TABS = [
  { id: "overview", label: "Overview", icon: GaugeIcon },
  { id: "services", label: "Services", icon: ServerIcon },
  { id: "health", label: "Health", icon: HeartPulseIcon },
  { id: "storage", label: "Storage", icon: HardDriveIcon },
  { id: "network", label: "Network", icon: NetworkIcon },
  { id: "catalogue", label: "Catalogue", icon: LayoutGridIcon },
  { id: "maintenance", label: "Maintenance", icon: CalendarClockIcon },
  { id: "system", label: "System", icon: MonitorIcon },
]

// Actions whose full output is rendered by the tab that asked for them. The
// strip shows only the outcome for these, or the same report fills the screen
// twice.
const OUTPUT_HAS_A_HOME = [
  "health",
  "watchdog",
  "doctor",
  "network-check",
  "route-list",
  "update-all",
  "cleanup",
  "cleanup-preview",
  "backup",
  "timemachine",
  "os-upgrade",
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
  // Which panel owns the current job's output. Separate from runningAction,
  // which is cleared the instant the job finishes: reading it to decide
  // whether the output already has a home meant the answer was always "no" by
  // the time there was any output to place, and the report appeared twice.
  const [jobOwner, setJobOwner] = React.useState<string | null>(null)
  // Command output kept per action, so switching tabs does not throw away the
  // health report you just ran.
  const [outputs, setOutputs] = React.useState<Record<string, string>>({})
  const [logs, setLogs] = React.useState<{ container: string; label: string } | null>(null)
  const [drill, setDrill] = React.useState<Consumer | null>(null)
  const [powerBusy, setPowerBusy] = React.useState<PowerMode | null>(null)
  // A step-up confirmation, shared by anything the server guards. guard()
  // runs the action, and if the server asks for a factor it collects one and
  // runs the same action again.
  const { guard, dialog: stepupDialog } = useStepup(me)

  const state = usePoll(api.state, 30_000)
  // 15s while idle. An action refreshes it immediately when the job ends, so a
  // badge is never more than a moment behind what the box is doing.
  const services = usePoll(api.services, 15_000)
  // Held back until the Storage tab is opened. This one shells out to
  // `corex manage storage`, which walks /var/lib/docker and every service
  // directory: 26.7 seconds measured on this box, fired on every page load by
  // every visitor whether or not they ever looked at Storage.
  const storage = usePoll(api.storage, 0, tab === "storage")
  // 20s, matching the blackbox sampler: polling faster shows the same numbers
  // twice, and this call walks both disks and Kuma's database.
  // The heavy half: both disks, Kuma's database and a cached `du`. Every 45
  // seconds is plenty for numbers that move that slowly.
  const overview = usePoll(api.overview, 45_000)
  // The light half, pushed every five seconds so the tiles move on their own.
  const vitals = useStream<Vitals>(api.vitalsStreamURL)
  const ports = usePoll(api.ports, 0, tab === "system" || tab === "network")
  const catalogue = usePoll(api.catalogue, 0, tab === "catalogue")

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
    setJobOwner(null)
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

  // One scheduled task, now. Its output lands in the Maintenance tab, which
  // is where the schedule and the last outcome already are.
  const runMaintenance = (task: MaintenanceTaskName) => {
    setRunningAction(task)
    setJobOwner(task)
    setJob({ id: "", state: "running", label: task, output: "" })
    // os-upgrade is the only one the server guards, so guard() is a no-op for
    // the other three and prompts for exactly the one that needs it.
    void guard(`Upgrading the operating system packages`, async () => {
      setJob(await api.maintenance(task))
    }).catch((e) => fail(task, e))
  }

  // Rebooting or shutting the machine down. The job panel carries the reply,
  // and for a reboot the next poll failing is the machine actually going, so
  // nothing here tries to hide that.
  const runPower = (mode: PowerMode) => {
    setJobOwner(null)
    void guard(mode === "shutdown" ? "Shutting the machine down" : "Rebooting the machine", async () => {
      setPowerBusy(mode)
      setJob({ id: "", state: "running", label: mode, output: "" })
      try {
        setJob(await api.power(mode))
      } catch (e) {
        setPowerBusy(null)
        throw e
      }
    }).catch((e) => {
      setPowerBusy(null)
      fail(mode, e)
    })
  }

  // Box-wide commands: health, watchdog, network-check, route-list, doctor,
  // cleanup and update-all. Their output lands in the panel that asked.
  const runBox = async (action: string) => {
    setRunningAction(action)
    setJobOwner(action)
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
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 sm:px-4 sm:py-3">
          <span className="text-base font-semibold tracking-tight">
            CoreX <span className="text-muted-foreground font-normal">Pro</span>
          </span>
          {state.data?.domain && (
            <span className="text-muted-foreground hidden font-mono text-xs sm:inline">
              {state.data.domain}
            </span>
          )}
          <div className="ml-auto flex items-center gap-2">
            {svcList.length > 0 && (
              <>
                <Badge variant="ok">{counts.healthy}</Badge>
                {counts.unhealthy > 0 && (
                  <Badge variant="destructive">{counts.unhealthy}</Badge>
                )}
                {counts.other > 0 && <Badge variant="secondary">{counts.other}</Badge>}
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

      <main className="mx-auto flex w-full max-w-7xl flex-col gap-3 p-3 sm:gap-4 sm:p-4">
        <Tabs value={tab} onValueChange={setTab}>
          {/* A dropdown on a phone and a row of tabs above it. Eight tabs in a
              scrolling strip means the one you want is usually off screen with
              nothing to say so; a select shows all eight at once and is the
              control the operating system already knows how to draw. */}
          <div className="sm:hidden">
            <label htmlFor="tab-select" className="sr-only">
              Choose a section
            </label>
            <div className="relative">
              <select
                id="tab-select"
                value={tab}
                onChange={(e) => setTab(e.target.value)}
                className="border-input bg-card focus-visible:border-ring focus-visible:ring-ring/50 h-10 w-full appearance-none rounded-md border px-3 pr-9 text-sm focus-visible:ring-[3px] focus-visible:outline-none"
              >
                {tabs.map(({ id, label }) => (
                  <option key={id} value={id}>
                    {label}
                  </option>
                ))}
              </select>
              <ChevronDownIcon className="text-muted-foreground pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2" />
            </div>
          </div>

          <TabsList className="hidden flex-wrap sm:flex">
            {tabs.map(({ id, label, icon: Icon }) => (
              <TabsTrigger key={id} value={id}>
                <Icon />
                {label}
              </TabsTrigger>
            ))}
          </TabsList>

          {/* Everything that used to sit above the tab bar now sits under it.
              A banner or a running job pushed the tabs down the screen, which
              on a phone meant opening the dashboard and seeing no dashboard. */}
          <div className="mt-3 flex flex-col gap-3 empty:hidden">
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
                      <code className="text-foreground">sudo corex manage agent test</code>, which
                      also reports whether this container can see the socket.
                    </p>
                  </div>
                </CardContent>
              </Card>
            )}

            {(services.error || state.error) && (
              <Card className="border-destructive/50">
                <CardContent className="text-sm">
                  <p className="font-medium">Could not load the dashboard data.</p>
                  <p className="text-muted-foreground mt-1 font-mono text-xs break-all">
                    {services.error || state.error}
                  </p>
                </CardContent>
              </Card>
            )}

            <JobPanel
              job={job}
              setJob={(j) => {
                setJob(j)
                if (!j) setJobOwner(null)
              }}
              onFinished={onJobFinished}
              hasHome={!!jobOwner && OUTPUT_HAS_A_HOME.includes(jobOwner)}
            />
          </div>

          <TabsContent value="overview">
            <OverviewTab
              data={overview.data as Overview | null}
              vitals={vitals.data}
              live={vitals.live}
              loading={overview.loading}
              error={overview.error}
              onDrill={setDrill}
            />
          </TabsContent>
          <TabsContent value="services">
            <ServicesTab
              services={svcList}
              updates={overview.data?.metrics?.updates ?? null}
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
          <TabsContent value="maintenance">
            <MaintenanceTab
              data={overview.data?.metrics?.maintenance ?? null}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runMaintenance}
            />
          </TabsContent>
          <TabsContent value="system">
            <SystemTab
              state={state.data}
              ports={ports.data ?? []}
              metrics={overview.data?.metrics ?? null}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              powerBusy={powerBusy}
              onUpdateAll={() => runBox("update-all")}
              onPower={runPower}
            />
          </TabsContent>
        </Tabs>

        <footer className="text-muted-foreground pb-6 text-center text-xs">
          {state.data?.version && <>CoreX Pro v{state.data.version} · </>}
          {state.data?.server_ip}
        </footer>
      </main>

      <ConsumersDialog
        mode={drill}
        metrics={overview.data?.metrics ?? null}
        onClose={() => setDrill(null)}
      />

      <LogsDialog
        container={logs?.container ?? null}
        label={logs?.label ?? ""}
        onClose={() => setLogs(null)}
      />

      {stepupDialog}
    </div>
  )
}
