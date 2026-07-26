# The harness builds the shared action-client image under a unique
# per-invocation tag, so inherit that exact tag. A hardcoded :latest resolves
# only on a machine that happens to hold a stale local build, and otherwise
# sends Docker to the registry for an image that was never published.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

# The shared image ends as the non-root packtest user; installing needs root,
# and the runtime identity is restored so this image matches the base.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*
USER packtest
