# The action client is the pinned buildpack-deps scm image itself, which ships
# its Debian release's git package, so the git every action runs, and every
# arrange step seeds its checkout with, is exactly the build the version row
# names. Nothing is installed on top of it.
ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# Cases run as 65532:65532, the harness's default runner identity, named
# packtest as in the shared client.
RUN groupadd --gid 65532 packtest \
    && useradd --uid 65532 --gid 65532 --no-create-home --no-log-init --home-dir /tmp/packtest packtest
