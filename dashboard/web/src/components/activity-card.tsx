import * as React from "react"
import { LaptopIcon, LogOutIcon, ShieldAlertIcon } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { auth, type ActivityRow, type SessionView } from "@/lib/api"
import { ago } from "@/lib/format"

/**
 * Where this account has been signed in, and what has happened to it.
 *
 * The first sign that an account is not yours any more is a sign-in you do not
 * recognise, which is why a mail provider shows you this and why a control
 * panel that can stop every service on the box should too.
 *
 * The history comes from an append-only log on the privileged side. That
 * matters: a record of who signed in is worth something only if the thing
 * being audited cannot quietly edit it.
 */

// How each event reads, and how alarming it is. Anything absent renders as
// itself rather than being hidden, so a new event type on the server is never
// silently invisible here.
const EVENT: Record<string, { text: string; tone: "ok" | "warn" | "destructive" | "secondary" }> = {
  login: { text: "Signed in", tone: "ok" },
  "login-failed": { text: "Sign-in refused", tone: "warn" },
  "locked-out": { text: "Locked out after repeated failures", tone: "destructive" },
  logout: { text: "Signed out", tone: "secondary" },
  "session-revoked": { text: "Session signed out remotely", tone: "secondary" },
  "password-changed": { text: "Password changed", tone: "warn" },
  "password-reset": { text: "Password reset by emailed code", tone: "warn" },
  "reset-requested": { text: "Password reset requested", tone: "warn" },
  "totp-enabled": { text: "Two-factor turned on", tone: "ok" },
  "totp-disabled": { text: "Two-factor turned off", tone: "destructive" },
  "recovery-code-used": { text: "Recovery code used", tone: "warn" },
  "passkey-added": { text: "Passkey added", tone: "ok" },
  "passkey-removed": { text: "Passkey removed", tone: "warn" },
  "passkey-login": { text: "Signed in with a passkey", tone: "ok" },
  stepup: { text: "Confirmed identity for a protected action", tone: "ok" },
  "stepup-failed": { text: "Confirmation refused", tone: "warn" },
}

/** A user agent is unreadable. This says what it actually is. */
function device(ua: string): string {
  if (!ua) return "unknown device"
  const os = /Windows/i.test(ua)
    ? "Windows"
    : /iPhone|iPad|iOS/i.test(ua)
      ? "iOS"
      : /Android/i.test(ua)
        ? "Android"
        : /Mac OS X|Macintosh/i.test(ua)
          ? "macOS"
          : /Linux/i.test(ua)
            ? "Linux"
            : ""
  const browser = /Edg\//i.test(ua)
    ? "Edge"
    : /OPR\//i.test(ua)
      ? "Opera"
      : /Firefox\//i.test(ua)
        ? "Firefox"
        : /Chrome\//i.test(ua)
          ? "Chrome"
          : /Safari\//i.test(ua)
            ? "Safari"
            : /curl/i.test(ua)
              ? "curl"
              : ""
  const parts = [browser, os].filter(Boolean)
  return parts.length ? parts.join(" on ") : ua.slice(0, 40)
}

