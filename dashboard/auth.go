package main

// The dashboard's own login.
//
// WHAT IT REPLACES
//   Traefik basic auth, which cannot change its own password, cannot recover
//   one, and has no idea who anyone is. Cloudflare Access solves the same
//   problem at the edge and is the better answer where it works, but it is
//   configured outside CoreX and failed here in a way CoreX could not see:
//   its one-time PIN never arrived at either mailbox, which locks the operator
//   out of their own dashboard while leaving it published.
//
// WHERE THE ACCOUNTS ARE
//   /etc/corex/dashboard-users.json, 0600 root. This container runs as nobody
//   and cannot read it. It goes through the agent's users-get and users-put
//   actions instead, and does every bit of the cryptography here: PBKDF2 for
//   passwords, recovery codes and reset tokens, RFC 6238 for two-factor.
//
//   The one thing that stays on the privileged side is the reset mail. The
//   relay credentials live in /etc/corex/smtp.conf, also 0600 root, and a
//   web-facing container has no business holding them. So the agent generates
//   the code, stores its hash in the document, sends the mail and tells us
//   nothing; this side verifies the code against that hash later, having never
//   seen either the code or the relay password. Same reasoning as the action
//   agent itself: one privileged process, a fixed list of things it will do.
//
// FAILING CLOSED
//   Auth turns itself on the first time the store is read and has an account
//   in it, and that fact is remembered. If a later read fails, requests are
//   refused rather than waved through, so killing the agent cannot be a way
//   past the login. Before the first account exists there is nothing to
//   enforce, and Traefik basic auth is still in front; see
//   `corex manage dashboard-user`.

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ── The stored document ───────────────────────────────────────────────────────
//
// The same shape agent/corex_users.py writes. Every secret is a self-describing
// hashRecord so neither side has to agree on an iteration count by convention,
// and a recovery code with 50 bits of its own entropy can be cheaper to check
// than a password without this side needing to know which it is holding.

type hashRecord struct {
	Algo       string `json:"algo"`
	Iterations int    `json:"iterations"`
	Salt       string `json:"salt"`
	Hash       string `json:"hash"`
}

type recoveryCode struct {
	hashRecord
	Used bool `json:"used"`
}

type resetRecord struct {
	hashRecord
	Requested int64 `json:"requested"`
	Expires   int64 `json:"expires"`
	Attempts  int   `json:"attempts"`
}

type totpConfig struct {
	Enabled bool   `json:"enabled"`
	Secret  string `json:"secret,omitempty"`
	// An enrolment that has been shown but not yet confirmed with a code.
	// Kept apart from Secret so an abandoned enrolment cannot lock anyone out.
	Pending  string         `json:"pending,omitempty"`
	Recovery []recoveryCode `json:"recovery,omitempty"`
}

type authUser struct {
	DisplayName     string       `json:"display_name"`
	Email           string       `json:"email"`
	Password        hashRecord   `json:"password"`
	Created         int64        `json:"created"`
	PasswordChanged int64        `json:"password_changed"`
	TOTP            totpConfig   `json:"totp"`
	Reset           *resetRecord `json:"reset,omitempty"`
}

type usersDoc struct {
	Version int                  `json:"version"`
	Rev     int                  `json:"rev"`
	Users   map[string]*authUser `json:"users"`
}

const (
	passwordIterations = 600000
	tokenIterations    = 120000
	hashAlgo           = "pbkdf2-sha256"
	minPasswordLen     = 12
	maxPasswordLen     = 200
	maxResetAttempts   = 6
	recoveryCodeCount  = 10
	sessionCookie      = "corex_session"
	sessionIdle        = 12 * time.Hour
	sessionMax         = 7 * 24 * time.Hour
)

// codeAlphabet has no 0, O, 1, I or L: these are read off a screen and typed
// on a phone. It must match CODE_ALPHABET in agent/corex_users.py.
const codeAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

// ── Store access ──────────────────────────────────────────────────────────────

