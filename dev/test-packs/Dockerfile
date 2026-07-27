# The shared action-client image: the Debian-owned clients that many packs use.
#
# A specialist client — clickhouse, cockroach, consul, kubectl, mc, mongosh,
# nomad, vault — lives in its own pack instead, extracted from the image that
# pack already runs as its SUT. Carrying all eight here cost 2.2GB that a redis
# row restored and never ran, and buys nothing: the source image is already
# local wherever the client is actually wanted.

FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

ENV DEBIAN_FRONTEND=noninteractive

# Debian-owned clients cover the generic HTTP, SQL, AWS, SNMP, and protocol
# plans. apt failures fail the build; no behavior plan is silently skipped.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        awscli \
        bash \
        ca-certificates \
        curl \
        jq \
        mariadb-client \
        netcat-openbsd \
        postgresql-client \
        redis-tools \
        snmp \
    && groupadd --gid 65532 packtest \
    && useradd --uid 65532 --gid 65532 --home-dir /tmp/packtest --create-home packtest \
    && printf '[client]\nuser=root\nssl-verify-server-cert=0\n' \
        > /etc/mysql/mariadb.conf.d/99-packtest.cnf \
    && rm -rf /var/lib/apt/lists/*

RUN aws --version

VOLUME ["/opt/emisar"]
ENV HOME="/tmp/packtest" \
    PATH="/opt/emisar/bin:${PATH}"

WORKDIR /workspace
USER packtest
ENTRYPOINT ["/bin/bash"]
