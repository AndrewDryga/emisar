ARG PACKTEST_IMAGE

# The client runs the CLI actions, so it needs the same binary the host would
# have — and its own caches, configuration, and crash artifacts to act on,
# exactly as those actions do on a real symbolication host.
FROM ${PACKTEST_IMAGE} AS client

COPY config.yml /etc/symbolicator/config.yml
# Crash artifacts land in one of the directories the file actions are contained
# to, so the cases exercise the real containment rather than a path that only
# works in the harness.
COPY fixtures/packtest.dmp fixtures/packtest.crash /var/tmp/

# jq builds the symbolicate request body; the runtime image does not ship it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# One cached object under a cache the retention keeps, so a cleanup preview has
# something real to retain rather than reporting an empty tree. Owned by the
# non-root identity the harness runs actions as.
RUN mkdir -p /data/objects/packtest /data/symcaches \
    && head -c 4096 /dev/urandom > /data/objects/packtest/debug-file \
    && chmod 0644 /etc/symbolicator/config.yml /var/tmp/packtest.dmp /var/tmp/packtest.crash \
    && chown -R 65532:65532 /data

FROM ${PACKTEST_IMAGE} AS sut