var (
	// storeMu serialises this process's own read-modify-write cycles, so two
	// browser tabs enrolling in two-factor at once cannot lose one another's
	// write. The agent additionally rejects a stale revision, which covers the
	// CLI writing at the same moment.
	storeMu sync.Mutex

	authStateMu sync.Mutex
	// Sticky: once an account has been seen, a later unreadable store is a
	// fault to report, not a reason to let everyone in.
	authConfigured bool

	// Whether a login is being enforced, cached briefly. Without this every
	// API request costs an agent round trip and a file read, and the app polls
	// six endpoints. Only this boolean is cached, never a user record: a
	// password change has to take effect at once, and it does, because the
	// session it invalidates lives in memory here.
	authEnabledCache   bool
	authEnabledCheckAt time.Time
)

const authEnabledTTL = 5 * time.Second

var errStoreUnavailable = errors.New("the dashboard user store is unreachable")

func loadUsers() (*usersDoc, error) {
	res, err := agentCall(map[string]interface{}{"action": "users-get"}, 20*time.Second)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errStoreUnavailable, err)
	}
	if !agentOK(res) {
		return nil, fmt.Errorf("%w: %s", errStoreUnavailable, agentString(res, "error"))
	}
	raw, err := json.Marshal(res["doc"])
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errStoreUnavailable, err)
	}
	var doc usersDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("%w: %v", errStoreUnavailable, err)
	}
	if doc.Users == nil {
		doc.Users = map[string]*authUser{}
	}
	if len(doc.Users) > 0 {
		authStateMu.Lock()
		authConfigured = true
		authStateMu.Unlock()
	}
	return &doc, nil
}

func saveUsers(doc *usersDoc) error {
	res, err := agentCall(map[string]interface{}{
		"action": "users-put",
		"doc":    doc,
	}, 20*time.Second)
	if err != nil {
		return fmt.Errorf("%w: %v", errStoreUnavailable, err)
	}
	if !agentOK(res) {
		return errors.New(agentString(res, "error"))
	}
	return nil
}

// authEnabled answers whether a login is being enforced right now, and says
// why when it cannot tell. A store that has never had an account in it means
// the login is not set up yet, which is not a failure: Traefik basic auth is
// still in front until `corex manage dashboard-user enable-auth` removes it.
func authEnabled() (bool, error) {
	authStateMu.Lock()
	if time.Since(authEnabledCheckAt) < authEnabledTTL {
		on := authEnabledCache
		authStateMu.Unlock()
		return on, nil
	}
	authStateMu.Unlock()

	doc, err := loadUsers()
	if err != nil {
		authStateMu.Lock()
		known := authConfigured
		authStateMu.Unlock()
		if known {
			return true, err
		}
		return false, nil
	}
	on := len(doc.Users) > 0
	authStateMu.Lock()
	authEnabledCache, authEnabledCheckAt = on, time.Now()
	authStateMu.Unlock()
	return on, nil
}

// ── Hashing ───────────────────────────────────────────────────────────────────

func makeHash(plain string, iterations int) (hashRecord, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return hashRecord{}, err
	}
	dk, err := pbkdf2.Key(sha256.New, plain, salt, iterations, 32)
	if err != nil {
		return hashRecord{}, err
	}
	return hashRecord{
		Algo:       hashAlgo,
		Iterations: iterations,
		Salt:       base64.StdEncoding.EncodeToString(salt),
		Hash:       base64.StdEncoding.EncodeToString(dk),
	}, nil
}

func verifyHash(rec hashRecord, plain string) bool {
	if rec.Algo != hashAlgo {
		return false
	}
	// Bounds, not because a stored count is untrusted input from a stranger,
	// but because a corrupted file must not turn into either a free pass or a
	// minute of CPU per login attempt.
	if rec.Iterations < 1000 || rec.Iterations > 5000000 {
		return false
	}
	salt, err := base64.StdEncoding.DecodeString(rec.Salt)
	if err != nil {
		return false
	}
	want, err := base64.StdEncoding.DecodeString(rec.Hash)
	if err != nil || len(want) == 0 {
		return false
	}
	got, err := pbkdf2.Key(sha256.New, plain, salt, rec.Iterations, len(want))
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(got, want) == 1
}

