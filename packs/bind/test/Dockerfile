ARG PACKTEST_VERSION=edge
ARG PACKTEST_DIGEST
FROM ubuntu/bind9:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apt-get update \
    && apt-get install -y --no-install-recommends bind9-dnsutils bind9-utils \
    && rm -rf /var/lib/apt/lists/*
