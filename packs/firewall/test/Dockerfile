# The nftables client for this pack's behavior cases. The ruleset is created
# and read inside the SUT's network namespace, so what the case needs is the
# shared client image plus nft — starting FROM that image is also what keeps
# the jq built --with-oniguruma=no at /opt/jq-without-regex available to the
# compatibility case.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends nftables \
    && rm -rf /var/lib/apt/lists/*

# Back to the default identity: a case that needs root asks for it, and the
# harness selects it with a Compose user override.
USER packtest
