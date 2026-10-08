# Development runner image for the repository demo and integration tests.
# It is not a published product image — that is runner/release/Dockerfile,
# which reuses the release-built binary instead of compiling from source.
# The build context is the repository root because the demo bundles both
# runner/ and packs/.
#
# Base images are digest-pinned for reproducible builds. Refresh with:
#   docker buildx imagetools inspect golang:1.27.1-alpine3.24 --format '{{.Manifest.Digest}}'

FROM golang:1.27.1-alpine3.24@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS builder

WORKDIR /src

COPY runner/go.mod runner/go.sum ./
RUN go mod download

COPY runner/ ./

# Compose overrides this so the live demo runners match their seeded version.
ARG RUNNER_VERSION=dev

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${RUNNER_VERSION}" \
    -o /out/emisar \
    .

# Debian provides the GNU utilities expected by the demo's Linux packs.
FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

RUN apt-get update -y \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash bind9-dnsutils ca-certificates chrony coreutils curl grep \
        mtr-tiny postgresql-client procps redis-tools tini \
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

COPY --from=builder /out/emisar /usr/local/bin/emisar
COPY --chown=root:root packs /opt/emisar/packs

# Even in development, pack bytes stay immutable to the action runtime user.
RUN test "$(stat -c '%U:%G:%a' /opt/emisar/packs)" = "root:root:755"

USER emisar
WORKDIR /var/lib/emisar

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/emisar", "connect", "--config", "/etc/emisar/config.yaml"]
