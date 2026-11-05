# Extraction-only artifact. The privileged host never starts this container.
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS compose
COPY infra/runtime/admin-runner/diagnostics/build-compose.sh /build-compose.sh
RUN --mount=type=cache,id=emisar-diagnostics-compose-go1.27.3-modules,target=/go/pkg/mod,sharing=locked \
    /bin/sh /build-compose.sh

FROM debian:bookworm-20261027-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS build
COPY portal/docker/debian.sources /etc/apt/sources.list.d/debian.sources
COPY portal/docker/debian-snapshot.pref /etc/apt/preferences.d/debian-snapshot.pref
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
    && cd /sysstat-source && apt-get source "sysstat=$(dpkg-query -W -f='${source:Version}' sysstat)" \
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
