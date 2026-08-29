# The raw-socket clients this pack declares. The shared runner-tools image
# carries only nc, so mtr and ping — the two actions that need CAP_NET_RAW —
# would have no case at all without them.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest

FROM ${PACKTEST_RUNNER_IMAGE}
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iputils-ping mtr-tiny \
    && rm -rf /var/lib/apt/lists/*
USER packtest
