# No official/Canonical net-snmp image exists, so build a minimal snmpd SUT from
# the Debian base (same base as runner-tools + the Debian fleet). Read-only,
# v2c canary community; the config is mounted from ../fixtures/snmpd.conf.
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST}
RUN apt-get update \
    && apt-get install -y --no-install-recommends snmp snmpd \
    && rm -rf /var/lib/apt/lists/*
EXPOSE 161/udp
