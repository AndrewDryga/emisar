# The Docker CLI for this pack's behavior cases. It comes from the same pinned
# image as the SUT, so the Compose file is parsed by the exact CLI the behavior
# matrix declares. Only the client and its compose plugin are copied: `docker
# compose config` parses a file and talks to no daemon.
#
# Starting FROM the shared client image keeps everything a case needs beside
# the CLI — including the jq built --with-oniguruma=no at /opt/jq-without-regex
# that the compatibility case puts first on PATH.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=29.7.1-cli
ARG PACKTEST_DIGEST
FROM docker:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=client /usr/local/bin/docker /usr/local/bin/docker
COPY --from=client /usr/local/libexec/docker/cli-plugins/docker-compose \
    /usr/local/libexec/docker/cli-plugins/docker-compose
