ARG PACKTEST_VERSION=2.0.7
ARG PACKTEST_DIGEST
FROM hashicorp/nomad:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS nomad

# The Node runtime is an independent fixture dependency, not the Nomad version.
FROM node:22.15.0-bookworm-slim@sha256:557e52a0fcb928ee113df7e1fb5d4f60c1341dbda53f55e3d815ca10807efdce
COPY --from=nomad /bin/nomad /usr/local/bin/nomad
USER node
