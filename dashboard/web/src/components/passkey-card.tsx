import * as React from "react"
import { FingerprintIcon, KeyRoundIcon, LoaderCircleIcon, TrashIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, Input } from "@/components/ui/input"
import { auth, type Passkey } from "@/lib/api"
import { ago } from "@/lib/format"
import { create, explain, platformAvailable, supported } from "@/lib/webauthn"

/**
 * Passkeys, which replace the password and the second factor in one step.
 *
 * The password is not removed when one is added, and that is deliberate: a
 * passkey lives in one authenticator, and an operator locked out of their own
 * control panel because a phone was lost is the exact failure this design
 * exists to avoid.
 */
export function PasskeyCard({ refresh }: { refresh: () => void }) {
  const [rows, setRows] = React.useState<Passkey[] | null>(null)
  const [meta, setMeta] = React.useState<{ available: boolean; origin: string } | null>(null)
  const [name, setName] = React.useState("")
  const [busy, setBusy] = React.useState(false)
  const [problem, setProblem] = React.useState<string | null>(null)
  const [note, setNote] = React.useState<string | null>(null)
  const [platform, setPlatform] = React.useState(false)

  const load = React.useCallback(async () => {
    try {
      const res = await auth.passkeys()
      setRows(res.passkeys)
      setMeta({ available: res.available, origin: res.origin })
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e))
    }
  }, [])

  React.useEffect(() => {
    void load()
    void platformAvailable().then(setPlatform)
  }, [load])

  const enrol = async () => {
    setBusy(true)
    setProblem(null)
    setNote(null)
    try {
      const started = await auth.passkeyBegin()
      const response = await create(started.options)
      const label =
        name.trim() ||
        (platform ? "This device" : "Security key") 
      await auth.passkeyFinish(started.ceremony, label, response)
      setName("")
      setNote(`Added "${label}". You can now sign in with it instead of the password.`)
      await load()
      refresh()
    } catch (e) {
      setProblem(explain(e))
    } finally {
      setBusy(false)
    }
  }

  const remove = async (p: Passkey) => {
    if (!window.confirm(`Remove "${p.name}"? You can enrol it again later.`)) return
    setBusy(true)
    setProblem(null)
    try {
      await auth.passkeyDelete(p.id)
      await load()
      refresh()
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <FingerprintIcon className="size-4" />
          Passkeys
        </CardTitle>
      </CardHeader>
      <CardContent className="grid gap-4">
        <p className="text-muted-foreground max-w-lg text-xs">
          A passkey is your fingerprint, face or a security key, and it replaces both the
          password and the code in one step. It cannot be phished: the browser will only sign
          for the address the key was made on, so a convincing copy of this page on another
          hostname gets nothing.
        </p>

        {!supported() && (
          <p className="text-warn text-xs">
            This browser cannot do WebAuthn, so passkeys are unavailable here.
          </p>
        )}
        {meta && !meta.available && (
          <p className="text-warn text-xs">
            No domain is configured, so a passkey has nothing to bind to.
          </p>
        )}
        {meta?.origin && (
          <p className="text-muted-foreground text-xs">
            Keys are bound to <code className="text-foreground">{meta.origin}</code>. Reaching
            the dashboard by IP address is a different origin, and passkeys will not work
            there.
          </p>
        )}

        {rows === null ? (
          <p className="text-muted-foreground text-xs">Reading your keys...</p>
        ) : rows.length === 0 ? (
          <p className="text-muted-foreground text-xs">No passkeys yet.</p>
        ) : (
          <div className="grid gap-1">
            {rows.map((p) => (
              <div
                key={p.id}
                className="flex items-center justify-between gap-2 border-b py-2 text-sm last:border-0"
              >
                <span className="flex min-w-0 items-center gap-2">
                  <KeyRoundIcon className="text-muted-foreground size-3.5 shrink-0" />
                  <span className="truncate">{p.name}</span>
                </span>
                <span className="flex shrink-0 items-center gap-3">
                  <span className="text-muted-foreground text-xs">
                    {p.last_used
                      ? `used ${ago(new Date(p.last_used * 1000).toISOString())}`
                      : "never used"}
                  </span>
                  <Button
                    size="xs"
                    variant="ghost"
                    disabled={busy}
                    onClick={() => remove(p)}
                    aria-label={`Remove ${p.name}`}
                  >
                    <TrashIcon />
                  </Button>
                </span>
              </div>
            ))}
          </div>
        )}

        {problem && (
          <p className="text-destructive text-xs" role="alert">
            {problem}
          </p>
        )}
        {note && <p className="text-ok text-xs">{note}</p>}

        {supported() && meta?.available && (
          <div className="grid max-w-md gap-3">
            <Field
              label="Name this key"
              htmlFor="passkey-name"
              hint="Something you will recognise in a list, such as the phone or the laptop it lives on."
            >
              <Input
                id="passkey-name"
                value={name}
                placeholder={platform ? "This device" : "Security key"}
                onChange={(e) => setName(e.target.value)}
              />
            </Field>
            <div>
              <Button onClick={enrol} disabled={busy}>
                {busy ? <LoaderCircleIcon className="animate-spin" /> : <FingerprintIcon />}
                Add a passkey
              </Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
