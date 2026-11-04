ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# The release is built once and shared by both containers: the same paths exist
# in the SUT and in runner-tools, which sees the SUT's processes through a shared
# PID namespace, so discovery and bin/fixture_app rpc run as they do on a host.
ENV LANG=C.UTF-8 MIX_ENV=prod
COPY fixtures/fixture_app /build
WORKDIR /build
RUN mix release --path /opt/fixture_app \
    && chown -R 65532:65532 /opt/fixture_app \
    && rm -rf /build
WORKDIR /
USER 65532:65532
ENTRYPOINT ["/opt/fixture_app/bin/fixture_app"]
CMD ["start"]
