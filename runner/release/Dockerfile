# Official runner container image, published to GHCR by
# .github/workflows/runner-release.yml on every runner-v* tag. The build
# consumes the exact release-built linux binary through the named `dist`
# build context instead of compiling from source, so the published image
# carries the same attested binary as the release tarballs:
#
#   docker buildx build -f runner/release/Dockerfile \
#     --build-context dist=./dist/image .
#
# where dist/image/linux-<arch>/emisar is the extracted release binary
# (the root .dockerignore deliberately excludes dist/ from the main
# context). The repository root is the main context; dev/runner/Dockerfile
# stays the demo-only from-source variant.
#
# Base images are digest-pinned for reproducible builds. Refresh with:
#   docker buildx imagetools inspect debian:bookworm-slim --format '{{.Manifest.Digest}}'

FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS packset

COPY runner/release/container-packs.txt /src/container-packs.txt
COPY packs /src/packs

RUN mkdir -p /out/packs \
    && while IFS= read -r pack; do \
        case "$pack" in ''|'#'*) continue ;; esac; \
        if [ ! -d "/src/packs/${pack}" ]; then \
            echo "container-packs.txt names a missing pack: ${pack}" >&2; exit 1; \
        fi; \
        cp -R "/src/packs/${pack}" "/out/packs/${pack}"; \
    done < /src/container-packs.txt

FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# Only what the baked packs execute (see container-packs.txt), plus CA
# roots for the TLS dial-out and tini as PID 1. Anything more belongs in
# an operator-built extension image — the image contents are part of the
# runner's capability boundary.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        bind9-dnsutils ca-certificates curl file iproute2 iputils-ping \
        mtr-tiny netcat-openbsd openssl procps sysstat tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    # uid/gid are pinned so volume ownership is documentable (the
    # Kubernetes and container docs cite 65532).
    && groupadd -g 65532 emisar \
    && useradd -u 65532 -g emisar -d /var/lib/emisar -s /usr/sbin/nologin emisar \
    && mkdir -p /etc/emisar /var/lib/emisar /var/log/emisar /opt/emisar/packs \
    && chown -R emisar:emisar /var/lib/emisar /var/log/emisar \
    && chown root:emisar /etc/emisar \
    && chmod 0750 /etc/emisar \
    && chown root:root /opt/emisar/packs \
    && chmod 0755 /opt/emisar/packs

ARG TARGETARCH
COPY --from=dist linux-${TARGETARCH}/emisar /usr/local/bin/emisar
COPY --from=packset --chown=root:root /out/packs /opt/emisar/packs
COPY --chown=root:emisar --chmod=0640 runner/release/container/config.yaml /etc/emisar/config.yaml

# Pack bytes stay immutable to the action runtime user.
RUN test "$(stat -c '%U:%G:%a' /opt/emisar/packs)" = "root:root:755"

# Numeric USER so Kubernetes runAsNonRoot can verify the uid from the
# image; the emisar passwd entry above keeps names in `ps`/`ls` output.
USER 65532:65532
WORKDIR /var/lib/emisar

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/emisar", "connect", "--config", "/etc/emisar/config.yaml"]
