# Two images from one file, because the runner and the service manager it
# drives have to be the same systemd build: the SUT boots it as PID 1, and the
# runner joins that container's PID namespace and /run to talk to it. Sharing
# the base is what keeps systemctl and systemd from drifting a version apart.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST

# The product under test. cron is here because the cases need a real unit to
# start, stop, restart, mask and signal; dbus is what systemctl talks over.
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS sut
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus cron \
    && rm -rf /var/lib/apt/lists/*
# Both images pin the SAME machine-id on purpose. journalctl reads
# /run/log/journal/<machine-id>/, so a client with its own id looks in a
# directory the service manager never wrote and reports "No entries" — the
# runner is standing in for this machine, so it has to identify as it.
RUN printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id

# Volatile journal storage, so everything journald writes lands under the /run
# the client shares. Debian's default is persistent once /var/log/journal
# exists, and /var is NOT shared — which reads from the client as an empty
# journal rather than as an error.
RUN mkdir -p /etc/systemd/journald.conf.d \
    && printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/packtest.conf

# The client. The shared runner image is the same Debian release as the SUT, so
# `systemctl` here is the same package the SUT runs.
FROM ${PACKTEST_RUNNER_IMAGE} AS tools
ENV DEBIAN_FRONTEND=noninteractive
# The shared image ends as the packtest user; installing needs root, and the
# runtime identity has to be restored or every case would run as root.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd \
    && rm -rf /var/lib/apt/lists/*
RUN printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id
COPY fixtures/journalctl-failure/ /opt/packtest-journalctl-failure/
RUN chmod 0755 /opt/packtest-journalctl-failure/*
USER packtest
