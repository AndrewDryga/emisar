ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# The vendor image has Vector, but no HTTP client for the action or readiness.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl mawk gawk \
    && rm -rf /var/lib/apt/lists/*

COPY fixtures/posix-awk /fixture/posix-awk
RUN install -D -m 0755 /fixture/posix-awk /opt/posix-awk/awk

ENTRYPOINT ["/usr/bin/vector"]
