# Two images from one file, because vtysh and the daemons it drives have to be
# the same FRR build: vtysh speaks a versioned protocol over the VTY sockets,
# and a client one release apart refuses to connect. The SUT runs the daemons;
# the runner joins its /run/frr and talks to them.
#
# Debian's frr package, not frrouting/frr: the official image is amd64-only,
# which the snmp pack's routing SUT already established (packs/snmp/test/snmpd-frr).
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST

# The product under test: zebra + bgpd + bfdd, with a BGP neighbor configured
# so every read returns real rows and the drain has something to shut.
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS sut
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends frr iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY daemons /etc/frr/daemons
COPY frr.conf /etc/frr/frr.conf
COPY entrypoint.sh /entrypoint.sh
RUN chown frr:frr /etc/frr/daemons /etc/frr/frr.conf \
    && chmod 640 /etc/frr/daemons /etc/frr/frr.conf \
    && chmod 755 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

# The client. vtysh comes from the same Debian release as the SUT's daemons.
FROM ${PACKTEST_RUNNER_IMAGE} AS tools
ENV DEBIAN_FRONTEND=noninteractive
# The shared image ends as the packtest user; installing needs root, and the
# runtime identity has to be restored or every case would run as root.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends frr \
    && rm -rf /var/lib/apt/lists/*
USER packtest
