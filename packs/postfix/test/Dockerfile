ARG PACKTEST_VERSION=5.1.0-alpine
ARG PACKTEST_DIGEST

FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apk add --no-cache perl

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
