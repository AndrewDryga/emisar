# The mongosh client for this pack's cases. It comes out of the very image the
# pack already runs as its SUT, so extracting it costs no extra pull, and the
# client version tracks the server version under test.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=8.2.5
ARG PACKTEST_DIGEST
FROM mongo:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=client /usr/bin/mongosh /usr/local/bin/mongosh
