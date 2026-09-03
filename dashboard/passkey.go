package main

// Passkeys, which is WebAuthn.
//
// WHY A DEPENDENCY HERE AND NOWHERE ELSE
//   Everything else in this binary is standard library, deliberately: it keeps
//   the build simple and there is nothing to audit. WebAuthn is where that
//   stops being the right trade. A verifier has to parse CBOR, decode COSE
//   public keys across three algorithms, check attestation statements, and
//   compare origins and flags exactly; each of those is a place where a
//   mistake is invisible, because a broken verifier still lets the right user
//   in. So this uses github.com/go-webauthn/webauthn, and the Go builder moves
//   to 1.25 because that library requires it.
//
// WHAT A PASSKEY IS FOR HERE
//   It replaces the password and the second factor in one step, and it cannot
//   be phished: the browser will only sign for the origin the key was created
//   on, so a convincing copy of this page on another hostname gets nothing.
//   That matters more than usual now, because this dashboard is published to
//   the internet and can stop every service on the box.
//
//   The password stays. A passkey lives in one authenticator, and an operator
//   locked out of their own control panel because a phone was lost is the
//   failure this whole design exists to avoid. `corex manage dashboard-user`
//   remains the way back in.
//
// THE ORIGIN HAS TO BE RIGHT OR NOTHING WORKS
//   WebAuthn binds a credential to an exact origin. The dashboard answers on
//   its public hostname and, on the LAN, on the same hostname through AdGuard,
//   so both are the same origin and one entry covers them. Reaching it by IP
//   is a different origin and passkeys will not work there, which is correct
//   rather than a bug: an IP cannot be verified as anything.

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// ── Stored shape ──────────────────────────────────────────────────────────────

type storedPasskey struct {
	// The credential id, base64url, which is what the browser sends back.
	ID   string `json:"id"`
	Name string `json:"name"`
	// The library's own credential record, kept whole rather than unpacked
	// into fields here. Its shape is the library's business and copying it
	// out by hand is how a sign counter or a transport list goes missing.
	Credential json.RawMessage `json:"credential"`
	Added      int64           `json:"added"`
	LastUsed   int64           `json:"last_used"`
	// Only ever set from the authenticator's own attestation, never trusted
	// from the client beyond what the library verified.
	SignCount uint32 `json:"sign_count"`
}

// webauthnUser adapts an account to the interface the library expects.
type webauthnUser struct {
	name string
	// A stable, opaque handle. Not the username: a user handle travels to the
	// authenticator and is stored there, so it must not be something that
	// changes or that leaks anything if the device is examined.
	handle []byte
	creds  []webauthn.Credential
}

