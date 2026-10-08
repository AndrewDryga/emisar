ARG PACKTEST_IMAGE
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest

FROM ${PACKTEST_IMAGE} AS symbolicator

# The vendor runtime is distroless. A static healthcheck helper preserves that
# runtime and its non-root identity without depending on a vendor shell or
# package manager.
FROM busybox:1.38.0-musl@sha256:ea2b9914a16a4ac1981994af97b318f7c7d4db76b580c56177f08bf76f4a0be8 AS health-tools

# The client runs the CLI actions, so it needs the same binary the host would
# have — and its own caches, configuration, and crash artifacts to act on,
# exactly as those actions do on a real symbolication host.
FROM ${PACKTEST_RUNNER_IMAGE} AS client

USER root
COPY --from=symbolicator /bin/symbolicator /usr/local/bin/symbolicator

COPY config.yml /etc/symbolicator/config.yml
# Crash artifacts land in one of the directories the file actions are contained
# to, so the cases exercise the real containment rather than a path that only
# works in the harness.
COPY fixtures/packtest.dmp fixtures/packtest.crash /var/tmp/

# The shared client supplies the shell, curl, and jq. Symbolicator's C++ unwind
# runtime is a client dependency, not a reason to change the distroless SUT.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && symbolicator --version

# One cached object under a cache the retention keeps, so a cleanup preview has
# something real to retain rather than reporting an empty tree. Owned by the
# non-root identity the harness runs actions as.
RUN mkdir -p /data/objects/packtest /data/symcaches \
    && head -c 4096 /dev/urandom > /data/objects/packtest/debug-file \
    && chmod 0644 /etc/symbolicator/config.yml /var/tmp/packtest.dmp /var/tmp/packtest.crash \
    && chown -R 65532:65532 /data

USER packtest

FROM symbolicator AS sut
COPY --from=health-tools /bin/busybox /bin/busybox
