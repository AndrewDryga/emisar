ARG PACKTEST_VERSION=edge
FROM ubuntu/bind9:${PACKTEST_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends bind9-dnsutils bind9-utils \
    && rm -rf /var/lib/apt/lists/*
