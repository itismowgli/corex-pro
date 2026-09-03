import * as React from "react"
import { QRCodeSVG } from "qrcode.react"
import {
  CheckIcon,
  LoaderCircleIcon,
  ShieldCheckIcon,
  ShieldOffIcon,
  TriangleAlertIcon,
} from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, Input } from "@/components/ui/input"
import { ActivityCard } from "@/components/activity-card"
import { PasskeyCard } from "@/components/passkey-card"
import { auth, type Me } from "@/lib/api"

// A small form wrapper: one busy flag, one error line, one confirmation. Every
// panel here is the same shape, and writing it three times is how two of them
// end up reporting failure differently from the third.
function useSubmit(onDone?: () => void) {
  const [busy, setBusy] = React.useState(false)
  const [problem, setProblem] = React.useState<string | null>(null)
  const [done, setDone] = React.useState<string | null>(null)

  const run = (fn: () => Promise<void>, message?: string) => async (e?: React.FormEvent) => {
    e?.preventDefault()
    setBusy(true)
    setProblem(null)
    setDone(null)
    try {
      await fn()
      if (message) setDone(message)
      onDone?.()
    } catch (err) {
      setProblem(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }
  return { busy, problem, done, run, setProblem, setDone }
}

function Status({ problem, done }: { problem: string | null; done: string | null }) {
  if (problem) {
    return (
      <p className="text-destructive text-xs" role="alert">
        {problem}
      </p>
    )
  }
  if (done) {
    return (
      <p className="text-ok flex items-center gap-1.5 text-xs">
        <CheckIcon className="size-3.5" />
        {done}
      </p>
    )
  }
  return null
}

function ProfileCard({ me, refresh }: { me: Me; refresh: () => void }) {
  const [name, setName] = React.useState(me.display_name)
  const [email, setEmail] = React.useState(me.email)
  const f = useSubmit(refresh)

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Your details</CardTitle>
      </CardHeader>
      <CardContent>
        <form
          className="grid max-w-md gap-4"
          onSubmit={f.run(async () => {
            await auth.saveProfile(name, email)
          }, "Saved.")}
        >
          <Field label="Display name" htmlFor="display-name">
            <Input id="display-name" value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <Field
            label="Recovery email"
            htmlFor="email"
            hint={
              <>
                Where a password reset code is sent, through this server's own relay at{" "}
                <code>/etc/corex/smtp.conf</code>. Leave it empty and the only way back in is
                SSH.
              </>
            }
          >
            <Input
              id="email"
              type="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </Field>
          <Status problem={f.problem} done={f.done} />
          <div>
            <Button type="submit" disabled={f.busy}>
              {f.busy && <LoaderCircleIcon className="animate-spin" />}
              Save
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

function PasswordCard({ refresh }: { refresh: () => void }) {
  const [current, setCurrent] = React.useState("")
  const [next, setNext] = React.useState("")
  const [again, setAgain] = React.useState("")
  const f = useSubmit(refresh)

  const mismatch = again.length > 0 && next !== again

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Password</CardTitle>
      </CardHeader>
      <CardContent>
        <form
          className="grid max-w-md gap-4"
          onSubmit={f.run(async () => {
            if (next !== again) throw new Error("the two new passwords do not match")
            await auth.changePassword(current, next)
            setCurrent("")
            setNext("")
            setAgain("")
          }, "Password changed. Your other sessions have been signed out.")}
        >
          <Field label="Current password" htmlFor="current-password">
            <Input
              id="current-password"
              type="password"
              autoComplete="current-password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
            />
          </Field>
          <Field label="New password" htmlFor="new-password" hint="At least 12 characters.">
            <Input
              id="new-password"
              type="password"
              autoComplete="new-password"
              value={next}
              onChange={(e) => setNext(e.target.value)}
            />
          </Field>
          <Field label="New password again" htmlFor="new-password-2">
            <Input
              id="new-password-2"
              type="password"
              autoComplete="new-password"
              aria-invalid={mismatch}
              value={again}
              onChange={(e) => setAgain(e.target.value)}
            />
          </Field>
          <Status problem={f.problem} done={f.done} />
          <div>
            <Button
              type="submit"
              disabled={f.busy || !current || next.length < 12 || mismatch}
            >
              {f.busy && <LoaderCircleIcon className="animate-spin" />}
              Change password
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

// Enrolment is deliberately two steps with a code in between. Turning
// two-factor on from a secret the phone never actually scanned is a lockout
// that only shows up at the next sign-in, by which time the QR code is gone.
function TOTPCard({ me, refresh }: { me: Me; refresh: () => void }) {
  const [enrolling, setEnrolling] = React.useState<{ secret: string; uri: string } | null>(null)
  const [code, setCode] = React.useState("")
  const [password, setPassword] = React.useState("")
  const [codes, setCodes] = React.useState<string[] | null>(null)
  const f = useSubmit(refresh)

  if (codes) {
    return (
      <Card className="border-ok/50">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <ShieldCheckIcon className="size-4" />
            Two-factor is on. Save these recovery codes.
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3">
          <p className="text-muted-foreground text-xs">
            Each one signs you in once if the phone is lost. This is the only time they are
            shown: they are hashed the moment they are stored, so nobody, including this
            server, can print them again.
          </p>
          <div className="bg-muted grid grid-cols-2 gap-1 rounded-md p-3 font-mono text-sm">
            {codes.map((c) => (
              <span key={c}>{c}</span>
            ))}
          </div>
          <div>
            <Button variant="outline" onClick={() => setCodes(null)}>
              I have saved them
            </Button>
          </div>
        </CardContent>
      </Card>
    )
  }

  if (me.totp_enabled) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <ShieldCheckIcon className="size-4" />
            Two-factor authentication is on
          </CardTitle>
        </CardHeader>
        <CardContent className="grid max-w-md gap-4">
          <p className="text-muted-foreground text-xs">
            {me.recovery_left} unused recovery code{me.recovery_left === 1 ? "" : "s"} left.
            {me.recovery_left <= 2 &&
              " Turn it off and on again to get a fresh set before you run out."}
          </p>
          <form
            className="grid gap-4"
            onSubmit={f.run(async () => {
              await auth.totpDisable(password)
              setPassword("")
            }, "Two-factor turned off.")}
          >
            <Field
              label="Password"
              htmlFor="totp-off-password"
              hint="Confirming the password stops a borrowed session from quietly removing the second factor."
            >
              <Input
                id="totp-off-password"
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </Field>
            <Status problem={f.problem} done={f.done} />
            <div>
              <Button type="submit" variant="outline" disabled={f.busy || !password}>
                {f.busy ? <LoaderCircleIcon className="animate-spin" /> : <ShieldOffIcon />}
                Turn off two-factor
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    )
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Two-factor authentication</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-4">
        {!enrolling && (
          <>
            <p className="text-muted-foreground max-w-lg text-xs">
              A six-digit code from an authenticator app, on top of the password. The QR code
              is rendered here in the page, with no request to anyone: this dashboard fetches
              nothing at runtime, which is the point of it working when the box is in trouble.
            </p>
            <Status problem={f.problem} done={f.done} />
            <div>
              <Button
                onClick={f.run(async () => {
                  setEnrolling(await auth.totpBegin())
                })}
                disabled={f.busy}
              >
                {f.busy && <LoaderCircleIcon className="animate-spin" />}
                Set it up
              </Button>
            </div>
          </>
        )}

        {enrolling && (
          <form
            className="grid gap-4"
            onSubmit={f.run(async () => {
              const res = await auth.totpEnable(code.trim())
              setCode("")
              setEnrolling(null)
              setCodes(res.recovery_codes)
            })}
          >
            <div className="flex flex-wrap items-start gap-6">
              <div className="rounded-md bg-white p-3">
                <QRCodeSVG value={enrolling.uri} size={168} level="M" />
              </div>
              <div className="grid max-w-xs gap-3">
                <p className="text-muted-foreground text-xs">
                  Scan it, or type the key in by hand:
                </p>
                <code className="bg-muted rounded-md p-2 font-mono text-xs break-all">
                  {enrolling.secret}
                </code>
                <Field
                  label="Code from the app"
                  htmlFor="totp-code"
                  hint="Nothing changes until this matches, so an abandoned setup cannot lock you out."
                >
                  <Input
                    id="totp-code"
                    autoComplete="one-time-code"
                    inputMode="numeric"
                    className="font-mono tracking-widest"
                    value={code}
                    onChange={(e) => setCode(e.target.value)}
                  />
                </Field>
              </div>
            </div>
            <Status problem={f.problem} done={f.done} />
            <div className="flex gap-2">
              <Button type="submit" disabled={f.busy || code.trim().length !== 6}>
                {f.busy && <LoaderCircleIcon className="animate-spin" />}
                Turn on two-factor
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setEnrolling(null)
                  setCode("")
                }}
              >
                Cancel
              </Button>
            </div>
          </form>
        )}
      </CardContent>
    </Card>
  )
}

export function AccountTab({ me, refresh }: { me: Me | null; refresh: () => void }) {
  if (!me?.auth_enabled) {
    return (
      <Card className="border-warn/50">
        <CardContent className="flex items-start gap-2 text-sm">
          <TriangleAlertIcon className="text-warn mt-0.5 size-4 shrink-0" />
          <div>
            <p className="font-medium">This dashboard has no accounts of its own.</p>
            <p className="text-muted-foreground mt-1 text-xs">
              It is behind Traefik basic auth, which cannot change its own password or
              recover one. Create the first account from SSH, then take basic auth away:
            </p>
            <pre className="text-foreground mt-2 text-xs">
              sudo corex manage dashboard-user add admin --email you@example.com{"\n"}
              sudo corex manage dashboard-user enable-auth
            </pre>
          </div>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="grid gap-4">
      <ProfileCard key={me.username + me.display_name + me.email} me={me} refresh={refresh} />
      <PasskeyCard refresh={refresh} />
      <PasswordCard refresh={refresh} />
      <TOTPCard me={me} refresh={refresh} />
      <ActivityCard onSignedOut={refresh} />
    </div>
  )
}
