ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST

# A real systemd-owned Fail2ban daemon. The emisar user shares the harness
# runner's numeric uid, so the ACL applied inside this host fixture grants the
# unprivileged action process in runner-tools exactly the production access.
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS sut
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends acl dbus fail2ban systemd systemd-sysv \
    && useradd --uid 65532 --user-group --no-create-home --shell /usr/sbin/nologin emisar \
    && install -d -m 0755 /etc/systemd/system/fail2ban.service.d \
    && printf '%s\n' '[Service]' \
        "ExecStartPost=-/usr/bin/timeout 10 /bin/sh -c 'until [ -S /run/fail2ban/fail2ban.sock ]; do sleep 0.1; done; exec /usr/bin/setfacl -m u:emisar:rw /run/fail2ban/fail2ban.sock'" \
        > /etc/systemd/system/fail2ban.service.d/emisar-access.conf \
    && systemctl enable fail2ban.service \
    && rm -rf /var/lib/apt/lists/*

FROM ${PACKTEST_RUNNER_IMAGE} AS tools
ENV DEBIAN_FRONTEND=noninteractive
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends fail2ban systemd util-linux \
    && rm -rf /var/lib/apt/lists/*
USER packtest