// dummyVerify burns roughly the time a real check would, so that "no such
// user" and "wrong password" take the same wall-clock time. Without it the
// login form answers an unknown username in a millisecond and a known one in
// a quarter of a second, which is a list of valid usernames for anyone with a
// stopwatch.
func dummyVerify(plain string) {
	salt := []byte("corex-dashboard-timing-equaliser")
	_, _ = pbkdf2.Key(sha256.New, plain, salt, passwordIterations, 32)
}

func randomCode(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, n)
	for i, b := range buf {
		out[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}
	return string(out), nil
}

// ── TOTP, RFC 6238 ────────────────────────────────────────────────────────────
//
// SHA-1, six digits, thirty seconds: not a preference, it is what every
// authenticator app assumes when the URI does not say otherwise, and this one
// says so explicitly anyway.

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

func newTOTPSecret() (string, error) {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return b32.EncodeToString(buf), nil
}

func hotp(key []byte, counter uint64) string {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], counter)
	mac := hmac.New(sha1.New, key)
	mac.Write(buf[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", v%1000000)
}

// totpCounter returns the counter a code matched, so the caller can refuse to
// accept the same one twice. A six-digit code is valid for at least thirty
// seconds, which is long enough to read it off a shoulder or out of a proxy
// log and replay it.
func totpCheck(secret, code string, now time.Time) (uint64, bool) {
	code = strings.TrimSpace(strings.ReplaceAll(code, " ", ""))
	if len(code) != 6 {
		return 0, false
	}
	key, err := b32.DecodeString(strings.ToUpper(strings.ReplaceAll(secret, " ", "")))
	if err != nil || len(key) == 0 {
		return 0, false
	}
	step := uint64(now.Unix() / 30)
	// One step either side, which is the usual allowance for a phone whose
	// clock has drifted.
	for _, c := range []uint64{step - 1, step, step + 1} {
		if subtle.ConstantTimeCompare([]byte(hotp(key, c)), []byte(code)) == 1 {
			return c, true
		}
	}
	return 0, false
}

func totpURI(user, secret, domain string) string {
	issuer := "CoreX"
	if domain != "" {
		issuer = "CoreX " + domain
	}
	label := url.PathEscape(issuer + ":" + user)
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", issuer)
	q.Set("algorithm", "SHA1")
	q.Set("digits", "6")
	q.Set("period", "30")
	return "otpauth://totp/" + label + "?" + q.Encode()
}

// ── Sessions ──────────────────────────────────────────────────────────────────
//
// Server side, in this process's memory, deliberately. A dashboard restart
// signing everyone out is correct behaviour for a control panel, and it means
// `dashboard-user passwd` from SSH plus a restart is a complete way to take
// an account back.

type session struct {
	User    string
	Created time.Time
	Seen    time.Time
	// True between a correct password and a correct second factor. Such a
	// session can do exactly one thing: present a code.
	AwaitingTOTP bool
}

var sessions = struct {
	sync.Mutex
	m map[string]*session
}{m: map[string]*session{}}

// totpUsed remembers the last counter accepted per user, so a code cannot be
// replayed inside its own validity window.
var totpUsed = struct {
	sync.Mutex
	m map[string]uint64
}{m: map[string]uint64{}}

func newSessionID() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func startSession(w http.ResponseWriter, user string, awaitingTOTP bool) error {
	id, err := newSessionID()
	if err != nil {
		return err
	}
	now := time.Now()
	sessions.Lock()
	sessions.m[id] = &session{User: user, Created: now, Seen: now, AwaitingTOTP: awaitingTOTP}
	// Opportunistic sweep, so an unbounded map cannot grow out of a 128MB
	// container on a login page someone is hammering.
	for k, s := range sessions.m {
		if now.Sub(s.Seen) > sessionIdle || now.Sub(s.Created) > sessionMax {
			delete(sessions.m, k)
		}
	}
	sessions.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    id,
		Path:     "/",
		HttpOnly: true,
		// Traefik terminates TLS in front of this container, so the browser
		// only ever sees the cookie over HTTPS. Testing against the container
		// IP over plain HTTP therefore has to carry the cookie by hand.
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(sessionMax / time.Second),
	})
	return nil
}

