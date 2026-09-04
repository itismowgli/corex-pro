import * as React from "react"
import { FingerprintIcon, LoaderCircleIcon, ShieldCheckIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Field, Input } from "@/components/ui/input"
import { auth, ElevationRequired, type Me } from "@/lib/api"
import { explain, get as webauthnGet, supported as webauthnSupported } from "@/lib/webauthn"

/**
 * Asking again before something that cannot be undone from here.
 *
 * The server decides what needs it: a guarded route answers 403 with an
 * elevation flag, and this catches that, collects a factor and runs the
 * original action again. The action itself does not have to know, which means
 * a new guarded route needs no change here.
 */

/** A factor is being collected for this action. */
type Pending = { label: string; run: () => Promise<void> }

export function useStepup(me: Me | null) {
  const [pending, setPending] = React.useState<Pending | null>(null)

  const guard = React.useCallback(async (label: string, run: () => Promise<void>) => {
    try {
      await run()
    } catch (e) {
      if (e instanceof ElevationRequired) {
        // Held rather than run: the same call goes out again once a factor is
        // accepted, so the caller writes one function and not two.
        setPending({ label, run })
        return
      }
      throw e
    }
  }, [])

  const dialog = (
    <StepupDialog me={me} pending={pending} onClose={() => setPending(null)} />
  )
  return { guard, dialog }
}

function StepupDialog({
  me,
  pending,
  onClose,
}: {
  me: Me | null
  pending: Pending | null
  onClose: () => void
}) {
  const [password, setPassword] = React.useState("")
  const [code, setCode] = React.useState("")
  const [busy, setBusy] = React.useState(false)
  const [problem, setProblem] = React.useState<string | null>(null)
  const canPasskey = React.useMemo(webauthnSupported, []) && (me?.passkeys ?? 0) > 0

  React.useEffect(() => {
    if (pending) {
      setPassword("")
      setCode("")
      setProblem(null)
    }
  }, [pending])

  if (!pending) return null

  // One path for all three factors: prove it, then run what was held. A failure
  // in the held action reports here too, because from the operator's point of
  // view they pressed one button.
  const confirm = (prove: () => Promise<unknown>) => {
    setBusy(true)
    setProblem(null)
    void (async () => {
      try {
        await prove()
      } catch (e) {
        setProblem(explain(e))
        setBusy(false)
        return
      }
      const run = pending.run
      onClose()
      setBusy(false)
      try {
        await run()
      } catch (e) {
        setProblem(explain(e))
      }
    })()
  }

  const withPasskey = () =>
    confirm(async () => {
      const started = await auth.stepupPasskeyBegin()
      const response = await webauthnGet(started.options)
      await auth.stepupPasskeyFinish(started.ceremony, response)
    })

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base">
            <ShieldCheckIcon className="size-4" />
            Confirm it is you
          </DialogTitle>
        </DialogHeader>

        <p className="text-muted-foreground text-sm">
          {pending.label} cannot be undone from this page, so it needs a fresh factor rather than a
          browser that is still signed in. The confirmation lasts five minutes.
        </p>

        <div className="flex flex-col gap-3">
          {canPasskey && (
            <>
              <Button onClick={withPasskey} disabled={busy} className="w-full">
                {busy ? (
                  <LoaderCircleIcon className="animate-spin" />
                ) : (
                  <FingerprintIcon />
                )}
                Use a passkey
              </Button>
              <p className="text-muted-foreground text-xs">
                A passkey asks your device to check a fingerprint, a face or a PIN, so it proves
                someone is here now. A password only proves the browser remembers one.
              </p>
            </>
          )}

          {me?.totp_enabled && (
            <form
              onSubmit={(e) => {
                e.preventDefault()
                confirm(() => auth.stepup({ code: code.trim() }))
              }}
              className="flex flex-col gap-2"
            >
              <Field label="Six-digit code" htmlFor="stepup-code">
                <Input
                  id="stepup-code"
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  placeholder="123456"
                  disabled={busy}
                />
              </Field>
              <Button type="submit" variant="secondary" disabled={busy || code.trim().length < 6}>
                Confirm with the code
              </Button>
            </form>
          )}

          <form
            onSubmit={(e) => {
              e.preventDefault()
              confirm(() => auth.stepup({ password }))
            }}
            className="flex flex-col gap-2"
          >
            <Field label="Password" htmlFor="stepup-password">
              <Input
                id="stepup-password"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                autoComplete="current-password"
                disabled={busy}
              />
            </Field>
            <Button type="submit" variant="secondary" disabled={busy || !password}>
              Confirm with the password
            </Button>
          </form>
        </div>

        {problem && <p className="text-destructive text-sm">{problem}</p>}
      </DialogContent>
    </Dialog>
  )
}
