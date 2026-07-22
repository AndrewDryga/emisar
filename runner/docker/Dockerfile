# Dockerfile for the emisar runner. Two stages:
#
#   builder — compiles the runner binary inside golang:alpine
#   runner  — minimal distroless-ish base + the binary + example packs
#
# Used in dev to test the runner against a local Phoenix server without
# needing to install the binary on the host. Build context is the REPO
# ROOT so the sibling packs/ dir is reachable; the runner source is
# copied from runner/.
#
#   docker build -f runner/docker/Dockerfile -t emisar/runner .
#   docker run --rm \
#     -e EMISAR_AUTH_KEY=emkey-auth-... \
#     -e EMISAR_URL=http://host.docker.internal:4000 \
#     --add-host=host.docker.internal:host-gateway \
#     emisar/runner

# --- builder -------------------------------------------------------
#
# Base images are digest-pinned for supply-chain integrity: the tag
# documents the human-readable version, the @sha256 pins the exact
# multi-arch index so a rebuild is reproducible and a moved/republished
# tag can't swap the base out from under us. Refresh (when bumping a tag
# or pulling upstream security patches) with:
#   docker buildx imagetools inspect golang:1.26-alpine --format '{{.Manifest.Digest}}'
# then paste the new digest below (keep the tag in sync).

FROM golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder

WORKDIR /src

# Cache deps in a separate layer
COPY runner/go.mod runner/go.sum ./
RUN go mod download

# Source — the runner module's full source tree
COPY runner/ ./

# Version stamped into the binary (reported to the cloud + shown in the UI).
# Defaults to "dev"; docker-compose overrides it so the live runner matches
# the version the seed pins on its row.
ARG RUNNER_VERSION=dev

# Strip symbols + omit DWARF for a smaller binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${RUNNER_VERSION}" \
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

# Digest-pinned (refresh via the buildx imagetools command noted above).
FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates tini procps grep coreutils bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r emisar \
    && useradd -r -g emisar -d /var/lib/emisar -s /sbin/nologin emisar \
    && mkdir -p /etc/emisar /var/lib/emisar /var/log/emisar /opt/emisar/packs /var/log/nginx \
    && chown -R emisar:emisar /var/lib/emisar /var/log/emisar \
    && chown root:emisar /etc/emisar \
    && chmod 0750 /etc/emisar \
    && chown root:root /opt/emisar/packs \
    && chmod 0755 /opt/emisar/packs

# DEV-ONLY: the docker-compose demo stack flips DEV_TOOLS=true to add the
# client binaries the seeded demo packs shell out to (postgres -> psql,
# caddy / HTTP reads -> curl, redis -> redis-cli, time-sync -> chronyc,
# network probes -> mtr/dig). Off by default so a real or self-hosted
# runner image stays minimal — operators install only the binaries the
# packs they actually run require. Packs whose client can never be real
# in a container (a JDK, tailscaled, ipmitool against a BMC) stay
# advertised-but-unavailable, which is the honest fleet shape.
ARG DEV_TOOLS=false
RUN if [ "$DEV_TOOLS" = "true" ]; then \
        apt-get update -y \
        && apt-get install -y --no-install-recommends \
            postgresql-client curl redis-tools chrony mtr-tiny bind9-dnsutils \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=builder /out/emisar /usr/local/bin/emisar
COPY --chown=root:root packs /opt/emisar/packs
COPY --chown=root:emisar runner/docker/config.yaml /etc/emisar/config.yaml

# Actions execute as the runtime user. Keep the runner's admission/signing
# configuration and trusted pack bytes immutable to that same user, or an
# allowed action could alter the next boot's security policy.
RUN chmod 0640 /etc/emisar/config.yaml \
    && test "$(stat -c '%U:%G:%a' /etc/emisar/config.yaml)" = "root:emisar:640" \
    && test "$(stat -c '%U:%G:%a' /opt/emisar/packs)" = "root:root:755"

USER emisar
WORKDIR /var/lib/emisar

# tini reaps zombies cleanly when child processes spawn under the runner.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/emisar", "connect", "--config", "/etc/emisar/config.yaml"]