func clearSession(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		sessions.Lock()
		delete(sessions.m, c.Value)
		sessions.Unlock()
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: "", Path: "/",
		HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode, MaxAge: -1,
	})
}

// currentSession returns the caller's session and refreshes its idle clock.
func currentSession(r *http.Request) (string, *session) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return "", nil
	}
	now := time.Now()
	sessions.Lock()
	defer sessions.Unlock()
	s, ok := sessions.m[c.Value]
	if !ok {
		return "", nil
	}
	if now.Sub(s.Seen) > sessionIdle || now.Sub(s.Created) > sessionMax {
		delete(sessions.m, c.Value)
		return "", nil
	}
	s.Seen = now
	return c.Value, s
}

// dropSessionsFor signs an account out everywhere. Called when its password
// changes, because a password change that leaves an attacker's session alive
// has not actually taken the account back.
func dropSessionsFor(user string, keep string) {
	sessions.Lock()
	for id, s := range sessions.m {
		if s.User == user && id != keep {
			delete(sessions.m, id)
		}
	}
	sessions.Unlock()
}

// ── Rate limiting ─────────────────────────────────────────────────────────────
//
// An emailed reset code is eight characters and a second factor is six digits.
// Both are trivially brute-forceable without this, and PBKDF2 does not help:
// it makes each attempt cost the server as much as the attacker.

type limiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

var limits = &limiter{hits: map[string][]time.Time{}}

// allow both asks and counts, for the paths where every attempt has a real
// cost. Sending a reset email is the case: the mail goes out whether or not
// the request was sensible.
func (l *limiter) allow(key string, max int, window time.Duration) bool {
	if !l.check(key, max, window) {
		return false
	}
	l.hit(key)
	return true
}

// check asks without counting, so that a correct password does not spend the
// budget a wrong one is meant to consume.
//
// Counting successes was the first version, and it is wrong in a way that only
// shows up in use: five attempts per quarter hour includes the phone, the
// laptop and the tab you already had open, so an operator who has done nothing
// wrong is locked out of their own control panel for fifteen minutes.
func (l *limiter) check(key string, max int, window time.Duration) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.prune(key, now, window)) < max
}

func (l *limiter) hit(key string) {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	l.hits[key] = append(l.hits[key], now)
	if len(l.hits) > 4096 {
		for k, v := range l.hits {
			if len(v) == 0 || now.Sub(v[len(v)-1]) > time.Hour {
				delete(l.hits, k)
			}
		}
	}
}

// clear forgives a key. Called when the caller proves who they are, so a few
// typos before a correct password leave nothing behind.
func (l *limiter) clear(keys ...string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, k := range keys {
		delete(l.hits, k)
	}
}

// prune drops expired entries. Callers hold the lock.
func (l *limiter) prune(key string, now time.Time, window time.Duration) []time.Time {
	kept := l.hits[key][:0]
	for _, t := range l.hits[key] {
		if now.Sub(t) < window {
			kept = append(kept, t)
		}
	}
	l.hits[key] = kept
	return kept
}

