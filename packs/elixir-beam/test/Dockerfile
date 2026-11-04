ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# The release is built once and shared by both containers: the same paths exist
# in the SUT and in runner-tools, which sees the SUT's processes through a shared
# PID namespace, so discovery and bin/fixture_app rpc run as they do on a host.
#
# recon is compiled into the application from its pinned source. The pack needs
# its modules in the release and nothing else, so this avoids Hex and rebar3. The
# cookie is a declared canary, so a case fails if any action prints it.
ENV LANG=C.UTF-8 MIX_ENV=prod
ARG RECON_VERSION=2.5.6
ARG RECON_SHA256=bad7d7f0f9504220ef1490b30ab97d1d4f5713124a9caac04866f3d506359e2f
COPY fixtures/fixture_app /build
WORKDIR /build
RUN curl -fsSL -o /tmp/recon.tar.gz "https://github.com/ferd/recon/archive/refs/tags/${RECON_VERSION}.tar.gz" \
    && printf '%s  /tmp/recon.tar.gz\n' "$RECON_SHA256" | sha256sum -c - \
    && mkdir -p vendor/recon \
    && tar -xzf /tmp/recon.tar.gz --strip-components=1 -C vendor/recon "recon-${RECON_VERSION}/src" \
    && rm -f vendor/recon/src/recon.app.src /tmp/recon.tar.gz \
    && mix release --path /opt/fixture_app \
    && printf 'packtest-canary-beam-cookie-5d90ab' > /opt/fixture_app/releases/COOKIE \
    && chown -R 65532:65532 /opt/fixture_app \
    && rm -rf /build
WORKDIR /
USER 65532:65532
ENTRYPOINT ["/opt/fixture_app/bin/fixture_app"]
CMD ["start"]
