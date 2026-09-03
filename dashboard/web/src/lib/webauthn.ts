/**
 * The browser half of a passkey ceremony.
 *
 * WebAuthn passes ArrayBuffers where JSON has strings, so every challenge and
 * id has to be converted on the way in and every response on the way out.
 * Getting one of those wrong fails with "the authenticator's response was not
 * valid", which says nothing about which field was wrong, so the conversion
 * lives in one place rather than being repeated at each call site.
 *
 * base64url, not base64: WebAuthn uses the URL-safe alphabet without padding,
 * and a stray "+" decodes to the wrong bytes rather than to an error.
 */

export function supported(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.PublicKeyCredential !== "undefined" &&
    typeof navigator?.credentials?.create === "function"
  )
}

/** Whether the device can present a passkey itself, rather than needing another. */
export async function platformAvailable(): Promise<boolean> {
  if (!supported()) return false
  try {
    return await window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
  } catch {
    return false
  }
}

function fromB64url(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(pad + "=".repeat((4 - (pad.length % 4)) % 4))
  const out = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
  return out
}

function toB64url(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf)
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

type AnyRecord = Record<string, unknown>

/** Decode the base64url fields the server sends in creation options. */
function decodeCreation(o: AnyRecord): CredentialCreationOptions {
  const pk = { ...o } as AnyRecord
  pk.challenge = fromB64url(String(pk.challenge))
  const user = { ...(pk.user as AnyRecord) }
  user.id = fromB64url(String(user.id))
  pk.user = user
  if (Array.isArray(pk.excludeCredentials)) {
    pk.excludeCredentials = (pk.excludeCredentials as AnyRecord[]).map((c) => ({
      ...c,
      id: fromB64url(String(c.id)),
    }))
  }
  return { publicKey: pk as unknown as PublicKeyCredentialCreationOptions }
}

function decodeRequest(o: AnyRecord): CredentialRequestOptions {
  const pk = { ...o } as AnyRecord
  pk.challenge = fromB64url(String(pk.challenge))
  if (Array.isArray(pk.allowCredentials)) {
    pk.allowCredentials = (pk.allowCredentials as AnyRecord[]).map((c) => ({
      ...c,
      id: fromB64url(String(c.id)),
    }))
  }
  return { publicKey: pk as unknown as PublicKeyCredentialRequestOptions }
}

/** Encode a credential back into the shape the server's parser expects. */
function encode(cred: PublicKeyCredential): AnyRecord {
  const res = cred.response as AuthenticatorAttestationResponse &
    AuthenticatorAssertionResponse
  const out: AnyRecord = {
    id: cred.id,
    rawId: toB64url(cred.rawId),
    type: cred.type,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: toB64url(res.clientDataJSON),
    } as AnyRecord,
  }
  const r = out.response as AnyRecord
  if (res.attestationObject) r.attestationObject = toB64url(res.attestationObject)
  if (res.authenticatorData) r.authenticatorData = toB64url(res.authenticatorData)
  if (res.signature) r.signature = toB64url(res.signature)
  if (res.userHandle) r.userHandle = toB64url(res.userHandle)
  return out
}

export async function create(options: unknown): Promise<AnyRecord> {
  const cred = (await navigator.credentials.create(
    decodeCreation(options as AnyRecord)
  )) as PublicKeyCredential | null
  if (!cred) throw new Error("the authenticator returned nothing")
  return encode(cred)
}

export async function get(options: unknown): Promise<AnyRecord> {
  const cred = (await navigator.credentials.get(
    decodeRequest(options as AnyRecord)
  )) as PublicKeyCredential | null
  if (!cred) throw new Error("the authenticator returned nothing")
  return encode(cred)
}

/**
 * Turn a WebAuthn exception into something worth showing.
 *
 * The spec deliberately gives the same NotAllowedError for a cancelled prompt,
 * a timeout and a refusal, so the honest message covers all three rather than
 * guessing at one.
 */
export function explain(e: unknown): string {
  const err = e as { name?: string; message?: string }
  switch (err?.name) {
    case "NotAllowedError":
      return "The request was cancelled, timed out, or the authenticator refused it."
    case "InvalidStateError":
      return "That authenticator already holds a passkey for this account."
    case "SecurityError":
      return "The page's address does not match what the passkey was created for. Passkeys work on the hostname, not on a bare IP address."
    case "NotSupportedError":
      return "This browser or device cannot do what was asked."
    case "AbortError":
      return "The request was abandoned."
    default:
      return err?.message || String(e)
  }
}
