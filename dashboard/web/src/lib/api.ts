// The dashboard's whole contract with the Go server. Every action goes to the
// privileged agent through it; nothing here can do more than the agent's own
// whitelist allows, which is why none of these are destructive.

export type ServiceStatus = "HEALTHY" | "UNHEALTHY" | "MISSING" | "DISABLED" | "UNKNOWN"

export type Service = {
  name: string
  label: string
  status: ServiceStatus
  urls: string[]
  container: string
  enabled: boolean
}

export type State = {
  version: string
  domain: string
  server_ip: string
  ssh_port: string
  hostname: string
  kernel: string
  uptime: string
  docker: string
  timezone: string
  // False when the unix socket is unreachable, which is the difference
  // between "the button failed" and "the buttons cannot work at all".
  agent_ok: boolean
  agent_error: string
}

export type ServiceAction = "start" | "stop" | "restart" | "repair" | "update"

export type Job = {
  id: string
  state: "running" | "done" | "failed"
  label: string
  output: string
}

export type Port = { service: string; url: string; note: string }

export type CatalogueEntry = {
  name: string
  label: string
  category: string
  description: string
  ram_mb: number
  disk_gb: number
  needs_domain: boolean
  installed: boolean
  enabled: boolean
  // Where it answers, or would answer once installed. "Needs a domain" was
  // not something a reader could act on; the hostname is.
  urls: string[]
}

// Box-wide actions, as opposed to the per-service ones. The names match the
// agent's whitelist, and the agent checks them again on its side.
export type RunAction = "health" | "watchdog" | "network-check" | "route-list" | "doctor"

// Fired whenever the server says the session is gone, so the app can drop
// straight back to the login form instead of showing a page whose every panel
// has quietly failed. Any request can be the one that discovers it: a session
// expires mid-poll, and `dashboard-user passwd` from SSH revokes it outright.
export const UNAUTHENTICATED_EVENT = "corex-unauthenticated"

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    // Cookies are same-origin here anyway, but a session that silently fails
    // to travel is the kind of bug that looks like a wrong password.
    credentials: "same-origin",
    headers: { Accept: "application/json", ...(init?.headers || {}) },
  })
  if (res.status === 401 && !path.startsWith("/api/auth/")) {
    window.dispatchEvent(new CustomEvent(UNAUTHENTICATED_EVENT))
  }
  const text = await res.text()
  let body: unknown = null
  if (text) {
    try {
      body = JSON.parse(text)
    } catch {
      // A non-JSON body from an admin endpoint is nearly always the reverse
      // proxy or the auth layer answering instead of the app. Say that rather
      // than "Unexpected token <".
      throw new Error(`${res.status} ${res.statusText}: ${text.slice(0, 200)}`)
    }
  }
  if (!res.ok) {
    const msg = (body as { error?: string })?.error
    if (
      res.status === 403 &&
      (body as { elevation_required?: boolean })?.elevation_required
    ) {
      throw new ElevationRequired(msg || "confirm who you are to continue")
    }
    throw new Error(msg || `${res.status} ${res.statusText}`)
  }
  return body as T
}

/**
 * The server refused because the session has not confirmed itself recently.
 *
 * It is a distinct type because a caller has to be able to tell it from a
 * plain refusal: this one is answered by asking the operator for a factor and
 * retrying, and any other 403 is not. A flag on the response body carries it,
 * since the status code alone cannot say which kind of no this is.
 */
export class ElevationRequired extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ElevationRequired"
  }
}

function post<T>(path: string, body: unknown): Promise<T> {
  return req<T>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  })
}

// Who is signed in, and whether a login is being enforced at all.
//
// auth_enabled is false until the first account exists, which is how an
// upgrade lands without locking anyone out: Traefik basic auth stays in front
// until `corex manage dashboard-user enable-auth` takes it away.
export type Me = {
  auth_enabled: boolean
  authenticated: boolean
  // A correct password given, a second factor still owed.
  awaiting_totp: boolean
  username: string
  display_name: string
  email: string
  totp_enabled: boolean
  recovery_left: number
  passkeys: number
  // Seconds left on a step-up, and which factor granted it. Zero means the
  // next protected action will ask.
  elevated_for: number
  elevated_by: string
}

export type Elevation = {
  ok: boolean
  elevated_for: number
  elevated_by: string
}

export type SessionView = {
  id: string
  current: boolean
  ip: string
  user_agent: string
  created: string
  last_seen: string
  awaiting_totp: boolean
}

export type Passkey = {
  id: string
  name: string
  added: number
  last_used: number
}

export type ActivityRow = {
  t: number
  event: string
  user: string
  ip: string
  ua: string
  detail: string
}

