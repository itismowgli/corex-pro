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
}

// Box-wide actions, as opposed to the per-service ones. The names match the
// agent's whitelist, and the agent checks them again on its side.
export type RunAction = "health" | "watchdog" | "network-check" | "route-list" | "doctor"

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: { Accept: "application/json", ...(init?.headers || {}) },
  })
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

export const api = {
  state: () => req<State>("/api/state"),
  services: () => req<Service[]>("/api/services"),
  storage: () => req<{ output: string }>("/api/storage"),
  ports: () => req<Port[]>("/api/ports"),
  catalogue: () => req<CatalogueEntry[]>("/api/catalogue"),
  run: (action: RunAction) => req<Job>(`/api/run/${action}`, { method: "POST" }),
  updateAll: () => req<Job>("/api/update-all", { method: "POST" }),
  act: (service: string, action: ServiceAction) =>
    req<Job>(`/api/service/${encodeURIComponent(service)}/${action}`, { method: "POST" }),
  job: (id: string) => req<Job>(`/api/job/${encodeURIComponent(id)}`),
  cleanup: (dryRun: boolean) =>
    req<Job>(`/api/cleanup${dryRun ? "?dry_run=1" : ""}`, { method: "POST" }),
  logsURL: (container: string) => `/api/logs/${encodeURIComponent(container)}`,
}
