# No official/Canonical net-snmp image exists, so build a minimal snmpd SUT from
# the Debian base (same base as runner-tools + the Debian fleet). Read-only,
# v2c community "public"; the config is mounted from ../fixtures/snmpd.conf.
FROM debian:13-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends snmpd \
    && rm -rf /var/lib/apt/lists/*
EXPOSE 161/udp
