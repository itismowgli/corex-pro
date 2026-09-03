package main

import (
	"encoding/json"
	"testing"
	"time"
)

// The user store is written by Python and read by Go, so a disagreement about
// the hash record is invisible to either side's own tests and shows up as a
// correct password being refused. These vectors came out of
// agent/corex_users.py and are checked here.
//
// Regenerate them with:
//
//	python3 -c 'import sys; sys.path.insert(0, "agent"); import corex_users as cu, json; \
//	  print(json.dumps({"password": "correct horse battery staple", \
//	    "record": cu.hash_secret("correct horse battery staple", 120000), \
//	    "code": "HZK9V-S52LK", "code_record": cu.hash_secret("HZK9V-S52LK", 120000)}, indent=1))'
const pythonVectors = `{
 "password": "correct horse battery staple",
 "record": {
  "algo": "pbkdf2-sha256",
  "iterations": 120000,
  "salt": "zcE9x3WshxSSnuv7b2Jwgw==",
  "hash": "kZFOv8ojMKqEyKw1g/3WqsUjfQ5WhpFZFUcL9N+4aZI="
 },
 "code_record": {
  "algo": "pbkdf2-sha256",
  "iterations": 120000,
  "salt": "Fir/c7SvZlStkd4ctKN9vg==",
  "hash": "0aA8XvVjVG7FP9xuHkixTnmXwMdN3CaBOQwi7XTLgB4="
 },
 "code": "HZK9V-S52LK"
}`

func TestPythonVectors(t *testing.T) {
	var v struct {
		Password   string     `json:"password"`
		Record     hashRecord `json:"record"`
		Code       string     `json:"code"`
		CodeRecord hashRecord `json:"code_record"`
	}
	if err := json.Unmarshal([]byte(pythonVectors), &v); err != nil {
		t.Fatal(err)
	}
	if !verifyHash(v.Record, v.Password) {
		t.Fatal("a password hashed by Python does not verify in Go")
	}
	if verifyHash(v.Record, v.Password+"x") {
		t.Fatal("a wrong password verified")
	}
	if !verifyHash(v.CodeRecord, v.Code) {
		t.Fatal("a recovery code hashed by Python does not verify in Go")
	}
}

func TestHashRoundTrip(t *testing.T) {
	rec, err := makeHash("hunter2hunter2", tokenIterations)
	if err != nil {
		t.Fatal(err)
	}
	if rec.Algo != hashAlgo || rec.Iterations != tokenIterations {
		t.Fatalf("record not self-describing: %+v", rec)
	}
	if !verifyHash(rec, "hunter2hunter2") || verifyHash(rec, "hunter2hunter3") {
		t.Fatal("round trip failed")
	}
	// A corrupted record must fail closed rather than becoming a free pass.
	for _, bad := range []hashRecord{
		{},
		{Algo: hashAlgo, Iterations: 1, Salt: rec.Salt, Hash: rec.Hash},
		{Algo: "md5", Iterations: rec.Iterations, Salt: rec.Salt, Hash: rec.Hash},
		{Algo: hashAlgo, Iterations: rec.Iterations, Salt: "!!", Hash: rec.Hash},
		{Algo: hashAlgo, Iterations: rec.Iterations, Salt: rec.Salt, Hash: ""},
	} {
		if verifyHash(bad, "hunter2hunter2") {
			t.Fatalf("a broken record verified: %+v", bad)
		}
	}
}

// RFC 6238's own test vector, so the TOTP implementation is checked against
// the specification rather than against itself.
func TestTOTPAgainstRFC6238(t *testing.T) {
	// The RFC's SHA-1 key is the ASCII "12345678901234567890".
	secret := b32.EncodeToString([]byte("12345678901234567890"))
	for _, tc := range []struct {
		unix int64
		want string
	}{
		{59, "287082"},
		{1111111109, "081804"},
		{1234567890, "005924"},
		{2000000000, "279037"},
	} {
		at := time.Unix(tc.unix, 0)
		if _, ok := totpCheck(secret, tc.want, at); !ok {
			t.Fatalf("RFC vector %d (%s) was rejected", tc.unix, tc.want)
		}
		if _, ok := totpCheck(secret, "000000", at); ok && tc.want != "000000" {
			t.Fatalf("an arbitrary code was accepted at %d", tc.unix)
		}
	}
	// The window is one step either side and no wider.
	at := time.Unix(1234567890, 0)
	if _, ok := totpCheck(secret, "005924", at.Add(31*time.Second)); !ok {
		t.Fatal("a code one step old was rejected")
	}
	if _, ok := totpCheck(secret, "005924", at.Add(95*time.Second)); ok {
		t.Fatal("a code three steps old was accepted")
	}
}

func TestRateLimiter(t *testing.T) {
	l := &limiter{hits: map[string][]time.Time{}}
	for i := 0; i < 3; i++ {
		if !l.allow("k", 3, time.Minute) {
			t.Fatalf("attempt %d was refused inside the limit", i)
		}
	}
	if l.allow("k", 3, time.Minute) {
		t.Fatal("the limit did not hold")
	}
	if !l.allow("other", 3, time.Minute) {
		t.Fatal("a different key was affected")
	}
}

func TestTOTPURICarriesTheParameters(t *testing.T) {
	uri := totpURI("parth", "ABCDEFGH", "example.com")
	for _, want := range []string{"otpauth://totp/", "secret=ABCDEFGH", "algorithm=SHA1", "digits=6", "period=30"} {
		if !contains(uri, want) {
			t.Fatalf("%q is missing from %q", want, uri)
		}
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
