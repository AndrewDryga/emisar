# The Terraform client for this pack's behavior cases. It comes from the same
# pinned image as the SUT so the state-format fixtures are tested by the exact
# Terraform version declared in the behavior matrix.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=1.15.8
ARG PACKTEST_DIGEST
FROM hashicorp/terraform:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=client /bin/terraform /usr/local/bin/terraform

# OpenTofu proves TF_BIN routes the same actions to the alternate CLI. It is not
# the product the version matrix sweeps, so it pins independently of it. Its
# published image refuses to act as a build base (ONBUILD exit 1), so the binary
# is copied straight out of it rather than through a named stage.
COPY --from=ghcr.io/opentofu/opentofu@sha256:ba827d1af675c3f522eb78e2b8098cc87daefb9ceb9d3c4b69d0a1bb6d272463 /usr/local/bin/tofu /usr/local/bin/tofu
