ARG PACKTEST_VERSION=2.4.68
FROM httpd:${PACKTEST_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
