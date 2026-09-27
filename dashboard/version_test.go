package main

import "testing"

// Every reference here was taken off the running box with
// `docker ps -a --format '{{.Image}}'`, for the reason in gotcha #38: a
// parser tested against invented input is tested against the author's
// assumptions. The bare image IDs are real, left by removed stacks, and the
// first version of imageVersion reported them as "latest".
func TestImageVersion(t *testing.T) {
	cases := map[string]string{
		"adguard/adguardhome:latest":                                     "latest",
		"authelia/authelia:4.39":                                         "4.39",
		"calcom/cal.com:v6.2.0":                                          "v6.2.0",
		"corex-dashboard:local":                                          "local",
		"ghcr.io/immich-app/immich-server:v3.1.0":                        "v3.1.0",
		"ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0": "14-vectorchord0.4.3-pgvectors0.2.0",
		"ghcr.io/ridafkih/keeper-standalone:2.18.7":                      "2.18.7",
		"jellyfin/jellyfin:12.0":                                         "12.0",
		"nextcloud:34":                                                   "34",
		"postgres:15-alpine":                                             "15-alpine",
		"prom/prometheus:v3.14.0":                                        "v3.14.0",

		// Untagged images, which this box has several of.
		"02f2cc4882f8": "",
		"a3b7f434b2dc": "",

		// Shapes that are not on this box but that the rule has to survive.
		"nextcloud":                    "latest",
		"registry:5000/app":            "latest",
		"repo@sha256:abcdef0123456789": "abcdef012345",
		"":                             "",
	}
	for ref, want := range cases {
		if got := imageVersion(ref); got != want {
			t.Errorf("imageVersion(%q) = %q, want %q", ref, got, want)
		}
	}
}
