ARG PACKTEST_VERSION=2.4.68
ARG PACKTEST_DIGEST
FROM httpd:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
