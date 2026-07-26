ARG PACKTEST_VERSION=1.31.3
ARG PACKTEST_DIGEST
FROM nginx:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl procps \
    && rm -rf /var/lib/apt/lists/* \
    # `nginx -t`/`-T` opens the configured pid file and creates its cache temp
    # directories, both of which the image ships root-owned — invisible while
    # the harness ran containers as root, fatal once it stopped.
    && chmod 0777 /var/run /var/cache/nginx
