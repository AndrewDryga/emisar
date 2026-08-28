# ssl-local reads certificates and keys already on the host with openssl. The
# fixture below mints a throwaway CA, a leaf, and a PKCS#12 bundle so the
# redaction rules have real PEM key material to mask — declaring a rule only
# proves it compiles.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*
USER packtest