// clientIP is what the rate limiter counts against.
//
// Cf-Connecting-Ip first, because the published path is Cloudflare Tunnel and
// that header is the only one carrying the actual visitor. Traefik replaces
// X-Forwarded-For with its own peer address unless told to trust the sender,
// so on a tunnelled request that header reads as cloudflared's container
// address. Everyone on the internet then shares one bucket, which is worse
// than it sounds: it is not just poor attribution, it lets one attacker spend
// the whole allowance and lock every other account out of the login.
//
// Both headers are still only as good as the hop that set them. A caller
// reaching this container directly on proxy-net can put anything in either,
// which lets it dodge its own per-address bucket, so every limit that matters
// has a second bucket keyed on something the caller does not choose: the
// username, or a global ceiling.
func clientIP(r *http.Request) string {
	if cf := strings.TrimSpace(r.Header.Get("Cf-Connecting-Ip")); cf != "" {
		return cf
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if first, _, ok := strings.Cut(xff, ","); ok {
			return strings.TrimSpace(first)
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ── The gate ──────────────────────────────────────────────────────────────────

// requireAuth wraps the API mux. The auth routes are registered on the outer
// mux instead, where their exact patterns beat the "/api/" prefix, so the set
// of unauthenticated routes is the list in registerAuthRoutes and nothing
// else can join it by being added to the wrong file.
func requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		on, err := authEnabled()
		if err != nil {
			log.Printf("auth: %v", err)
			writeErr(w, http.StatusServiceUnavailable,
				"The dashboard cannot read its accounts, so it will not serve anything. "+
					"Check the agent with: sudo corex manage agent test")
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
		next.ServeHTTP(w, r)
	})
}

// ── Handlers ──────────────────────────────────────────────────────────────────

// readJSONBody decodes a small JSON body from a POST.
//
// There is no CSRF token, and that is a decision rather than an omission. The
// session cookie is SameSite=Lax, so a cross-site POST carries no cookie at
// all, and every state-changing route here is a POST with a JSON body, which
// an HTML form cannot produce. A token would add a second mechanism doing the
// first one's job.
func readJSONBody(w http.ResponseWriter, r *http.Request, dst interface{}) bool {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return false
	}
	// 64KB is far more than any of these bodies, and stops a 128MB container
	// being emptied by one request.
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
	if err := dec.Decode(dst); err != nil {
		writeErr(w, http.StatusBadRequest, "could not read the request")
		return false
	}
	return true
}

type meResponse struct {
	AuthEnabled   bool   `json:"auth_enabled"`
	Authenticated bool   `json:"authenticated"`
	AwaitingTOTP  bool   `json:"awaiting_totp"`
	Username      string `json:"username"`
	DisplayName   string `json:"display_name"`
	Email         string `json:"email"`
	TOTPEnabled   bool   `json:"totp_enabled"`
	RecoveryLeft  int    `json:"recovery_left"`
}