export function ActivityCard({ onSignedOut }: { onSignedOut: () => void }) {
  const [sessions, setSessions] = React.useState<SessionView[] | null>(null)
  const [rows, setRows] = React.useState<ActivityRow[] | null>(null)
  const [problem, setProblem] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)

  const load = React.useCallback(async () => {
    try {
      const [s, a] = await Promise.all([auth.sessions(), auth.activity()])
      setSessions(s)
      setRows(a)
      setProblem(null)
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e))
    }
  }, [])

  React.useEffect(() => {
    void load()
  }, [load])

  const revokeOthers = async () => {
    if (!window.confirm("Sign out every other device? This one stays signed in.")) return
    setBusy(true)
    try {
      await auth.revoke({ others: true })
      await load()
      onSignedOut()
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const others = (sessions ?? []).filter((s) => !s.current).length

  return (
    <div className="grid gap-4">
      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2 text-base">
            <LaptopIcon className="size-4" />
            Where you are signed in
            {others > 0 && (
              <Button
                size="xs"
                variant="outline"
                className="ml-auto"
                disabled={busy}
                onClick={revokeOthers}
              >
                <LogOutIcon />
                Sign out {others} other {others === 1 ? "device" : "devices"}
              </Button>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-1">
          {sessions === null ? (
            <p className="text-muted-foreground text-xs">Reading...</p>
          ) : sessions.length === 0 ? (
            <p className="text-muted-foreground text-xs">No sessions, which cannot be right.</p>
          ) : (
            sessions.map((s) => (
              <div
                key={s.id}
                className="flex flex-wrap items-start justify-between gap-x-2 gap-y-1 border-b py-2 text-sm last:border-0"
              >
                <span className="grid min-w-0 gap-0.5">
                  <span className="truncate">
                    {device(s.user_agent)}
                    {s.current && (
                      <Badge variant="ok" className="ml-2">
                        this device
                      </Badge>
                    )}
                    {s.awaiting_totp && (
                      <Badge variant="warn" className="ml-2">
                        second factor owed
                      </Badge>
                    )}
                  </span>
                  <span className="text-muted-foreground font-mono text-xs break-all">{s.ip}</span>
                </span>
                <span className="text-muted-foreground shrink-0 text-xs" title={s.last_seen}>
                  active {ago(s.last_seen)}
                </span>
              </div>
            ))
          )}
          <p className="text-muted-foreground mt-2 text-xs">
            Sessions live in the dashboard's memory, so restarting the container signs
            everyone out. That is the fastest way to take the account back if something looks
            wrong here.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <ShieldAlertIcon className="size-4" />
            Recent account activity
          </CardTitle>
        </CardHeader>
        <CardContent>
          {problem && (
            <p className="text-destructive text-xs" role="alert">
              {problem}
            </p>
          )}
          {rows === null ? (
            <p className="text-muted-foreground text-xs">Reading...</p>
          ) : rows.length === 0 ? (
            <p className="text-muted-foreground text-xs">
              Nothing recorded yet. This starts from the first sign-in after the access log
              was added.
            </p>
          ) : (
            <div className="max-h-[50vh] overflow-auto">
              {/* Four columns do not fit on a phone, and squeezing them makes
                  every one unreadable rather than one of them missing. Below
                  sm the same rows are stacked, which is the shape a narrow
                  screen can actually show. */}
              <div className="grid gap-2 sm:hidden">
                {rows.map((e, i) => {
                  const meta = EVENT[e.event] ?? { text: e.event, tone: "secondary" as const }
                  return (
                    <div key={`${e.t}-${i}`} className="grid gap-1 border-b pb-2 last:border-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge variant={meta.tone}>{meta.text}</Badge>
                        <span
                          className="text-muted-foreground text-xs"
                          title={new Date(e.t * 1000).toLocaleString()}
                        >
                          {ago(new Date(e.t * 1000).toISOString())}
                        </span>
                      </div>
                      {e.detail && (
                        <span className="text-muted-foreground text-xs">{e.detail}</span>
                      )}
                      <span className="text-muted-foreground text-xs">
                        {device(e.ua)}
                        {e.ip && (
                          <span className="font-mono break-all"> from {e.ip}</span>
                        )}
                      </span>
                    </div>
                  )
                })}
              </div>

              <div className="hidden w-full overflow-x-auto sm:block">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>What</TableHead>
                      <TableHead>From</TableHead>
                      <TableHead>Device</TableHead>
                      <TableHead className="text-right">When</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {rows.map((e, i) => {
                      const meta = EVENT[e.event] ?? { text: e.event, tone: "secondary" as const }
                      return (
                        <TableRow key={`${e.t}-${i}`}>
                          <TableCell>
                            <Badge variant={meta.tone}>{meta.text}</Badge>
                            {e.detail && (
                              <div className="text-muted-foreground mt-0.5 text-xs">
                                {e.detail}
                              </div>
                            )}
                          </TableCell>
                          <TableCell className="font-mono text-xs break-all">
                            {e.ip || "-"}
                          </TableCell>
                          <TableCell className="text-xs">{device(e.ua)}</TableCell>
                          <TableCell
                            className="text-muted-foreground text-right text-xs whitespace-nowrap"
                            title={new Date(e.t * 1000).toLocaleString()}
                          >
                            {ago(new Date(e.t * 1000).toISOString())}
                          </TableCell>
                        </TableRow>
                      )
                    })}
                  </TableBody>
                </Table>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
