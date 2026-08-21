# Add the one binary the fs-search pack declares that the shared action client
# does not already carry. Everything else these actions call — du, find, stat,
# sha256sum, wc, head, tail, grep, sort, awk — is Debian-essential.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends file \
    && rm -rf /var/lib/apt/lists/*
USER packtest
