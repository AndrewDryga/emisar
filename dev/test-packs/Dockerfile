# One shared action-client image for container-backed pack behavior tests.
# Specialist clients come from the exact image used by the matching SUT. This
# avoids remote install scripts and keeps client versions aligned with servers.

FROM hashicorp/consul:2.0.2@sha256:7dcf35d6b2682831094f1680aa58be214134969505acce0a9b280249581aa7d2 AS consul
FROM hashicorp/nomad:2.0.4@sha256:14f0cf3dc43d949e759b50d793529976a1a1a7f391eaf1e048acd55cd5392462 AS nomad
FROM hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54 AS vault
FROM rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87 AS k3s
FROM mongo:8.2.5@sha256:60aa240412f473f672ec8b282fd5651aa156dcc7a220f81f5381ce768ccc3167 AS mongo
FROM cockroachdb/cockroach:v26.2.4@sha256:85417da0fd2f57e4f1b01ae8a4125402c977a38a56b43d0902db93dc2669ab09 AS cockroach
FROM clickhouse/clickhouse-server:26.6.2.81-alpine@sha256:9acc2bb14b5a55bdaf08485fba63200092f9c04cfa50f70a92f1fccc51482d7f AS clickhouse
FROM minio/minio:latest@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e AS minio

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

COPY --from=consul /bin/consul /usr/local/bin/consul
COPY --from=nomad /bin/nomad /usr/local/bin/nomad
COPY --from=vault /bin/vault /usr/local/bin/vault
COPY --from=k3s /bin/k3s /usr/local/bin/kubectl
COPY --from=mongo /usr/bin/mongosh /usr/local/bin/mongosh
COPY --from=cockroach /cockroach/cockroach /usr/local/bin/cockroach
COPY --from=clickhouse /usr/bin/clickhouse /usr/local/bin/clickhouse
COPY --from=minio /usr/bin/mc /usr/local/bin/mc

RUN ln -s /usr/local/bin/clickhouse /usr/local/bin/clickhouse-client \
    && aws --version \
    && cockroach version | head -1 \
    && consul version \
    && kubectl version --client \
    && mongosh --version \
    && mc --version \
    && nomad version \
    && vault version \
    && clickhouse-client --version

VOLUME ["/opt/emisar"]
ENV HOME="/tmp/packtest" \
    PATH="/opt/emisar/bin:${PATH}"

WORKDIR /workspace
USER packtest
ENTRYPOINT ["/bin/bash"]
