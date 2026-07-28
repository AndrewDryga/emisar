ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
ARG PACKTEST_VERSION=577.0.0-slim
ARG PACKTEST_DIGEST
FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS gcloud

FROM ${PACKTEST_RUNNER_IMAGE}
COPY --from=gcloud /usr/lib/google-cloud-sdk /usr/lib/google-cloud-sdk
USER root
RUN ln -s /usr/lib/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud
USER packtest
