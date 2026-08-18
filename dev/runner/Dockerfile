# Development runner image for the repository demo and integration tests.
# It is not a published product image — that is runner/release/Dockerfile,
# which reuses the release-built binary instead of compiling from source.
# The build context is the repository root because the demo bundles both
# runner/ and packs/.
#
# Base images are digest-pinned for reproducible builds. Refresh with:
#   docker buildx imagetools inspect golang:1.26-alpine --format '{{.Manifest.Digest}}'

FROM golang:1.26-alpine@sha256:3889b425f035be855a72fb4755265311293b6d414521f0a519d819df32222d83 AS builder

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
FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

RUN apt-get update -y \
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
