FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base system + every CLI binary referenced by the packs.
# Built once; cached layer is reused across all pack tests.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release apt-transport-https unzip \
    bash coreutils procps iproute2 net-tools iputils-ping dnsutils \
    file findutils grep gawk sed jq nano vim-tiny \
    git openssl openssh-client \
    psmisc lsof strace gdb sysstat netcat-openbsd ngrep \
    iptables nftables conntrack tcpdump \
    chrony \
    rsync xz-utils zstd \
    python3 python3-pip python3-venv python3-yaml \
    nodejs npm \
    default-jre-headless \
    postgresql-client mariadb-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

# cases.yaml is parsed by harness.sh with jq (base apt) on JSON converted from
# YAML by python3 — no yq needed.

# AWS CLI v2
RUN curl -sSL "https://awscli.amazonaws.com/awscli-exoscale-linux-$(uname -m).zip" -o /tmp/awscli.zip 2>/dev/null \
    || curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
    && cd /tmp && unzip -q awscli.zip && ./aws/install && rm -rf /tmp/awscli.zip /tmp/aws \
    || echo "aws-cli not installed; aws-* pack tests will be skipped"

# kubectl
RUN curl -sSL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl || true

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/* || true

# HashiCorp tools (consul, nomad, vault, terraform)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y --no-install-recommends consul nomad vault terraform && rm -rf /var/lib/apt/lists/* || true

# Docker CLI (for docker pack tests; runs against host docker socket)
RUN curl -fsSL https://get.docker.com | sh || true

# Pack-specific binaries via apt where available
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx-common apache2-utils \
    bind9-utils bind9-dnsutils \
    fail2ban-client \
    haproxy socat \
    wireguard-tools \
    nfs-common rpcbind \
    zfsutils-linux \
    php-cli php-fpm composer \
    rabbitmq-server \
    || apt-get install -y --no-install-recommends \
        nginx-common bind9-utils fail2ban haproxy socat \
        wireguard-tools nfs-common php-cli composer \
    ; rm -rf /var/lib/apt/lists/*

# JVM diagnostic tools come with default-jdk
RUN apt-get update && apt-get install -y --no-install-recommends default-jdk-headless \
    && rm -rf /var/lib/apt/lists/* || true

# net-snmp client (snmpget/snmpwalk/snmptable) for the snmp pack's actions
RUN apt-get update && apt-get install -y --no-install-recommends snmp \
    && rm -rf /var/lib/apt/lists/*

# mongosh for the mongodb pack (single static tarball — no apt repo).
RUN set -eux; case "$(dpkg --print-architecture)" in arm64) m=arm64;; amd64) m=x64;; *) m=x64;; esac; \
    curl -fsSL "https://downloads.mongodb.com/compass/mongosh-2.3.8-linux-$m.tgz" -o /tmp/mongosh.tgz; \
    tar -xzf /tmp/mongosh.tgz -C /tmp; \
    mv /tmp/mongosh-*/bin/mongosh /usr/local/bin/mongosh; \
    rm -rf /tmp/mongosh*; \
    mongosh --version

# cockroach CLI for the cockroach pack (the single binary from the release tarball).
RUN set -eux; v=v24.3.5; arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://binaries.cockroachdb.com/cockroach-$v.linux-$arch.tgz" -o /tmp/crdb.tgz; \
    tar -xzf /tmp/crdb.tgz -C /tmp; \
    mv "/tmp/cockroach-$v.linux-$arch/cockroach" /usr/local/bin/cockroach; \
    rm -rf /tmp/crdb.tgz "/tmp/cockroach-$v.linux-$arch"; \
    cockroach version | head -1

# clickhouse-client for the clickhouse pack — the single multicall `clickhouse`
# binary from the pinned common-static tgz (no apt repo / GPG keyserver), symlinked
# so the pack's bare `clickhouse-client` invocation resolves. 24.8 LTS matches the SUT.
RUN set -eux; v=24.8.14.39; case "$(dpkg --print-architecture)" in arm64) a=arm64;; *) a=amd64;; esac; \
    curl -fsSL "https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-$v-$a.tgz" -o /tmp/ch.tgz; \
    tar -xzf /tmp/ch.tgz -C /tmp; \
    mv "/tmp/clickhouse-common-static-$v/usr/bin/clickhouse" /usr/local/bin/clickhouse; \
    ln -s /usr/local/bin/clickhouse /usr/local/bin/clickhouse-client; \
    rm -rf /tmp/ch.tgz "/tmp/clickhouse-common-static-$v"; \
    clickhouse-client --version

# emisar binary (mounted at runtime via volume)
VOLUME ["/opt/emisar"]
ENV PATH="/opt/emisar/bin:${PATH}"

# Pack catalog + test harness mounted at runtime
WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
