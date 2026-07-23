ARG PACKTEST_VERSION=5.1.0-alpine
ARG PACKTEST_DIGEST

FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apk add --no-cache perl

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
