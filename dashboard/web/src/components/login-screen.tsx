import * as React from "react"
import { AlertTriangleIcon, KeyRoundIcon, LoaderCircleIcon, ShieldIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, Input } from "@/components/ui/input"
import { auth, type Me } from "@/lib/api"

// The four things this screen can be showing. It is one screen rather than
// four routes because the dashboard is a single page behind one hostname and a
// half-completed login is state, not a place: refreshing the tab mid-way
// through a second factor should land you back at the password, which is
// exactly what re-reading /api/auth/me does.
type Stage = "password" | "totp" | "reset-request" | "reset-complete"

export function LoginScreen({
  me,
  error,
  onSignedIn,
}: {
  me: Me | null
  error: string | null
  onSignedIn: () => void
}) {
  const [stage, setStage] = React.useState<Stage>(me?.awaiting_totp ? "totp" : "password")
  const [username, setUsername] = React.useState("")
  const [password, setPassword] = React.useState("")
  const [code, setCode] = React.useState("")
  const [newPassword, setNewPassword] = React.useState("")
  const [busy, setBusy] = React.useState(false)
  const [problem, setProblem] = React.useState<string | null>(null)
  const [notice, setNotice] = React.useState<string | null>(null)

  // A session that reached the second factor and then reloaded arrives here
  // already half signed in, so the form has to follow the server rather than
  // start from the top.
  React.useEffect(() => {
    if (me?.awaiting_totp) setStage("totp")
  }, [me?.awaiting_totp])

  const attempt = async (fn: () => Promise<unknown>, after: () => void) => {
    setBusy(true)
    setProblem(null)
    try {
      await fn()
      after()
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const submitPassword = (e: React.FormEvent) => {
    e.preventDefault()
    void attempt(
      async () => {
        const res = await auth.login(username.trim(), password)
        setPassword("")
        if (res.awaiting_totp) setStage("totp")
        else onSignedIn()
      },
      () => {}
    )
  }

  const submitTOTP = (e: React.FormEvent) => {
    e.preventDefault()
    void attempt(
      async () => {
        const res = await auth.totp(code.trim())
        setCode("")
        if (res.used_recovery) {
          setNotice(
            `Signed in with a recovery code. ${res.recovery_left ?? 0} left; ` +
              `turn two-factor off and on again in the Account tab to get a new set.`
          )
        }
        onSignedIn()
      },
      () => {}
    )
  }

  const submitResetRequest = (e: React.FormEvent) => {
    e.preventDefault()
    void attempt(
      async () => {
        await auth.resetRequest(username.trim())
        // Deliberately the same message whatever happened. The server answers
        // identically for an account that does not exist, so promising here
        // that mail is on its way would give away more than the server does.
        setNotice(
          "If that account exists and has an address on file, a code is on its way. " +
            "It expires in 15 minutes."
        )
        setStage("reset-complete")
      },
      () => {}
    )
  }

  const submitResetComplete = (e: React.FormEvent) => {
    e.preventDefault()
    void attempt(
      async () => {
        await auth.resetComplete(username.trim(), code.trim(), newPassword)
        setCode("")
        setNewPassword("")
        setNotice("Password changed. Sign in with it.")
        setStage("password")
      },
      () => {}
    )
  }

  const title =
    stage === "totp"
      ? "Two-factor code"
      : stage === "reset-request"
        ? "Forgotten password"
        : stage === "reset-complete"
          ? "Enter your reset code"
          : "Sign in"

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 text-center">
          <p className="text-lg font-semibold tracking-tight">
            CoreX <span className="text-muted-foreground font-normal">Pro</span>
          </p>
          <p className="text-muted-foreground text-xs">Homelab control panel</p>
        </div>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              {stage === "totp" ? <ShieldIcon className="size-4" /> : <KeyRoundIcon className="size-4" />}
              {title}
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            {error && (
              <p className="text-destructive flex items-start gap-2 text-xs">
                <AlertTriangleIcon className="mt-0.5 size-3.5 shrink-0" />
                <span>{error}</span>
              </p>
            )}
            {notice && <p className="text-muted-foreground text-xs">{notice}</p>}
            {problem && (
              <p className="text-destructive text-xs" role="alert">
                {problem}
              </p>
            )}

            {stage === "password" && (
              <form className="grid gap-4" onSubmit={submitPassword}>
                <Field label="Username" htmlFor="username">
                  <Input
                    id="username"
                    autoComplete="username"
                    autoFocus
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                  />
                </Field>
                <Field label="Password" htmlFor="password">
                  <Input
                    id="password"
                    type="password"
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy || !username || !password}>
                  {busy && <LoaderCircleIcon className="animate-spin" />}
                  Sign in
                </Button>
                <button
                  type="button"
                  className="text-muted-foreground hover:text-foreground text-xs underline-offset-4 hover:underline"
                  onClick={() => {
                    setProblem(null)
                    setNotice(null)
                    setStage("reset-request")
                  }}
                >
                  I have forgotten my password
                </button>
              </form>
            )}

            {stage === "totp" && (
              <form className="grid gap-4" onSubmit={submitTOTP}>
                <Field
                  label="Code"
                  htmlFor="code"
                  hint="Six digits from your authenticator app, or one of the recovery codes you saved."
                >
                  <Input
                    id="code"
                    autoComplete="one-time-code"
                    inputMode="text"
                    autoFocus
                    className="font-mono tracking-widest"
                    value={code}
                    onChange={(e) => setCode(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy || code.trim().length < 6}>
                  {busy && <LoaderCircleIcon className="animate-spin" />}
                  Continue
                </Button>
                <p className="text-muted-foreground text-xs">
                  Locked out of both? From SSH:{" "}
                  <code className="text-foreground">
                    sudo corex manage dashboard-user totp-reset &lt;username&gt;
                  </code>
                </p>
              </form>
            )}

            {stage === "reset-request" && (
              <form className="grid gap-4" onSubmit={submitResetRequest}>
                <Field
                  label="Username"
                  htmlFor="reset-username"
                  hint="A code goes to the address on the account, through this server's own mail relay."
                >
                  <Input
                    id="reset-username"
                    autoComplete="username"
                    autoFocus
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy || !username}>
                  {busy && <LoaderCircleIcon className="animate-spin" />}
                  Send me a code
                </Button>
                <button
                  type="button"
                  className="text-muted-foreground hover:text-foreground text-xs underline-offset-4 hover:underline"
                  onClick={() => setStage("password")}
                >
                  Back to sign in
                </button>
              </form>
            )}

            {stage === "reset-complete" && (
              <form className="grid gap-4" onSubmit={submitResetComplete}>
                <Field label="Username" htmlFor="rc-username">
                  <Input
                    id="rc-username"
                    autoComplete="username"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                  />
                </Field>
                <Field label="Code from the email" htmlFor="rc-code">
                  <Input
                    id="rc-code"
                    autoFocus
                    className="font-mono tracking-widest uppercase"
                    value={code}
                    onChange={(e) => setCode(e.target.value)}
                  />
                </Field>
                <Field
                  label="New password"
                  htmlFor="rc-password"
                  hint="At least 12 characters."
                >
                  <Input
                    id="rc-password"
                    type="password"
                    autoComplete="new-password"
                    value={newPassword}
                    onChange={(e) => setNewPassword(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy || !code || newPassword.length < 12}>
                  {busy && <LoaderCircleIcon className="animate-spin" />}
                  Set the password
                </Button>
                <button
                  type="button"
                  className="text-muted-foreground hover:text-foreground text-xs underline-offset-4 hover:underline"
                  onClick={() => setStage("password")}
                >
                  Back to sign in
                </button>
              </form>
            )}
          </CardContent>
        </Card>

        <p className="text-muted-foreground mt-4 text-center text-xs">
          Locked out? Every account can be reset from SSH with{" "}
          <code className="text-foreground">sudo corex manage dashboard-user</code>.
        </p>
      </div>
    </div>
  )
}
