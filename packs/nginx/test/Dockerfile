ARG PACKTEST_VERSION=1.31.3
ARG PACKTEST_DIGEST
FROM nginx:${PACKTEST_VERSION}${PACKTEST_DIGEST}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl procps \
    && rm -rf /var/lib/apt/lists/*
