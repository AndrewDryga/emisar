FROM debian:13-slim AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:5.1.0-alpine

RUN apk add --no-cache perl

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
