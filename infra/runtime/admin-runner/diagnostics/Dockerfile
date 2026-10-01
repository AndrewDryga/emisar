# A byte bundle, never a privileged diagnostics container. Native execution on
# COS preserves the inspected host's process, mount, network and device views.
FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS build
COPY debian.sources /etc/apt/sources.list.d/debian.sources
RUN apt-get update -y && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates curl dmidecode ethtool iproute2 iputils-ping jq \
       lvm2 mdadm python3-ntp chrony procps smartmontools sysstat util-linux \
    && mkdir /tmp/ntpcli && cd /tmp/ntpcli \
    && apt-get download ntpsec \
    && dpkg-deb --extract ntpsec_*.deb extracted \
    && install -m 0755 extracted/usr/bin/ntpq /usr/local/bin/ntpq \
    && rm -rf /tmp/ntpcli /var/lib/apt/lists/*
COPY build.sh run-tool commands.txt /build/
RUN /bin/bash /build/build.sh
# This minimal image has no sysstat installation. The sar sample must find our
# relocated sadc through PATH rather than accidentally using the build host's.
FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS smoke
COPY --from=build /bundle /bundle
RUN test ! -e /usr/lib/sysstat/sadc \
    && /bundle/bin/sar -u 1 1 \
    && /bundle/bin/ntpq --version \
    && /bundle/bin/chronyc -v \
    && /bundle/cli-plugins/docker-compose version
FROM scratch
COPY --from=smoke /bundle /bundle
# docker create requires a command, but production never starts this image.
CMD ["/bundle/bin/iostat", "-V"]
