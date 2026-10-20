ARG PACKTEST_VERSION=5.1.0-alpine
ARG PACKTEST_DIGEST

FROM debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apk add --no-cache perl

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
