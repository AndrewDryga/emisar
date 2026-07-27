# The clickhouse client for this pack's cases. It comes out of the very image the
# pack already runs as its SUT, so extracting it costs no extra pull, and the
# client version tracks the server version under test.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=26.6.2.81-alpine
ARG PACKTEST_DIGEST
FROM clickhouse/clickhouse-server:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
# Copied twice rather than symlinked: the shared image ends as a non-root user,
# and COPY is unaffected by USER where RUN ln is not.
COPY --from=client /usr/bin/clickhouse /usr/local/bin/clickhouse
COPY --from=client /usr/bin/clickhouse /usr/local/bin/clickhouse-client
