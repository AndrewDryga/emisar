# Add the one binary the git-local pack declares to the shared action client.
# Every case seeds its own checkout in this container, which is the runner host
# the actions read.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
USER packtest