export const auth = {
  me: () => req<Me>("/api/auth/me"),
  login: (username: string, password: string) =>
    post<{ ok: boolean; awaiting_totp: boolean; display_name: string }>(
      "/api/auth/login",
      { username, password }
    ),
  totp: (code: string) =>
    post<{ ok: boolean; used_recovery?: boolean; recovery_left?: number }>(
      "/api/auth/totp",
      { code }
    ),
  logout: () => post<{ ok: boolean }>("/api/auth/logout", {}),
  changePassword: (current: string, next: string) =>
    post<{ ok: boolean }>("/api/auth/password", { current, new: next }),
  saveProfile: (display_name: string, email: string) =>
    post<{ ok: boolean; display_name: string; email: string }>("/api/auth/profile", {
      display_name,
      email,
    }),
  totpBegin: () => post<{ secret: string; uri: string }>("/api/auth/totp/begin", {}),
  totpEnable: (code: string) =>
    post<{ ok: boolean; recovery_codes: string[] }>("/api/auth/totp/enable", { code }),
  totpDisable: (password: string) =>
    post<{ ok: boolean }>("/api/auth/totp/disable", { password }),
  resetRequest: (username: string) =>
    post<{ ok: boolean }>("/api/auth/reset/request", { username }),
  resetComplete: (username: string, code: string, password: string) =>
    post<{ ok: boolean }>("/api/auth/reset/complete", { username, code, password }),
  sessions: () => req<SessionView[]>("/api/auth/sessions"),
  passkeys: () =>
    req<{ passkeys: Passkey[]; rp_id: string; origin: string; available: boolean }>(
      "/api/auth/passkey/list"
    ),
  passkeyBegin: () =>
    post<{ ceremony: string; options: PublicKeyCredentialCreationOptions }>(
      "/api/auth/passkey/begin",
      {}
    ),
  passkeyFinish: (ceremony: string, name: string, response: unknown) =>
    post<{ ok: boolean; id: string; name: string }>("/api/auth/passkey/finish", {
      ceremony,
      name,
      response,
    }),
  passkeyDelete: (id: string) => post<{ ok: boolean }>("/api/auth/passkey/delete", { id }),
  passkeyLoginBegin: () =>
    post<{ ceremony: string; options: PublicKeyCredentialRequestOptions }>(
      "/api/auth/passkey/login/begin",
      {}
    ),
  passkeyLoginFinish: (ceremony: string, response: unknown) =>
    post<{ ok: boolean; display_name: string }>("/api/auth/passkey/login/finish", {
      ceremony,
      response,
    }),
  revoke: (opts: { id?: string; others?: boolean }) =>
    post<{ ok: boolean; dropped: number }>("/api/auth/sessions/revoke", opts),
  activity: () => req<ActivityRow[]>("/api/auth/activity"),
  stepup: (body: { password?: string; code?: string }) =>
    post<Elevation>("/api/auth/stepup", body),
  stepupPasskeyBegin: () =>
    post<{ ceremony: string; options: unknown }>(
      "/api/auth/stepup/passkey/begin",
      {}
    ),
  stepupPasskeyFinish: (ceremony: string, response: unknown) =>
    post<Elevation>("/api/auth/stepup/passkey/finish", { ceremony, response }),
}


// ── The overview payload ─────────────────────────────────────────────────────
//
// Everything on this page is a number, not terminal output. The rest of the
// dashboard shows a command's own output deliberately, because those commands
// are the source of truth; that argument does not apply to a temperature or a
// disk percentage, which are better seen than read.

export type Sample = {
  t: string
  temp: number
  load: number
  mem_used_mb: number
  mem_total_mb: number
  swap_used_mb: number
  throttled: boolean
  containers: number
}

export type Disk = {
  path: string
  label: string
  used_b: number
  total_b: number
  free_b: number
  pct: number
}

export type DockerUsage = {
  count: number
  active: number
  size: string
  reclaimable: string
  size_b: number
  reclaimable_b: number
}

export type Monitor = {
  name: string
  active: boolean
  type: string
  status: "up" | "down" | "pending" | "maintenance" | "unknown"
  last_check: string
  message: string
  ping_ms: number | null
}

export type Finding = { t: string; level: "down" | "up" | "info"; text: string }

export type Metrics = {
  at: number
  cpu: {
    temp_c: number | null
    temp_source: string
    temp_state: "ok" | "warn" | "hot" | "unknown"
    load: number[]
    cores: number
  }
  memory: {
    used_mb?: number
    total_mb?: number
    swap_used_mb?: number
    swap_total_mb?: number
  }
  uptime_s: number | null
  disks: Disk[]
  docker: Record<string, DockerUsage> | null
  service_sizes: { name: string; bytes: number }[]
  series: Sample[]
  watchdog: Finding[]
  thermal: {
    enabled: boolean
    warn_c: number | null
    shed_c: number | null
    emergency_c: number | null
    shed: string[]
  }
  monitors: Monitor[]
  smart: { device: string; status: string }[]
  dpkg: { clean: boolean; packages: string[] } | null
  // Read with ethtool on the privileged side. An array, never null, so the
  // client can map over it without a guard (gotcha #37).
  wol: WakeOnLan[]
  maintenance: Maintenance | null
  // null on the fast vitals stream, which does not carry it.
  updates: Updates | null
}

