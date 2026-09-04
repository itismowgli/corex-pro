package main

// Step-up authentication.
//
// A signed-in session is enough to read the box and to start, stop or repair a
// service, all of which are recoverable. It is not enough to power the machine
// off, because nobody can turn it back on from here: the dashboard runs on the
// box it would be switching off, and the tunnel goes down with it. A stolen
// laptop with a live cookie must not be able to do that.
//
// So the dangerous actions ask again, and the answer is good for five minutes.
// The factor is a password, a current TOTP code, or a passkey assertion with
// user verification required. The passkey is the one worth preferring: user
// verification means the authenticator checked a biometric or a PIN just now,
// which proves someone is present. A password proves only that the browser
// still remembers it.
//
// Elevation lives on the session in memory, so it does not survive a restart
// of this container and cannot be carried to another browser.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// Five minutes is long enough to read a confirmation dialog, type the word it
// asks for and press the button, and short enough that walking away from an
// unlocked laptop does not leave a power switch armed.
const elevationTTL = 5 * time.Minute

// elevationLeft is how much of the window remains. Zero means not elevated,
// which is also the answer for a session still awaiting a second factor.
func elevationLeft(s *session) time.Duration {
	if s == nil || s.AwaitingTOTP || s.ElevatedUntil.IsZero() {
		return 0
	}
	if left := time.Until(s.ElevatedUntil); left > 0 {
		return left
	}
	return 0
}

// elevate opens the window on the caller's own session, found by cookie rather
// than by user, so elevating in one browser does not arm another.
func elevate(r *http.Request, method string) time.Duration {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return 0
	}
	sessions.Lock()
	defer sessions.Unlock()
	s, ok := sessions.m[c.Value]
	if !ok {
		return 0
	}
	s.ElevatedUntil = time.Now().Add(elevationTTL)
	s.ElevatedBy = method
	return elevationTTL
}

// dropElevation closes the window early. A password change calls it, because
// an elevation granted by the old password should not outlive it.
func dropElevation(user string) {
	sessions.Lock()
	for _, s := range sessions.m {
		if s.User == user {
			s.ElevatedUntil = time.Time{}
			s.ElevatedBy = ""
		}
	}
	sessions.Unlock()
}

// errNeedElevation is the message the browser shows, so it says what to do
// rather than naming the mechanism.
const errNeedElevation = "confirm who you are to continue"

// requireElevated guards a handler that cannot be undone from here. It runs
// inside requireAuth, so a session already exists by this point.
//
// With no account configured there is nothing to step up from: the box is
// behind Traefik basic auth in that state, and refusing would leave the
// buttons permanently dead on an install that never enabled the login. So it
// passes through, the same way requireAuth does.
func requireElevated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		on, err := authEnabled()
		if err != nil {
			writeErr(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		if !on {
			next.ServeHTTP(w, r)
			return
		}
		_, s := currentSession(r)
		if s == nil || s.AwaitingTOTP {
			writeErr(w, http.StatusUnauthorized, "sign in to continue")
			return
		}
		if elevationLeft(s) <= 0 {
			// The flag matters more than the status code: the client cannot
			// tell a "prove it again" 403 from a "you may never do this" 403,
			// and guessing wrong means either a lost dialog or a retry loop.
			writeJSON(w, http.StatusForbidden, map[string]interface{}{
				"error":              errNeedElevation,
				"elevation_required": true,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// elevatedOrRefuse is requireElevated for a handler that guards only one of
// its own paths. It answers with the same body, so the client's one retry
// path covers both.
func elevatedOrRefuse(w http.ResponseWriter, r *http.Request) bool {
	on, err := authEnabled()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return false
	}
	if !on {
		return true
	}
	_, s := currentSession(r)
	if elevationLeft(s) > 0 {
		return true
	}
	writeJSON(w, http.StatusForbidden, map[string]interface{}{
		"error":              errNeedElevation,
		"elevation_required": true,
	})
	return false
}

// stepupLimit applies the login limiter's shape to the step-up: failures only,
// one bucket keyed on the account and one global floor. The address is not a
// bucket here because the caller is already signed in, so the account is the
// better key and it cannot be forged.
func stepupLimit(user string) error {
	if !limits.check("stepup:user:"+user, 5, 15*time.Minute) ||
		!limits.check("stepup:all", 40, 15*time.Minute) {
		return errors.New("too many attempts, wait a few minutes")
	}
	return nil
}

func stepupFail(r *http.Request, user, why string) {
	limits.hit("stepup:user:" + user)
	limits.hit("stepup:all")
	record(r, "stepup-failed", user, why)
}

func stepupOK(w http.ResponseWriter, r *http.Request, user, method string) {
	limits.clear("stepup:user:" + user)
	left := elevate(r, method)
	if left <= 0 {
		writeErr(w, http.StatusUnauthorized, "that session has gone, sign in again")
		return
	}
	log.Printf("auth: %s confirmed with a %s from %s", user, method, clientIP(r))
	record(r, "stepup", user, method)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "elevated_for": int(left.Seconds()), "elevated_by": method,
	})
}

// ── Password and code ─────────────────────────────────────────────────────────

// authStepupHandler takes whichever factor the caller has. A password is
// always accepted, including when TOTP is enrolled, so losing a phone cannot
// lock the operator out of their own power button. Recovery codes are not
// accepted: they are the way back into a login, and spending one to confirm a
// reboot wastes it.
func authStepupHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	_, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	if err := stepupLimit(s.User); err != nil {
		record(r, "locked-out", s.User, "too many confirmations")
		writeErr(w, http.StatusTooManyRequests, err.Error())
		return
	}

	code := strings.TrimSpace(body.Code)
	switch {
	case code != "":
		if !u.TOTP.Enabled {
			writeErr(w, http.StatusBadRequest,
				"two-factor is not set up on this account, so use the password")
			return
		}
		counter, valid := totpCheck(u.TOTP.Secret, code, time.Now())
		if !valid {
			stepupFail(r, s.User, "wrong code")
			writeErr(w, http.StatusUnauthorized, "that code was not accepted")
			return
		}
		// The same replay guard the login uses, and the same map, so a code
		// spent on one cannot be spent again on the other inside its window.
		totpUsed.Lock()
		last, seen := totpUsed.m[s.User]
		if seen && counter <= last {
			totpUsed.Unlock()
			stepupFail(r, s.User, "code replayed")
			writeErr(w, http.StatusUnauthorized, "that code has been used, wait for the next one")
			return
		}
		totpUsed.m[s.User] = counter
		totpUsed.Unlock()
		stepupOK(w, r, s.User, "totp")

	case body.Password != "":
		if !verifyHash(u.Password, body.Password) {
			stepupFail(r, s.User, "wrong password")
			writeErr(w, http.StatusUnauthorized, "that password does not match")
			return
		}
		stepupOK(w, r, s.User, "password")

	default:
		writeErr(w, http.StatusBadRequest, "send a password or a code")
	}
}

// ── Passkey ───────────────────────────────────────────────────────────────────

// stepupPasskeyBeginHandler asks for an assertion from this account's own
// keys, not a discoverable one. The account is already known, so naming the
// allowed credentials means the authenticator offers only the right key
// instead of a picker.
func stepupPasskeyBeginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	wa, err := webauthnInstance()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	_, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	if len(u.Passkeys) == 0 {
		writeErr(w, http.StatusBadRequest, "this account has no passkey enrolled")
		return
	}
	if err := stepupLimit(s.User); err != nil {
		writeErr(w, http.StatusTooManyRequests, err.Error())
		return
	}
	wu, err := waUser(s.User, u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not read this account's passkeys")
		return
	}
	// Required, not preferred, which is the whole reason to prefer this path:
	// the authenticator has to check a biometric or a PIN, so the assertion
	// says a person is here now.
	options, sessionData, err := wa.BeginLogin(wu,
		webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the confirmation")
		return
	}
	key, err := putCeremony(s.User, sessionData)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start the confirmation")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ceremony": key,
		"options":  options.Response,
	})
}

