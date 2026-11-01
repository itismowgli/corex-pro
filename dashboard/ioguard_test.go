package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every refusal happens before the agent is called, so a bad value never
// reaches the privileged side. A limit of five seconds would reboot the
// machine on any slow write, which is the case worth refusing loudly.
func TestIoGuardHandlerRefusesBadSettings(t *testing.T) {
	cases := map[string]string{
		"empty":          `{}`,
		"stall too low":  `{"stall_sec": 5}`,
		"stall too high": `{"stall_sec": 99999}`,
		"grace too low":  `{"boot_grace_sec": 10}`,
		"bad action":     `{"action": "format"}`,
		"unknown field":  `{"devices": "sda"}`,
		"not json":       `reboot please`,
	}
	for name, body := range cases {
		req := httptest.NewRequest(http.MethodPost, "/api/io-guard", strings.NewReader(body))
		rec := httptest.NewRecorder()
		ioGuardHandler(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: want 400, got %d (%s)", name, rec.Code, rec.Body.String())
		}
	}
	req := httptest.NewRequest(http.MethodGet, "/api/io-guard", nil)
	rec := httptest.NewRecorder()
	ioGuardHandler(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET: want 405, got %d", rec.Code)
	}
}
