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
    throw new Error(msg || `${res.status} ${res.statusText}`)
  }
  return body as T
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

export type Overview = {
  metrics: Metrics | null
  services: { healthy: number; unhealthy: number; stopped: number; missing: number }
  containers: { running: number; total: number; restarting: number; unhealthy: number }
  top: ContainerRow[]
  agent_ok: boolean
  agent_error: string
  collected_at: string
}

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
  logsURL: (container: string) => `/api/logs/${encodeURIComponent(container)}`,
}
