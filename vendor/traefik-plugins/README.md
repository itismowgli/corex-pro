# Vendored Traefik plugins

This tree mirrors the layout Traefik expects under `/plugins-local/src`, so
`lib/services/traefik.sh` installs it with a plain recursive copy and a second
plugin needs no code change.

## Why the source is here at all

Traefik contacts `plugins.traefik.io` at every start for anything declared
under `experimental.plugins`, and when that call fails it disables plugins
entirely. Every router naming one then answers 404 with "invalid middleware
type or middleware does not exist". That happened on a live box: AdGuard was
restarting during a repair, Traefik came up in the DNS gap, and Grafana and
Portainer served 404 for hours while both containers stayed healthy.

Persisting Traefik's download cache does not help. It was measured: with the
cache at 3.3MB, stopping AdGuard and restarting Traefik reproduced the failure
exactly.

`experimental.localPlugins` reads the source from disk and never calls out.
Measured on a throwaway Traefik 3.6.25 whose DNS pointed at an unroutable
address: "Plugins loaded", the middleware enabled, the router enabled.

## Contents

`github.com/sablierapp/sablier-traefik-plugin` at v1.3.0, Apache-2.0, the wake
controller middleware for cold-start services. Traefik interprets the Go source
with Yaegi, so what ships is source rather than a binary. `go.mod` declares no
requirements, so nothing else has to be vendored with it.

The test files, CI workflows and documentation images are left out. The two
files under `assets/` are kept because `.traefik.yml` names them.

## Updating it

Fetch the tag, copy the files this directory already holds, and check the
digests against what Traefik itself downloaded, which lives on an installed
server at `docker-configs/traefik/plugins-storage/archives/`.

```bash
curl -fsSLo /tmp/p.tar.gz \
  https://codeload.github.com/sablierapp/sablier-traefik-plugin/tar.gz/refs/tags/vX.Y.Z
tar xzf /tmp/p.tar.gz -C /tmp
shasum -a 256 /tmp/sablier-traefik-plugin-X.Y.Z/{main.go,config.go,version.go,go.mod,.traefik.yml}
```

`localPlugins` takes no version field, so `version.go` is the only record of
which release is here. Keep this file and that constant saying the same thing.

The digests of the v1.3.0 files vendored here, which match the copy the live
server was running:

```
ad5f19d7c8ed50334a3f39da5e99f263936761b963cc3d2134f9559dcd250574  main.go
72ee0e79ec38d9fbe01d1a72d2868c05f83f2ef5e6a239f15b51dfb44c91e797  config.go
1eba4292fa7973cd0e7fc7acdb591b25aa70b691dc2404d7653492fa842c5c40  version.go
2209796da85180c68319eeb7998730a094ef7324ea76cf004ea2cad0521fb777  go.mod
429a387f232bc2764861e3ad03ff5945102b49fc91dc5679706ef8decaa67b5b  .traefik.yml
4df3c306dddaaf4baffdff5ca820cc679ac8cd6dc263c6a74517783e42fa7a3b  LICENSE
```
