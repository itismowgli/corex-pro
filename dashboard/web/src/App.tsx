import * as React from "react"
import {
  AlertTriangleIcon,
  ExternalLinkIcon,
  LogOutIcon,
  MenuIcon,
  MoonIcon,
  PlayIcon,
  RefreshCwIcon,
  RotateCwIcon,
  ScrollTextIcon,
  SearchIcon,
  SunIcon,
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
import { Sheet, SheetContent } from "@/components/ui/sheet"
import { SidebarBody } from "@/components/app-sidebar"
import { CommandPalette, usePaletteHotkey, type PaletteItem } from "@/components/command-palette"
import { navItems, navLabel } from "@/lib/nav"
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

// The sidebar's collapsed state, remembered the same way and guarded the same
// way: a read that throws inside a useState initialiser blanks the page, and
// a remembered rail is not worth that.
function readCollapsed(): boolean {
  try {
    return localStorage.getItem("corex-sidebar") === "collapsed"
  } catch {
    return false
  }
}

function useSidebar() {
  const [collapsed, setCollapsed] = React.useState(readCollapsed)
  React.useEffect(() => {
    try {
      localStorage.setItem("corex-sidebar", collapsed ? "collapsed" : "open")
    } catch {
      // A browser with site data blocked still gets a working page.
    }
  }, [collapsed])
  return { collapsed, toggle: () => setCollapsed((c) => !c) }
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

  const { collapsed, toggle: toggleCollapsed } = useSidebar()
  // The drawer on a phone, and the palette on every screen.
  const [navOpen, setNavOpen] = React.useState(false)
  const [paletteOpen, setPaletteOpen] = React.useState(false)
  usePaletteHotkey(setPaletteOpen)

  // Choosing a section always closes the drawer. Leaving it open over the
  // page you just asked for is the one thing a drawer must not do.
  const go = React.useCallback((id: string) => {
    setTab(id)
    setNavOpen(false)
  }, [])

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

  // Refresh either way. A logout call that failed to reach the server still
  // has to be reflected here, or the page claims a session it may not have.
  const signOut = async () => {
    try {
      await auth.logout()
    } finally {
      refreshMe()
    }
  }

  // Everything the palette can reach, assembled here because this is where
  // the handlers already live. A palette that defines its own actions is a
  // second place for an action to be wrong.
  const paletteItems: PaletteItem[] = React.useMemo(() => {
    const sections: PaletteItem[] = navItems(me?.auth_enabled).map((i) => ({
      id: `go:${i.id}`,
      group: "Go to",
      label: i.label,
      hint: i.hint,
      icon: i.icon,
      run: () => go(i.id),
    }))

    const commands: PaletteItem[] = [
      { id: "run:health", label: "Run the hardware health report", to: "health", action: "health" },
      { id: "run:watchdog", label: "Run the resource watchdog", to: "health", action: "watchdog" },
      { id: "run:doctor", label: "Run the doctor", to: "health", action: "doctor" },
      { id: "run:network-check", label: "Check the network and certificates", to: "network", action: "network-check" },
      { id: "run:route-list", label: "List the Traefik routes", to: "network", action: "route-list" },
      { id: "run:cleanup-preview", label: "Preview what a cleanup would reclaim", to: "storage", action: "cleanup-preview" },
      { id: "run:update-all", label: "Update every service", to: "system", action: "update-all" },
    ].map((c) => ({
      id: c.id,
      group: "Run",
      label: c.label,
      icon: PlayIcon,
      keywords: c.action,
      disabled: locked,
      run: () => {
        go(c.to)
        void runBox(c.action)
      },
    }))

    const svcActions: PaletteItem[] = svcList.flatMap((svc) => [
      {
        id: `restart:${svc.name}`,
        group: "Services",
        label: `Restart ${svc.label}`,
        icon: RotateCwIcon,
        keywords: `${svc.name} ${svc.container}`,
        disabled: locked || !svc.enabled,
        run: () => void runService(svc, "restart"),
      },
      {
        id: `logs:${svc.name}`,
        group: "Services",
        label: `Logs for ${svc.label}`,
        icon: ScrollTextIcon,
        keywords: `${svc.name} ${svc.container}`,
        run: () => setLogs({ container: svc.container, label: svc.label }),
      },
      ...(svc.urls ?? []).slice(0, 1).map((url) => ({
        id: `open:${svc.name}`,
        group: "Services",
        label: `Open ${svc.label}`,
        hint: url,
        icon: ExternalLinkIcon,
        keywords: `${svc.name} ${url}`,
        run: () => window.open(url, "_blank", "noopener"),
      })),
    ])

    const view: PaletteItem[] = [
      {
        id: "view:refresh",
        group: "This page",
        label: "Refresh everything",
        icon: RefreshCwIcon,
        run: refreshAll,
      },
      {
        id: "view:theme",
        group: "This page",
        label: dark ? "Switch to the light theme" : "Switch to the dark theme",
        icon: dark ? SunIcon : MoonIcon,
        run: toggleTheme,
      },
      ...(me?.auth_enabled
        ? [
            {
              id: "view:signout",
              group: "This page",
              label: "Sign out",
              icon: LogOutIcon,
              run: () => void signOut(),
            } as PaletteItem,
          ]
        : []),
    ]

    return [...sections, ...commands, ...svcActions, ...view]
  }, [me?.auth_enabled, svcList, locked, dark, go])

  const sidebar = (mobile: boolean) => (
    <SidebarBody
      tab={tab}
      onSelect={go}
      authEnabled={me?.auth_enabled}
      collapsed={mobile ? false : collapsed}
      onToggleCollapse={mobile ? undefined : toggleCollapsed}
      onOpenPalette={() => {
        setNavOpen(false)
        setPaletteOpen(true)
      }}
      version={state.data?.version}
      serverIp={state.data?.server_ip}
    />
  )

  return (
    <div className="min-h-screen">
      {/* The nav is a fixed column on a wide screen, so it cannot be scrolled
          away from and nothing rendered on the page can push it off. */}
      <aside
        data-nav="sidebar"
        className={`bg-card fixed inset-y-0 left-0 z-30 hidden border-r transition-[width] md:flex md:flex-col ${
          collapsed ? "md:w-16" : "md:w-60"
        }`}
      >
        {sidebar(false)}
      </aside>

      {/* The same body in a drawer on a phone. One list, two presentations:
          two lists drift, and the one that drifts is always the phone. */}
      <Sheet open={navOpen} onOpenChange={setNavOpen}>
        <SheetContent title="Sections">{sidebar(true)}</SheetContent>
      </Sheet>

      <div className={collapsed ? "md:pl-16" : "md:pl-60"}>
        <header className="bg-background/85 sticky top-0 z-20 border-b backdrop-blur">
          <div className="flex items-center gap-2 px-3 py-2.5 sm:px-5">
            <Button
              data-nav="mobile-trigger"
              size="icon"
              variant="ghost"
              className="md:hidden"
              onClick={() => setNavOpen(true)}
              aria-label="Open the sections menu"
            >
              <MenuIcon />
            </Button>
            <span className="text-base font-semibold tracking-tight md:hidden">
              CoreX <span className="text-muted-foreground font-normal">Pro</span>
            </span>
            <h1 className="hidden truncate text-base font-semibold tracking-tight md:block">
              {navLabel(tab, me?.auth_enabled)}
            </h1>
            {state.data?.domain && (
              <span className="text-muted-foreground hidden font-mono text-xs lg:inline">
                {state.data.domain}
              </span>
            )}

            <div className="ml-auto flex items-center gap-1">
              <Button
                size="icon"
                variant="ghost"
                className="md:hidden"
                onClick={() => setPaletteOpen(true)}
                aria-label="Search sections and services"
              >
                <SearchIcon />
              </Button>
              {svcList.length > 0 && (
                <div className="mr-1 hidden items-center gap-1.5 sm:flex">
                  <Badge variant="ok">{counts.healthy}</Badge>
                  {counts.unhealthy > 0 && (
                    <Badge variant="destructive">{counts.unhealthy}</Badge>
                  )}
                  {counts.other > 0 && <Badge variant="secondary">{counts.other}</Badge>}
                </div>
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
                    onClick={() => void signOut()}
                  >
                    <LogOutIcon />
                  </Button>
                </>
              )}
            </div>
          </div>
        </header>

        <main className="mx-auto flex w-full max-w-[90rem] flex-col gap-4 p-3 sm:p-5">
          {/* Banners and the running job sit under the header, never above the
              navigation. On a phone the nav is the menu button in that header,
              so nothing here can push the way out of a section off screen. */}
          <div className="flex flex-col gap-3 empty:hidden">
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

          {tab === "overview" && (
            <OverviewTab
              data={overview.data as Overview | null}
              vitals={vitals.data}
              live={vitals.live}
              loading={overview.loading}
              error={overview.error}
              onDrill={setDrill}
            />
          )}
          {tab === "services" && (
            <ServicesTab
              services={svcList}
              updates={overview.data?.metrics?.updates ?? null}
              loading={services.loading}
              busy={busy}
              locked={locked}
              onAction={runService}
              onLogs={(svc) => setLogs({ container: svc.container, label: svc.label })}
            />
          )}
          {tab === "health" && (
            <HealthTab
              metrics={overview.data?.metrics ?? null}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runBox}
            />
          )}
          {tab === "storage" && (
            <StorageTab
              metrics={overview.data?.metrics ?? null}
              raw={storage.data?.output ?? ""}
              loading={overview.loading}
              error={storage.error}
              busy={!!runningAction?.startsWith("cleanup")}
              locked={locked}
              onCleanup={(dryRun) => runBox(dryRun ? "cleanup-preview" : "cleanup")}
            />
          )}
          {tab === "network" && (
            <NetworkTab
              services={svcList}
              state={state.data}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runBox}
            />
          )}
          {tab === "catalogue" && (
            <CatalogueTab entries={catalogue.data ?? []} loading={catalogue.loading} />
          )}
          {tab === "maintenance" && (
            <MaintenanceTab
              data={overview.data?.metrics?.maintenance ?? null}
              outputs={outputs}
              running={runningAction}
              locked={locked}
              onRun={runMaintenance}
            />
          )}
          {tab === "system" && (
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
          )}
          {tab === "account" && <AccountTab me={me} refresh={refreshMe} />}

          {/* The wide layout carries these in the sidebar footer. A phone
              never sees that, so they are repeated once at the bottom. */}
          <footer className="text-muted-foreground pb-4 text-center text-xs md:hidden">
            {state.data?.version && <>CoreX Pro v{state.data.version} · </>}
            {state.data?.server_ip}
          </footer>
        </main>
      </div>

      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} items={paletteItems} />

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
