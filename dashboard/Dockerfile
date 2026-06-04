# CoreX Dashboard — Multi-stage Docker build
# Final image: ~20MB (alpine + bash + docker-cli + Go binary with embedded assets)
#
# Stage 1: Build the Go binary (templates/static are embedded at compile time)
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Copy module files first for layer caching
COPY go.mod ./

# No external dependencies — stdlib only. No go.sum needed.

# Copy source
COPY main.go ./
COPY templates/ templates/
COPY static/    static/

# Build a static binary: no CGO, stripped debug info
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o corex-dashboard .

# ── Stage 2: Runtime image ──────────────────────────────────────────────────
FROM alpine:3.20

# bash: needed to execute corex-manage.sh
# docker-cli: needed for `docker ps`, `docker logs`, etc.
# ca-certificates: needed for HTTPS calls from shell scripts
RUN apk add --no-cache bash docker-cli ca-certificates

WORKDIR /app

COPY --from=builder /build/corex-dashboard .

# Expose dashboard port (Traefik routes external HTTPS to this)
EXPOSE 8080

# Run as nobody (read-only access to Docker socket + corex files is sufficient)
# The compose file mounts /var/run/docker.sock:ro and /opt/corex-pro:ro
USER nobody

ENTRYPOINT ["/app/corex-dashboard"]
