ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=2.36.8
ARG PACKTEST_DIGEST
FROM amazon/aws-cli:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS aws

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=aws /usr/local/aws-cli /usr/local/aws-cli
USER root
RUN ln -sf /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws
USER packtest
