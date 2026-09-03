# CoreX Dashboard, built in three stages so the runtime image carries neither
# Node nor Go: an Alpine base, the Docker CLI, and one static binary with the
# whole frontend inside it.
#
# Nothing is fetched at runtime. The previous version pulled Tailwind from
# cdn.tailwindcss.com and htmx from unpkg, which made the page that tells you
# the box is in trouble depend on the internet being fine, and an htmx
# integrity hash that did not match the file meant every browser refused to run
# it, so no button on the page did anything.

# ── Stage 1: the single-page app ─────────────────────────────────────────────
# Node 22, not 20. Node 20 reached end of life in April 2026, and jsdom, which
# the render check needs, pulls in an undici that fails to import on it:
#
#   TypeError: webidl.util.markAsUncloneable is not a function
#     at Object.<anonymous> (/web/node_modules/jsdom/lib/api.js:12:33)
#
# That failure only appears inside the image, because a developer machine
# running a current Node imports it fine, which is a good argument for the
# image build being the only supported build path.
FROM node:22-alpine AS web

# Both compilers in this file are Go programs and both size their parallelism
# from the CPU count: esbuild, which vite uses to transform, and the Go
# compiler itself. Unbounded, this build took a Ryzen mini server from 62C to
# 93.4C, which is a degree and a half from the thermal guardian's shed
# threshold and five from where the hardware cuts its own power (gotcha #17
# and #31). nice sets priority, not heat; this sets heat.
ENV GOMAXPROCS=4

WORKDIR /web

# Lockfile first, so a source-only change does not reinstall the dependencies.
COPY web/package.json web/package-lock.json ./
# ci, not install: the lockfile is the pinned set, and install would quietly
# resolve something newer at build time.
RUN npm ci --no-audit --no-fund

COPY web/ ./
# Runs tsc --noEmit and then vite build, so a type error fails the image build
# rather than shipping a blank tab.
RUN npm run build

# ── Stage 2: the Go binary, with the built assets embedded ───────────────────
# Go 1.25. Two reasons, in the order they arrived: crypto/pbkdf2 entered the
# standard library in 1.24 and the login hashes passwords with it, and
# go-webauthn requires 1.25. Alpine also needs git here, because the module
# download fetches from source hosts.
FROM golang:1.25-alpine AS builder

# Same reason as the web stage: bound the compiler's parallelism.
ENV GOMAXPROCS=4

# git, because module resolution fetches from source hosts.
RUN apk add --no-cache git

WORKDIR /build

# go.sum is committed and copied, so the build resolves to exactly the
# versions that were tested rather than whatever is current. The one external
# dependency is the WebAuthn implementation; see dashboard/passkey.go for why
# that is the single place a library beats standard library here.
COPY go.mod go.sum ./
RUN go mod download
COPY main.go auth.go overview.go passkey.go auth_test.go ./
COPY --from=web /web/dist ./web/dist

# The tests run here, not somewhere else, for the same reason the frontend's
# render check does: a hash record written by agent/corex_users.py and read by
# auth.go is a contract neither language can check alone, and getting it wrong
# looks exactly like a correct password being refused. A tenth of a second.
RUN go vet ./... && go test ./...

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o corex-dashboard .

# ── Stage 3: runtime ─────────────────────────────────────────────────────────
FROM alpine:3.20

# bash: runs corex-manage.sh
# docker-cli: docker ps, docker logs
# jq: corex-manage.sh reads state.json with it. Without jq every state_get
#     returned empty, so `status --plain` printed nothing and the dashboard
#     fell back to deriving health from `docker ps`.
# ca-certificates: HTTPS from the shell scripts
RUN apk add --no-cache bash docker-cli jq ca-certificates

WORKDIR /app

COPY --from=builder /build/corex-dashboard .

EXPOSE 8080

# nobody, not root. The dashboard reaches privileged actions through the agent
# socket, whose group membership is the actual boundary; see lib/agent.sh and
# CLAUDE.md gotcha #30.
USER nobody

ENTRYPOINT ["/app/corex-dashboard"]