func (u *webauthnUser) WebAuthnID() []byte                         { return u.handle }
func (u *webauthnUser) WebAuthnName() string                       { return u.name }
func (u *webauthnUser) WebAuthnDisplayName() string                { return u.name }
func (u *webauthnUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

// ── Configuration ─────────────────────────────────────────────────────────────

var (
	waOnce sync.Once
	waInst *webauthn.WebAuthn
	waErr  error
)

// passkeyOrigin is the exact origin the browser will report. Overridable
// because a deployment might front the dashboard on a different hostname, and
// a mismatch here is silent: registration simply fails with "origin not
// allowed" and nothing says which origin was expected.
func passkeyRP() (rpID, origin string) {
	if v := os.Getenv("COREX_PASSKEY_ORIGIN"); v != "" {
		origin = strings.TrimSuffix(v, "/")
		rpID = strings.TrimPrefix(strings.TrimPrefix(origin, "https://"), "http://")
		if i := strings.IndexByte(rpID, '/'); i >= 0 {
			rpID = rpID[:i]
		}
		return rpID, origin
	}
	domain := loadState().Domain
	if domain == "" {
		return "", ""
	}
	rpID = "dashboard." + domain
	return rpID, "https://" + rpID
}

func webauthnInstance() (*webauthn.WebAuthn, error) {
	waOnce.Do(func() {
		rpID, origin := passkeyRP()
		if rpID == "" {
			waErr = fmt.Errorf(
				"no domain is configured, so a passkey has nothing to bind to. " +
					"Set COREX_PASSKEY_ORIGIN, or configure the domain in state.json")
			return
		}
		waInst, waErr = webauthn.New(&webauthn.Config{
			RPDisplayName: "CoreX Pro",
			RPID:          rpID,
			RPOrigins:     []string{origin},
		})
	})
	return waInst, waErr
}

// ── Ceremony state ────────────────────────────────────────────────────────────
//
// A registration or a login is two requests, and the challenge issued by the
// first has to be remembered for the second. In memory and short lived, for
// the same reason sessions are: a dashboard restart cancelling a half-finished
// enrolment is correct, and a challenge that outlives the tab is a replay
// window nobody needs.

type ceremony struct {
	data    webauthn.SessionData
	user    string
	expires time.Time
}

var ceremonies = struct {
	sync.Mutex
	m map[string]*ceremony
}{m: map[string]*ceremony{}}

const ceremonyTTL = 5 * time.Minute

func putCeremony(user string, data *webauthn.SessionData) (string, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	key := base64.RawURLEncoding.EncodeToString(buf)
	now := time.Now()
	ceremonies.Lock()
	ceremonies.m[key] = &ceremony{data: *data, user: user, expires: now.Add(ceremonyTTL)}
	for k, v := range ceremonies.m {
		if now.After(v.expires) {
			delete(ceremonies.m, k)
		}
	}
	ceremonies.Unlock()
	return key, nil
}

func takeCeremony(key string) *ceremony {
	ceremonies.Lock()
	defer ceremonies.Unlock()
	c, ok := ceremonies.m[key]
	// Taken, not read: a challenge is single use, and leaving it in place
	// after a failed attempt is a free retry against the same one.
	delete(ceremonies.m, key)
	if !ok || time.Now().After(c.expires) {
		return nil
	}
	return c
}

// ── Reading and writing an account's keys ─────────────────────────────────────

func userHandle(u *authUser) ([]byte, bool) {
	if u.WebAuthnID == "" {
		return nil, false
	}
	b, err := base64.RawURLEncoding.DecodeString(u.WebAuthnID)
	if err != nil {
		return nil, false
	}
	return b, true
}

func ensureHandle(u *authUser) ([]byte, error) {
	if h, ok := userHandle(u); ok {
		return h, nil
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	u.WebAuthnID = base64.RawURLEncoding.EncodeToString(b)
	return b, nil
}

func credentialsOf(u *authUser) []webauthn.Credential {
	out := make([]webauthn.Credential, 0, len(u.Passkeys))
	for _, p := range u.Passkeys {
		var c webauthn.Credential
		if err := json.Unmarshal(p.Credential, &c); err != nil {
			log.Printf("passkey: stored credential %q is unreadable: %v", p.Name, err)
			continue
		}
		out = append(out, c)
	}
	return out
}

func waUser(name string, u *authUser) (*webauthnUser, error) {
	h, err := ensureHandle(u)
	if err != nil {
		return nil, err
	}
	return &webauthnUser{name: name, handle: h, creds: credentialsOf(u)}, nil
}

// ── Registration ──────────────────────────────────────────────────────────────

func passkeyBeginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	wa, err := webauthnInstance()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	if len(u.Passkeys) >= 10 {
		writeErr(w, http.StatusConflict, "this account already has ten passkeys")
		return
	}

	wu, err := waUser(s.User, u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not prepare the enrolment")
		return
	}
	// The handle may have just been generated, so persist before the browser
	// stores it. A handle the authenticator knows and the server does not is
	// a key that can never be used.
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	options, sessionData, err := wa.BeginRegistration(wu,
		// Discoverable, so signing in needs no username at all: the
		// authenticator offers the account itself.
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementPreferred),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementPreferred,
			UserVerification: protocol.VerificationPreferred,
		}),
		// Exclude what is already enrolled, so the same device cannot be
		// registered twice and silently shadow its own earlier key.
		webauthn.WithExclusions(credentialDescriptors(wu.creds)),
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the enrolment: "+err.Error())
		return
	}

	key, err := putCeremony(s.User, sessionData)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the enrolment")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ceremony": key,
		"options":  options.Response,
	})
}