/**
 * Whether an update is actually waiting, per service.
 *
 * "unknown" is a real answer and is shown as one. A registry that could not be
 * reached must not read as either good or bad news, and hiding the Update
 * button on a failed lookup would take a working button away over a network
 * blip.
 */
export type UpdateState = "update" | "stale-tag" | "unknown" | "current" | "pinned"

export type ImageUpdate = {
  image: string
  state: UpdateState
  note: string
  age_days?: number
}

export type ServiceUpdate = {
  service: string
  state: UpdateState
  note: string
  images: ImageUpdate[]
}

export type Updates = {
  checked_at: number
  checking: boolean
  services: Record<string, ServiceUpdate>
}

export type MaintenanceTask = {
  name: MaintenanceTaskName
  label: string
  description: string
  enabled: boolean
  interval_h: number
  hour: number
  // Unix seconds, 0 when it has never run. The page has to say "never" rather
  // than draw a tick for something that has not happened.
  last: number
  next: number
  state: "ok" | "failed" | ""
  elapsed: number
  detail: string
  // A refusal to start is not a run, so it is recorded separately and does not
  // reset the clock. Newer than `last` means the last thing that happened was
  // being declined, usually for temperature.
  deferred_at: number
  deferred_detail: string
}

export type MaintenanceTaskName = "backup" | "cleanup" | "timemachine" | "os-upgrade"

export type Maintenance = {
  installed: boolean
  timer_active: boolean
  enabled: boolean
  tasks: MaintenanceTask[]
}

export type WakeOnLan = {
  interface: string
  supported: boolean
  enabled: boolean
  modes: string
}

export type ContainerRow = {
  name: string
  service: string
  status: string
  health: string
  cpu_percent: number
  mem_bytes: number
  mem_limit: number
  mem_percent: number
  restarts: number
  oom_killed: boolean
  since: string
}

export type Vitals = {
  at: number
  temp_c: number | null
  temp_state: "ok" | "warn" | "hot" | "unknown"
  load: number[]
  cores: number
  mem_used_mb: number
  mem_total_mb: number
  swap_used_mb: number
  containers_running: number
  containers_total: number
  containers_restarting: number
  top: ContainerRow[]
  agent_ok: boolean
}

export type Overview = {
  metrics: Metrics | null
  services: { healthy: number; unhealthy: number; stopped: number; missing: number }
  containers: { running: number; total: number; restarting: number; unhealthy: number }
  top: ContainerRow[]
  agent_ok: boolean
  agent_error: string
  collected_at: string
}

export type PowerMode = "reboot" | "shutdown"

export const api = {
  state: () => req<State>("/api/state"),
  services: () => req<Service[]>("/api/services"),
  storage: () => req<{ output: string }>("/api/storage"),
  ports: () => req<Port[]>("/api/ports"),
  catalogue: () => req<CatalogueEntry[]>("/api/catalogue"),
  overview: () => req<Overview>("/api/overview"),
  containers: () => req<ContainerRow[]>("/api/containers"),
  run: (action: RunAction) => req<Job>(`/api/run/${action}`, { method: "POST" }),
  updateAll: () => req<Job>("/api/update-all", { method: "POST" }),
  act: (service: string, action: ServiceAction) =>
    req<Job>(`/api/service/${encodeURIComponent(service)}/${action}`, { method: "POST" }),
  job: (id: string) => req<Job>(`/api/job/${encodeURIComponent(id)}`),
  cleanup: (dryRun: boolean) =>
    req<Job>(`/api/cleanup${dryRun ? "?dry_run=1" : ""}`, { method: "POST" }),
  // Behind a step-up confirmation on the server, so the first call of a
  // session throws ElevationRequired and is retried after a factor.
  power: (mode: PowerMode) => req<Job>(`/api/power/${mode}`, { method: "POST" }),
  // os-upgrade is the one behind a step-up, so this can throw
  // ElevationRequired for that task alone.
  maintenance: (task: MaintenanceTaskName) =>
    req<Job>(`/api/maintenance/${task}`, { method: "POST" }),
  logsURL: (container: string) => `/api/logs/${encodeURIComponent(container)}`,
  vitalsStreamURL: "/api/stream/vitals",
}
