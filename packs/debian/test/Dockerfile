# apt writes the package database of the machine the action runs on, and here
# that machine is the runner container itself — disposable, recreated per case.
# So there is no separate SUT: the version matrix pins the Debian release whose
# apt and dpkg are under test, and the client image is built from it.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=13-slim
ARG PACKTEST_DIGEST

# Present only so the matrix's pinned release is what supplies apt: the shared
# runner image is built from this same Debian, and this stage fails the build if
# that ever stops being true.
FROM debian:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS release
RUN apt-get --version > /release-apt-version

FROM ${PACKTEST_RUNNER_IMAGE} AS tools
COPY --from=release /release-apt-version /release-apt-version
USER root
# The package lists the shared image deletes, restored: apt-get install cannot
# resolve anything without them, and a case that had to fetch them first would
# be testing the network.
RUN apt-get update \
    && test "$(apt-get --version | head -1)" = "$(head -1 /release-apt-version)"
# sl is the case's subject: a leaf package with no reverse dependencies, so
# installing and removing it cannot disturb anything the harness needs.
USER packtest