func credentialDescriptors(creds []webauthn.Credential) []protocol.CredentialDescriptor {
	out := make([]protocol.CredentialDescriptor, 0, len(creds))
	for _, c := range creds {
		out = append(out, c.Descriptor())
	}
	return out
}

func passkeyFinishHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	wa, err := webauthnInstance()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	var body struct {
		Ceremony string          `json:"ceremony"`
		Name     string          `json:"name"`
		Response json.RawMessage `json:"response"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "could not read the response")
		return
	}
	cer := takeCeremony(body.Ceremony)
	if cer == nil {
		writeErr(w, http.StatusBadRequest, "that enrolment expired, start it again")
		return
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	if cer.user != s.User {
		writeErr(w, http.StatusForbidden, "that enrolment belongs to another account")
		return
	}

	parsed, err := protocol.ParseCredentialCreationResponseBytes(body.Response)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "the authenticator's response was not valid")
		return
	}
	wu, err := waUser(s.User, u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not complete the enrolment")
		return
	}
	cred, err := wa.CreateCredential(wu, cer.data, parsed)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "that passkey was refused: "+err.Error())
		return
	}

	raw, err := json.Marshal(cred)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not store the passkey")
		return
	}
	id := base64.RawURLEncoding.EncodeToString(cred.ID)
	for _, p := range u.Passkeys {
		if p.ID == id {
			writeErr(w, http.StatusConflict, "that passkey is already enrolled")
			return
		}
	}
	name := strings.TrimSpace(body.Name)
	if name == "" {
		name = "Passkey"
	}
	if len(name) > 48 {
		name = name[:48]
	}
	u.Passkeys = append(u.Passkeys, storedPasskey{
		ID: id, Name: name, Credential: raw,
		Added: time.Now().Unix(), SignCount: cred.Authenticator.SignCount,
	})
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	log.Printf("auth: %s added a passkey (%s)", s.User, name)
	record(r, "passkey-added", s.User, name)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "id": id, "name": name})
}

// ── Signing in ────────────────────────────────────────────────────────────────

func passkeyLoginBeginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	wa, err := webauthnInstance()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	// Rate limited like any other sign-in path. A passkey assertion is far
	// harder to guess than a password, but the ceremony still costs the
	// server work and the limiter is what stops that being free.
	ip := clientIP(r)
	if !limits.check("login:ip:"+ip, 10, 15*time.Minute) ||
		!limits.check("login:all", 60, 15*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts, wait a few minutes")
		return
	}

	options, sessionData, err := wa.BeginDiscoverableLogin(
		webauthn.WithUserVerification(protocol.VerificationPreferred),
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the sign-in")
		return
	}
	key, err := putCeremony("", sessionData)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the sign-in")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ceremony": key,
		"options":  options.Response,
	})
}

func passkeyLoginFinishHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	wa, err := webauthnInstance()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	var body struct {
		Ceremony string          `json:"ceremony"`
		Response json.RawMessage `json:"response"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "could not read the response")
		return
	}
	cer := takeCeremony(body.Ceremony)
	if cer == nil {
		writeErr(w, http.StatusBadRequest, "that sign-in expired, try again")
		return
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(body.Response)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "the authenticator's response was not valid")
		return
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, err := loadUsers()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	// The user handle in the assertion says which account this is. Matching on
	// it rather than trusting any name the client sends is the whole point of
	// a discoverable credential.
	var matchedName string
	var matchedUser *authUser
	discover := func(rawID, handle []byte) (webauthn.User, error) {
		want := base64.RawURLEncoding.EncodeToString(handle)
		for name, u := range doc.Users {
			if u.WebAuthnID != want {
				continue
			}
			wu, err := waUser(name, u)
			if err != nil {
				return nil, err
			}
			matchedName, matchedUser = name, u
			return wu, nil
		}
		return nil, fmt.Errorf("no account holds that passkey")
	}

	cred, err := wa.ValidateDiscoverableLogin(discover, cer.data, parsed)
	if err != nil || matchedUser == nil {
		limits.hit("login:ip:" + clientIP(r))
		limits.hit("login:all")
		record(r, "login-failed", matchedName, "passkey refused")
		writeErr(w, http.StatusUnauthorized, "that passkey was not accepted")
		return
	}

	// A sign counter that goes backwards is the documented signal of a cloned
	// authenticator. The library reports it; refusing on it is this side's
	// decision, and refusing is right for a panel that can stop every service.
	if cred.Authenticator.CloneWarning {
		record(r, "login-failed", matchedName, "authenticator clone warning")
		writeErr(w, http.StatusUnauthorized,
			"that authenticator reported a counter that went backwards, which can mean it was cloned. "+
				"Remove the passkey and enrol it again.")
		return
	}

	id := base64.RawURLEncoding.EncodeToString(cred.ID)
	for i := range matchedUser.Passkeys {
		if matchedUser.Passkeys[i].ID != id {
			continue
		}
		if raw, err := json.Marshal(cred); err == nil {
			matchedUser.Passkeys[i].Credential = raw
		}
		matchedUser.Passkeys[i].SignCount = cred.Authenticator.SignCount
		matchedUser.Passkeys[i].LastUsed = time.Now().Unix()
	}
	if err := saveUsers(doc); err != nil {
		log.Printf("auth: could not persist the passkey counter: %v", err)
	}

	// A passkey is the password and the second factor at once, so it lands a
	// fully signed-in session rather than one awaiting a code.
	if err := startSession(w, r, matchedName, false); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start a session")
		return
	}
	limits.clear("login:ip:"+clientIP(r), "login:user:"+matchedName)
	log.Printf("auth: %s signed in with a passkey from %s", matchedName, clientIP(r))
	record(r, "passkey-login", matchedName, "")
	record(r, "login", matchedName, "passkey")
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "awaiting_totp": false, "display_name": matchedUser.DisplayName,
	})
}