func stepupPasskeyFinishHandler(w http.ResponseWriter, r *http.Request) {
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

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	cer := takeCeremony(body.Ceremony)
	if cer == nil {
		writeErr(w, http.StatusBadRequest, "that confirmation expired, try again")
		return
	}
	// The ceremony was issued to one account. Checking that here means a
	// second session cannot finish a challenge it did not start.
	if cer.user != s.User {
		stepupFail(r, s.User, "ceremony belongs to another account")
		writeErr(w, http.StatusBadRequest, "that confirmation was not yours")
		return
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(body.Response)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "the authenticator's response was not valid")
		return
	}
	wu, err := waUser(s.User, u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not read this account's passkeys")
		return
	}
	cred, err := wa.ValidateLogin(wu, cer.data, parsed)
	if err != nil {
		stepupFail(r, s.User, "passkey refused")
		writeErr(w, http.StatusUnauthorized, "that passkey was not accepted")
		return
	}
	// A counter that went backwards is the documented signal of a cloned
	// authenticator, and refusing it matters more here than at the login: this
	// is the factor that unlocks powering the machine off.
	if cred.Authenticator.CloneWarning {
		stepupFail(r, s.User, "authenticator clone warning")
		writeErr(w, http.StatusUnauthorized,
			"that authenticator reported a counter that went backwards, which can mean it was cloned. "+
				"Remove the passkey and enrol it again.")
		return
	}
	// The library validates user verification against the options it was given,
	// so this is belt and braces rather than the check itself.
	if !cred.Flags.UserVerified {
		stepupFail(r, s.User, "no user verification")
		writeErr(w, http.StatusUnauthorized,
			"that authenticator did not verify who was using it, so it cannot confirm this")
		return
	}

	id := base64.RawURLEncoding.EncodeToString(cred.ID)
	for i := range u.Passkeys {
		if u.Passkeys[i].ID != id {
			continue
		}
		if raw, err := json.Marshal(cred); err == nil {
			u.Passkeys[i].Credential = raw
		}
		u.Passkeys[i].SignCount = cred.Authenticator.SignCount
		u.Passkeys[i].LastUsed = time.Now().Unix()
	}
	if err := saveUsers(doc); err != nil {
		log.Printf("auth: could not persist the passkey counter: %v", err)
	}
	stepupOK(w, r, s.User, "passkey")
}

func registerStepupRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/auth/stepup", authStepupHandler)
	mux.HandleFunc("/api/auth/stepup/passkey/begin", stepupPasskeyBeginHandler)
	mux.HandleFunc("/api/auth/stepup/passkey/finish", stepupPasskeyFinishHandler)
}