func authMeHandler(w http.ResponseWriter, r *http.Request) {
	out := meResponse{}
	on, err := authEnabled()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	out.AuthEnabled = on
	if !on {
		writeJSON(w, http.StatusOK, out)
		return
	}
	_, s := currentSession(r)
	if s == nil {
		writeJSON(w, http.StatusOK, out)
		return
	}
	out.Username = s.User
	out.AwaitingTOTP = s.AwaitingTOTP
	out.Authenticated = !s.AwaitingTOTP
	if doc, err := loadUsers(); err == nil {
		if u := doc.Users[s.User]; u != nil {
			out.DisplayName = u.DisplayName
			out.Email = u.Email
			out.TOTPEnabled = u.TOTP.Enabled
			for _, c := range u.TOTP.Recovery {
				if !c.Used {
					out.RecoveryLeft++
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func authLoginHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	body.Username = strings.ToLower(strings.TrimSpace(body.Username))

	ip := clientIP(r)
	// Three buckets, counting failures only. The address one is the
	// fair-to-everyone limit; the username one still applies when the address
	// is forged or shared; the global one is the floor a forger cannot get
	// under, since anything reaching this container directly can put whatever
	// it likes in X-Forwarded-For.
	ipKey, userKey := "login:ip:"+ip, "login:user:"+body.Username
	if !limits.check(ipKey, 10, 15*time.Minute) ||
		!limits.check(userKey, 5, 15*time.Minute) ||
		!limits.check("login:all", 60, 15*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts, wait a few minutes")
		return
	}
	refuse := func() {
		limits.hit(ipKey)
		limits.hit(userKey)
		limits.hit("login:all")
		writeErr(w, http.StatusUnauthorized, "that username and password do not match")
	}

	doc, err := loadUsers()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	u := doc.Users[body.Username]
	if u == nil {
		dummyVerify(body.Password)
		refuse()
		return
	}
	if !verifyHash(u.Password, body.Password) {
		refuse()
		return
	}
	limits.clear(ipKey, userKey)

	if err := startSession(w, body.Username, u.TOTP.Enabled); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not start a session")
		return
	}
	log.Printf("auth: %s signed in from %s", body.Username, ip)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok":            true,
		"awaiting_totp": u.TOTP.Enabled,
		"display_name":  u.DisplayName,
	})
}

// authTOTPHandler completes a login. It accepts a six-digit code or one of the
// single-use recovery codes, because a phone that is lost or wiped is the
// common case and the alternative is an SSH session.
func authTOTPHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	id, s := currentSession(r)
	if s == nil {
		writeErr(w, http.StatusUnauthorized, "sign in again")
		return
	}
	if !s.AwaitingTOTP {
		writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
		return
	}
	totpKey := "totp:" + id
	if !limits.check(totpKey, 10, 5*time.Minute) ||
		!limits.check("totp:all", 60, 5*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many codes, wait a few minutes")
		return
	}
	wrongCode := func(msg string) {
		limits.hit(totpKey)
		limits.hit("totp:all")
		writeErr(w, http.StatusUnauthorized, msg)
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, err := loadUsers()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	u := doc.Users[s.User]
	if u == nil || !u.TOTP.Enabled {
		writeErr(w, http.StatusUnauthorized, "sign in again")
		return
	}

	code := strings.TrimSpace(body.Code)
	if counter, ok := totpCheck(u.TOTP.Secret, code, time.Now()); ok {
		totpUsed.Lock()
		last, seen := totpUsed.m[s.User]
		if seen && counter <= last {
			totpUsed.Unlock()
			wrongCode("that code has already been used, wait for the next one")
			return
		}
		totpUsed.m[s.User] = counter
		totpUsed.Unlock()
		sessions.Lock()
		s.AwaitingTOTP = false
		sessions.Unlock()
		limits.clear(totpKey)
		writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
		return
	}

	// A recovery code. Marked used before the reply, so a code cannot be
	// spent twice by two requests arriving together.
	upper := strings.ToUpper(code)
	for i := range u.TOTP.Recovery {
		if u.TOTP.Recovery[i].Used {
			continue
		}
		if verifyHash(u.TOTP.Recovery[i].hashRecord, upper) {
			u.TOTP.Recovery[i].Used = true
			if err := saveUsers(doc); err != nil {
				writeErr(w, http.StatusServiceUnavailable, err.Error())
				return
			}
			sessions.Lock()
			s.AwaitingTOTP = false
			sessions.Unlock()
			limits.clear(totpKey)
			left := 0
			for _, c := range u.TOTP.Recovery {
				if !c.Used {
					left++
				}
			}
			log.Printf("auth: %s used a recovery code, %d left", s.User, left)
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"ok": true, "used_recovery": true, "recovery_left": left,
			})
			return
		}
	}
	wrongCode("that code is not right")
}

func authLogoutHandler(w http.ResponseWriter, r *http.Request) {
	clearSession(w, r)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

// requireUser is the shared preamble of every signed-in account action: a
// live session, and the account it names still existing.
func requireUser(w http.ResponseWriter, r *http.Request) (*usersDoc, *authUser, *session, bool) {
	_, s := currentSession(r)
	if s == nil || s.AwaitingTOTP {
		writeErr(w, http.StatusUnauthorized, "sign in to continue")
		return nil, nil, nil, false
	}
	doc, err := loadUsers()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return nil, nil, nil, false
	}
	u := doc.Users[s.User]
	if u == nil {
		clearSession(w, r)
		writeErr(w, http.StatusUnauthorized, "that account no longer exists")
		return nil, nil, nil, false
	}
	return doc, u, s, true
}

func checkPassword(p string) error {
	if len(p) < minPasswordLen {
		return fmt.Errorf("the password must be at least %d characters", minPasswordLen)
	}
	if len(p) > maxPasswordLen {
		return fmt.Errorf("the password must be at most %d characters", maxPasswordLen)
	}
	return nil
}

func authPasswordHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Current string `json:"current"`
		New     string `json:"new"`
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
	// One bucket shared with totp/disable below: both prove the same password,
	// so counting them separately would double the guesses allowed. Failures
	// only, as on the login path.
	pwKey := "passwd:" + s.User
	if !limits.check(pwKey, 10, 15*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts, wait a few minutes")
		return
	}
	if !verifyHash(u.Password, body.Current) {
		limits.hit(pwKey)
		writeErr(w, http.StatusForbidden, "the current password is not right")
		return
	}
	if err := checkPassword(body.New); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	rec, err := makeHash(body.New, passwordIterations)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not hash the password")
		return
	}
	u.Password = rec
	u.PasswordChanged = time.Now().Unix()
	u.Reset = nil
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	// Everywhere but here. A password change that leaves someone else's
	// session alive has not taken the account back.
	id, _ := currentSession(r)
	dropSessionsFor(s.User, id)
	log.Printf("auth: %s changed their password", s.User)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func authProfileHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DisplayName string `json:"display_name"`
		Email       string `json:"email"`
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
	name := strings.TrimSpace(body.DisplayName)
	if name == "" {
		name = s.User
	}
	if len(name) > 64 {
		name = name[:64]
	}
	email := strings.TrimSpace(body.Email)
	if email != "" && (!strings.Contains(email, "@") || strings.ContainsAny(email, " \t")) {
		writeErr(w, http.StatusBadRequest, "that does not look like an email address")
		return
	}
	u.DisplayName = name
	u.Email = email
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "display_name": name, "email": email,
	})
}

// authTOTPBeginHandler hands out a secret and stores it as pending. Nothing is
// enforced until a code proves the phone actually has it, so an abandoned
// enrolment cannot lock anyone out.
func authTOTPBeginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	doc, u, s, ok := requireUser(w, r)
	if !ok {
		return
	}
	if u.TOTP.Enabled {
		writeErr(w, http.StatusConflict,
			"two-factor is already on. Turn it off first, or reset it from SSH with "+
				"`sudo corex manage dashboard-user totp-reset "+s.User+"`.")
		return
	}
	secret, err := newTOTPSecret()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not generate a secret")
		return
	}
	u.TOTP.Pending = secret
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"secret": secret,
		"uri":    totpURI(s.User, secret, loadState().Domain),
	})
}

func authTOTPEnableHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
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
	if u.TOTP.Pending == "" {
		writeErr(w, http.StatusBadRequest, "start the enrolment again")
		return
	}
	enrolKey := "enrol:" + s.User
	if !limits.check(enrolKey, 10, 5*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many codes, wait a few minutes")
		return
	}
	counter, valid := totpCheck(u.TOTP.Pending, body.Code, time.Now())
	if !valid {
		limits.hit(enrolKey)
		writeErr(w, http.StatusBadRequest,
			"that code is not right. Check the phone's clock if it keeps failing.")
		return
	}

	plain := make([]string, 0, recoveryCodeCount)
	stored := make([]recoveryCode, 0, recoveryCodeCount)
	for i := 0; i < recoveryCodeCount; i++ {
		a, err1 := randomCode(5)
		b, err2 := randomCode(5)
		if err1 != nil || err2 != nil {
			writeErr(w, http.StatusInternalServerError, "could not generate recovery codes")
			return
		}
		code := a + "-" + b
		rec, err := makeHash(code, tokenIterations)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "could not hash the recovery codes")
			return
		}
		plain = append(plain, code)
		stored = append(stored, recoveryCode{hashRecord: rec})
	}

	u.TOTP = totpConfig{Enabled: true, Secret: u.TOTP.Pending, Recovery: stored}
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	// The enrolling code counts as spent, so it cannot also be a login.
	totpUsed.Lock()
	totpUsed.m[s.User] = counter
	totpUsed.Unlock()
	log.Printf("auth: %s turned on two-factor", s.User)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "recovery_codes": plain,
	})
}

func authTOTPDisableHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
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
	pwKey := "passwd:" + s.User
	if !limits.check(pwKey, 10, 15*time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts, wait a few minutes")
		return
	}
	if !verifyHash(u.Password, body.Password) {
		limits.hit(pwKey)
		writeErr(w, http.StatusForbidden, "that password is not right")
		return
	}
	u.TOTP = totpConfig{Enabled: false}
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	log.Printf("auth: %s turned off two-factor", s.User)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

