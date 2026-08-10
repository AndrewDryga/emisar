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
# systemd refuses to boot without a machine-id, and a read-only one would make
# every case share a journal namespace.
RUN systemd-machine-id-setup

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
USER packtest