// ── Management ────────────────────────────────────────────────────────────────

type passkeyView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Added    int64  `json:"added"`
	LastUsed int64  `json:"last_used"`
}

func passkeyListHandler(w http.ResponseWriter, r *http.Request) {
	_, u, _, ok := requireUser(w, r)
	if !ok {
		return
	}
	out := []passkeyView{}
	for _, p := range u.Passkeys {
		out = append(out, passkeyView{ID: p.ID, Name: p.Name, Added: p.Added, LastUsed: p.LastUsed})
	}
	rpID, origin := passkeyRP()
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"passkeys": out,
		"rp_id":    rpID,
		"origin":   origin,
		// The page needs to know whether it can offer enrolment at all, and
		// saying why it cannot beats a button that always fails.
		"available": rpID != "",
	})
}

func passkeyDeleteHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID string `json:"id"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	doc, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	kept := u.Passkeys[:0]
	removed := ""
	for _, p := range u.Passkeys {
		if p.ID == body.ID {
			removed = p.Name
			continue
		}
		kept = append(kept, p)
	}
	if removed == "" {
		writeErr(w, http.StatusNotFound, "no such passkey")
		return
	}
	u.Passkeys = kept
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	log.Printf("auth: %s removed a passkey (%s)", s.User, removed)
	record(r, "passkey-removed", s.User, removed)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func registerPasskeyRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/auth/passkey/list", passkeyListHandler)
	mux.HandleFunc("/api/auth/passkey/begin", passkeyBeginHandler)
	mux.HandleFunc("/api/auth/passkey/finish", passkeyFinishHandler)
	mux.HandleFunc("/api/auth/passkey/delete", passkeyDeleteHandler)
	mux.HandleFunc("/api/auth/passkey/login/begin", passkeyLoginBeginHandler)
	mux.HandleFunc("/api/auth/passkey/login/finish", passkeyLoginFinishHandler)
}