// authResetRequestHandler asks the agent to mail a code.
//
// The reply is the same whatever happened: the account may not exist, may have
// no address on file, or may have asked a moment ago. Saying which turns this
// form into a way of finding out who has an account here.
func authResetRequestHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	username := strings.ToLower(strings.TrimSpace(body.Username))
	ip := clientIP(r)
	if !limits.allow("reset:ip:"+ip, 5, time.Hour) ||
		!limits.allow("reset:all", 30, time.Hour) {
		writeErr(w, http.StatusTooManyRequests, "too many requests, try again later")
		return
	}
	res, err := agentCall(map[string]interface{}{
		"action": "auth-reset", "username": username,
	}, 60*time.Second)
	if err != nil {
		log.Printf("auth: reset request for %q failed: %v", username, err)
	} else if !agentOK(res) {
		// The one failure worth showing: no relay is configured at all, which
		// is an operator problem and not a fact about this username.
		log.Printf("auth: reset request for %q refused: %s", username, agentString(res, "error"))
		if strings.Contains(agentString(res, "error"), "mail relay") {
			writeErr(w, http.StatusServiceUnavailable,
				"This box has no outbound mail relay, so a code cannot be sent. "+
					"Run `sudo corex manage mail-setup`, or reset the password from SSH "+
					"with `sudo corex manage dashboard-user passwd <username>`.")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func authResetCompleteHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Code     string `json:"code"`
		Password string `json:"password"`
	}
	if !readJSONBody(w, r, &body) {
		return
	}
	username := strings.ToLower(strings.TrimSpace(body.Username))
	ip := clientIP(r)
	doKey := "resetdo:ip:" + ip
	if !limits.check(doKey, 10, time.Hour) ||
		!limits.check("resetdo:all", 60, time.Hour) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts, try again later")
		return
	}
	wrongReset := func(code int, msg string) {
		limits.hit(doKey)
		limits.hit("resetdo:all")
		writeErr(w, code, msg)
	}
	if err := checkPassword(body.Password); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	storeMu.Lock()
	defer storeMu.Unlock()
	doc, err := loadUsers()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	u := doc.Users[username]
	if u == nil || u.Reset == nil {
		wrongReset(http.StatusForbidden, "that code is not valid")
		return
	}
	if time.Now().Unix() > u.Reset.Expires {
		u.Reset = nil
		_ = saveUsers(doc)
		wrongReset(http.StatusForbidden, "that code has expired, ask for another")
		return
	}
	// A per-code attempt counter on top of the per-address one, because the
	// code is only 40 bits and the address is under the attacker's control.
	if u.Reset.Attempts >= maxResetAttempts {
		u.Reset = nil
		_ = saveUsers(doc)
		wrongReset(http.StatusForbidden, "too many wrong codes, ask for another")
		return
	}
	if !verifyHash(u.Reset.hashRecord, strings.ToUpper(strings.TrimSpace(body.Code))) {
		u.Reset.Attempts++
		_ = saveUsers(doc)
		wrongReset(http.StatusForbidden, "that code is not valid")
		return
	}

	rec, err := makeHash(body.Password, passwordIterations)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not hash the password")
		return
	}
	u.Password = rec
	u.PasswordChanged = time.Now().Unix()
	u.Reset = nil
	if err := saveUsers(doc); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	dropSessionsFor(username, "")
	limits.clear(doKey, "login:user:"+username)
	log.Printf("auth: %s reset their password from %s", username, ip)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func registerAuthRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/auth/me", authMeHandler)
	mux.HandleFunc("/api/auth/login", authLoginHandler)
	mux.HandleFunc("/api/auth/totp", authTOTPHandler)
	mux.HandleFunc("/api/auth/logout", authLogoutHandler)
	mux.HandleFunc("/api/auth/password", authPasswordHandler)
	mux.HandleFunc("/api/auth/profile", authProfileHandler)
	mux.HandleFunc("/api/auth/totp/begin", authTOTPBeginHandler)
	mux.HandleFunc("/api/auth/totp/enable", authTOTPEnableHandler)
	mux.HandleFunc("/api/auth/totp/disable", authTOTPDisableHandler)
	mux.HandleFunc("/api/auth/reset/request", authResetRequestHandler)
	mux.HandleFunc("/api/auth/reset/complete", authResetCompleteHandler)
}
