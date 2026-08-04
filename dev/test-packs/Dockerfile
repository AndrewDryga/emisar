# The shared action-client image: the Debian-owned clients that many packs use.
#
# A specialist client — clickhouse, cockroach, consul, kubectl, mc, mongosh,
# nomad, vault — lives in its own pack instead, extracted from the image that
# pack already runs as its SUT. Carrying all eight here cost 2.2GB that a redis
# row restored and never ran, and buys nothing: the source image is already
# local wherever the client is actually wanted.

# Debian's jq links Oniguruma, so nothing here would notice a pack filter that
# depends on jq's optional regex builtins — while a host whose jq was configured
# --with-oniguruma=no raises "jq was compiled without ONIGURUMA regex library"
# the first time such a call runs, mid-answer. This stage builds that jq from
# the pinned release so a pack case can put it ahead of the packaged one on PATH
# and prove its filters run on core jq. The toolchain stays in this stage; the
# final image gains one ~1.4MB binary.
#
# --disable-shared is what makes the result portable: a libtool build leaves
# `jq` linked against the libjq it just built, and that binary copied into the
# final image silently resolves Debian's libjq — Oniguruma and all.
FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd AS jq-without-regex

ARG JQ_VERSION=1.8.2
ARG JQ_SHA256=71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gcc libc6-dev make \
    && curl -fsSL -o /tmp/jq.tar.gz \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${JQ_VERSION}.tar.gz" \
    && printf '%s  /tmp/jq.tar.gz\n' "$JQ_SHA256" | sha256sum -c - \
    && tar -xzf /tmp/jq.tar.gz -C /tmp \
    && cd "/tmp/jq-${JQ_VERSION}" \
    && ./configure --with-oniguruma=no --disable-shared --disable-docs --disable-maintainer-mode \
    && make -j"$(nproc)" \
    && install -D -m 0755 jq /out/jq

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

# Not on PATH by default: a case opts in by putting this directory first, so
# every other case keeps exercising the packaged jq an operator actually has.
COPY --from=jq-without-regex /out/jq /opt/jq-without-regex/jq

# The claim this binary makes is the whole point, and it is checked here rather
# than in the build stage because the final image is where a dynamically linked
# copy would pick Debian's Oniguruma-enabled libjq back up.
RUN /opt/jq-without-regex/jq --version \
    && /opt/jq-without-regex/jq -nc '[1, 2] | map(. * 2)' \
    && ! /opt/jq-without-regex/jq -n '"a" | test("a")' 2>/dev/null

VOLUME ["/opt/emisar"]
ENV HOME="/tmp/packtest" \
    PATH="/opt/emisar/bin:${PATH}"

WORKDIR /workspace
USER packtest
ENTRYPOINT ["/bin/bash"]
