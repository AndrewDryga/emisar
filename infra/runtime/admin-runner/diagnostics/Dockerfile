# Extraction-only artifact. The privileged host never starts this container.
FROM --platform=$BUILDPLATFORM golang:1.27.2-alpine3.24@sha256:85dc1069ac644ea3c527b177303a406eb3358192816cd7f9e5848eb658851673 AS compose
COPY infra/runtime/admin-runner/diagnostics/build-compose.sh /build-compose.sh
RUN --mount=type=cache,id=emisar-diagnostics-compose-go1.27.2-modules,target=/go/pkg/mod,sharing=locked \
    /bin/sh /build-compose.sh

FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS build
COPY portal/docker/debian.sources /etc/apt/sources.list.d/debian.sources
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl chrony dmidecode ethtool iproute2 iputils-ping \
       jq lvm2 mdadm procps python3-ntp smartmontools sysstat util-linux \
       build-essential dpkg-dev autoconf zlib1g-dev \
    && mkdir /ntp-source /sysstat-source /python-source \
    && cd /ntp-source && apt-get download ntpsec \
    && dpkg-deb --extract ntpsec_*.deb extracted \
    && install -m 0755 extracted/usr/bin/ntpq /usr/local/bin/ntpq \
    && cd /sysstat-source && apt-get source sysstat \
    && cd sysstat-* && ./configure --disable-nls --disable-documentation --disable-sensors \
    && make -j2 SA_LIB_DIR=/run/emisar-admin-runner/diagnostics/bin sar sadc iostat \
    && install -m 0755 sar sadc iostat /usr/local/bin/ \
    && cd /python-source && apt-get source "python3.11=$(dpkg-query -W -f='${source:Version}' python3.11-minimal)"
COPY infra/runtime/admin-runner/diagnostics/ /build/
COPY --from=compose /compose /compose-source-build
ARG SOURCE_REVISION
RUN /bin/bash /build/build-python.sh && /bin/bash /build/build.sh "$SOURCE_REVISION"

FROM scratch
ARG SOURCE_REVISION
LABEL org.emisar.image-purpose="admin-diagnostics" \
      org.opencontainers.image.revision="$SOURCE_REVISION" \
      org.opencontainers.image.source="https://github.com/andrewdryga/emisar"
COPY --from=build /bundle /bundle
# Docker create requires a command; production only copies the bundle out.
CMD ["/bundle/bin/iostat", "-V"]
