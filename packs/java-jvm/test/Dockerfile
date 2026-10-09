ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE} AS client

# jvmstat resolves the process uid through passwd before locating hsperfdata.
# Both containers must agree on the names, not merely the numeric uid/gid.
RUN groupadd --gid 65532 packtest \
    && useradd --uid 65532 --gid 65532 --no-create-home --no-log-init --home-dir /tmp/packtest packtest \
    && groupadd --gid 65533 packtest-foreign \
    && useradd --uid 65533 --gid 65533 --no-create-home --no-log-init --home-dir /tmp/packtest-foreign packtest-foreign \
    && mkdir -p /tmp/packtest \
    && chown 65532:65532 /tmp/packtest

FROM client AS sut

COPY fixtures/PerfFixture.java /fixture/PerfFixture.java
RUN javac /fixture/PerfFixture.java
COPY fixtures/start.sh /fixture/start.sh
USER 65532:65532
ENTRYPOINT ["/bin/sh", "/fixture/start.sh"]
