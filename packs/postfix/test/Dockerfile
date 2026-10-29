ARG PACKTEST_VERSION=5.1.0-alpine
ARG PACKTEST_DIGEST

FROM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apk add --no-cache perl

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
