package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// A session that has stepped up and one that has not are one boolean apart in
// memory, and the difference decides whether a web page can switch this
// machine off. So the window is checked directly rather than only through the
// handlers, which need an agent to answer.

func TestElevationWindow(t *testing.T) {
	for _, tc := range []struct {
		name string
		s    *session
		want bool
	}{
		{"nil session", nil, false},
		{"never elevated", &session{User: "a"}, false},
		{"expired", &session{User: "a", ElevatedUntil: time.Now().Add(-time.Second)}, false},
		{"live", &session{User: "a", ElevatedUntil: time.Now().Add(time.Minute)}, true},
		// A half-finished login must not be able to carry elevation, whatever
		// else is set on it.
		{"awaiting a second factor", &session{
			User: "a", AwaitingTOTP: true,
			ElevatedUntil: time.Now().Add(time.Minute),
		}, false},
	} {
		if got := elevationLeft(tc.s) > 0; got != tc.want {
			t.Fatalf("%s: elevated=%v, want %v", tc.name, got, tc.want)
		}
	}
}

// elevate has to find the session by cookie. Elevating by username would arm
// every browser holding a session for that account, which is the opposite of
// proving that someone is present at this one.
func TestElevateOnlyTouchesTheCallersSession(t *testing.T) {
	sessions.Lock()
	sessions.m = map[string]*session{
		"here":      {User: "admin", Seen: time.Now(), Created: time.Now()},
		"elsewhere": {User: "admin", Seen: time.Now(), Created: time.Now()},
	}
	sessions.Unlock()
	t.Cleanup(func() {
		sessions.Lock()
		sessions.m = map[string]*session{}
		sessions.Unlock()
	})

	r := httptest.NewRequest(http.MethodPost, "/api/auth/stepup", nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: "here"})
	if left := elevate(r, "password"); left != elevationTTL {
		t.Fatalf("elevate returned %v, want %v", left, elevationTTL)
	}

	// Read under the lock and release it before calling anything that takes
	// it again. dropElevation does, and holding it across that call
	// deadlocks the test rather than the code.
	read := func(id string) *session {
		sessions.Lock()
		defer sessions.Unlock()
		s := sessions.m[id]
		copied := *s
		return &copied
	}

	here := read("here")
	if elevationLeft(here) <= 0 {
		t.Fatal("the caller's own session was not elevated")
	}
	if here.ElevatedBy != "password" {
		t.Fatalf("factor recorded as %q", here.ElevatedBy)
	}
	if elevationLeft(read("elsewhere")) > 0 {
		t.Fatal("another browser holding a session for the same account was elevated too")
	}

	// A password change has to take the window with it, or the elevation the
	// old password bought outlives the password.
	dropElevation("admin")
	if elevationLeft(read("here")) > 0 {
		t.Fatal("dropElevation left the window open")
	}
}

// The refusal has to be distinguishable from every other 403, because the
// client answers this one by asking for a factor and retrying. A bare status
// code cannot say which kind of no it is.
func TestRequireElevatedRefusalCarriesTheFlag(t *testing.T) {
	authStateMu.Lock()
	authConfigured = true
	authEnabledCache = true
	authEnabledCheckAt = time.Now()
	authStateMu.Unlock()
	t.Cleanup(func() {
		authStateMu.Lock()
		authConfigured = false
		authEnabledCache = false
		authEnabledCheckAt = time.Time{}
		authStateMu.Unlock()
	})

	sessions.Lock()
	sessions.m = map[string]*session{
		"plain": {User: "admin", Seen: time.Now(), Created: time.Now()},
		"armed": {User: "admin", Seen: time.Now(), Created: time.Now(),
			ElevatedUntil: time.Now().Add(time.Minute), ElevatedBy: "passkey"},
	}
	sessions.Unlock()
	t.Cleanup(func() {
		sessions.Lock()
		sessions.m = map[string]*session{}
		sessions.Unlock()
	})

	reached := false
	h := requireElevated(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		reached = true
		w.WriteHeader(http.StatusOK)
	}))

	call := func(cookie string) *httptest.ResponseRecorder {
		reached = false
		r := httptest.NewRequest(http.MethodPost, "/api/power/shutdown", nil)
		if cookie != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: cookie})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	w := call("plain")
	if w.Code != http.StatusForbidden {
		t.Fatalf("a session with no step-up got %d, want 403", w.Code)
	}
	if reached {
		t.Fatal("the guarded handler ran without an elevation")
	}
	var body struct {
		Error             string `json:"error"`
		ElevationRequired bool   `json:"elevation_required"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.ElevationRequired {
		t.Fatalf("the refusal did not say elevation was the reason: %s", w.Body.String())
	}
	if body.Error == "" {
		t.Fatal("the refusal carried no message for the operator")
	}

	if w := call(""); w.Code != http.StatusUnauthorized {
		t.Fatalf("no session at all got %d, want 401", w.Code)
	}
	if reached {
		t.Fatal("the guarded handler ran with no session")
	}

	if w := call("armed"); w.Code != http.StatusOK || !reached {
		t.Fatalf("an elevated session got %d (reached=%v), want 200", w.Code, reached)
	}
}
