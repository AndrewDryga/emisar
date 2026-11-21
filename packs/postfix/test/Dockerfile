ARG PACKTEST_VERSION=5.1.0-alpine
ARG PACKTEST_DIGEST

FROM debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS qshape

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postfix \
    && rm -rf /var/lib/apt/lists/*

FROM boky/postfix:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apk add --no-cache perl \
    # maillog_grep's cases write their log lines here as the non-root runner.
    && install -m 0666 /dev/null /var/log/mail.log

COPY --from=qshape /usr/sbin/qshape /usr/local/bin/qshape
