# Two images from one file, because the runner and the service manager it
# drives have to be the same systemd build: the SUT boots it as PID 1, and the
# runner joins that container's PID namespace and /run to talk to it. Sharing
# the base is what keeps systemctl and systemd from drifting a version apart.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST

# The product under test. cron is here because the cases need a real unit to
# start, stop, restart, enable and disable, and because the crontab reads want
# real crontabs to find; dbus is what systemctl talks over.
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS sut
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus cron \
    && rm -rf /var/lib/apt/lists/*
# cron_recent reads what cron LOGGED, so a job has to actually fire. @reboot
# runs when the daemon starts, which a restart in the case triggers on demand —
# a minute-schedule job would make the case wait for a clock boundary.
RUN printf '@reboot root /bin/true\n' > /etc/cron.d/packtest \
    && chmod 0644 /etc/cron.d/packtest

# Both images pin the SAME machine-id on purpose. journalctl reads
# /run/log/journal/<machine-id>/, so a client carrying its own id looks in a
# directory the service manager never wrote and reports "No entries" — the
# runner stands in for this machine, so it has to identify as it.
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
    && apt-get install -y --no-install-recommends systemd cron \
    && rm -rf /var/lib/apt/lists/*
RUN printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id
# crontab_all enumerates the passwd file of the machine the ACTION runs on,
# which is this container rather than the service-manager SUT, so the crontab
# it should find lives here — without it the case would pass against an empty
# machine and prove nothing.
RUN useradd --create-home --shell /bin/sh deploy \
    && printf '17 3 * * * /usr/local/bin/packtest-nightly\n' | crontab -u deploy -
# Arrange and probe steps run as the image's own user, not as the case's
# runner_user, so the journal reads they do to set up and verify need this
# group — the action itself already runs as root.
RUN usermod -aG systemd-journal packtest
USER packtest
