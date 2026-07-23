ARG PACKTEST_VERSION=1.31.3
FROM nginx:${PACKTEST_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl procps \
    && rm -rf /var/lib/apt/lists/*
