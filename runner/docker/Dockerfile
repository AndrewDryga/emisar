# Dockerfile for the emisar runner. Two stages:
#
#   builder — compiles the runner binary inside golang:alpine
#   runner  — minimal distroless-ish base + the binary + example packs
#
# Used in dev to test the runner against a local Phoenix server without
# needing to install the binary on the host. Build context is the
# runner module (runner/), so COPY paths are relative to that.
#
#   docker build -f runner/docker/Dockerfile -t emisar/runner runner/
#   docker run --rm \
#     -e EMISAR_AUTH_KEY=emkey-auth-... \
#     -e EMISAR_URL=http://host.docker.internal:4000 \
#     --add-host=host.docker.internal:host-gateway \
#     emisar/runner

# --- builder -------------------------------------------------------

FROM golang:1.26-alpine AS builder

WORKDIR /src

# Cache deps in a separate layer
COPY go.mod go.sum ./
RUN go mod download

# Source — the runner module's full source tree
COPY . ./

# Strip symbols + omit DWARF for a smaller binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=dev" \
    -o /out/emisar \
    .

# --- runner --------------------------------------------------------
#
# Debian (not Alpine) on purpose: real GNU coreutils, grep, stat,
# procps `uptime`, and the standard /var/log directory layout — what
# the linux-core action pack expects. Alpine ships BusyBox flavors of
# all of these that handle long-form GNU flags differently (`grep
# --max-count` vs `-m`, etc.). Sticks with debian:bookworm-slim to
# share base layers with the portal image.

FROM debian:bookworm-slim

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates tini procps grep coreutils bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r emisar \
    && useradd -r -g emisar -d /var/lib/emisar -s /sbin/nologin emisar \
    && mkdir -p /etc/emisar /var/lib/emisar /var/log/emisar /opt/emisar/packs /var/log/nginx \
    && chown -R emisar:emisar /etc/emisar /var/lib/emisar /var/log/emisar /opt/emisar

COPY --from=builder /out/emisar /usr/local/bin/emisar
COPY --chown=emisar:emisar examples/packs /opt/emisar/packs
COPY --chown=emisar:emisar docker/config.yaml /etc/emisar/config.yaml

USER emisar
WORKDIR /var/lib/emisar

# tini reaps zombies cleanly when child processes spawn under the runner.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/emisar", "connect", "--config", "/etc/emisar/config.yaml"]
