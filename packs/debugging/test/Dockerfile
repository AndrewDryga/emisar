# Add the two binaries declared by the debugging pack to the shared action
# client. The case starts its own target processes inside this container.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
COPY fixtures/dmesg-fallback/ /opt/packtest-dmesg-fallback/
COPY fixtures/dmesg-failure/ /opt/packtest-dmesg-failure/
RUN chmod 0755 /opt/packtest-dmesg-fallback/* /opt/packtest-dmesg-failure/*
USER packtest
