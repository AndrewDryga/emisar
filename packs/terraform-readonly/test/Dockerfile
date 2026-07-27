# The Terraform client for this pack's behavior cases. It comes from the same
# pinned image as the SUT so the state-format fixtures are tested by the exact
# Terraform version declared in the behavior matrix.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=1.15.8
ARG PACKTEST_DIGEST
FROM hashicorp/terraform:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=client /bin/terraform /usr/local/bin/terraform
