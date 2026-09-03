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
FROM node:20-alpine AS web

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
FROM golang:1.22-alpine AS builder

WORKDIR /build

# No external Go dependencies, stdlib only, so there is no go.sum.
COPY go.mod ./
COPY main.go ./
COPY --from=web /web/dist ./web/dist

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
