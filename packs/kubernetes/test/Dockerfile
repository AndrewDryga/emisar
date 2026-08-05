# The kubectl client for this pack's cases. It comes out of the very image the
# pack already runs as its SUT, so extracting it costs no extra pull, and the
# client version tracks the server version under test.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=client /bin/k3s /usr/local/bin/kubectl
