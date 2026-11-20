ARG PACKTEST_VERSION=2.0.7
ARG PACKTEST_DIGEST
FROM hashicorp/nomad:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS nomad

# The Node runtime is an independent fixture dependency, not the Nomad version.
FROM node:26.13.1-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1
COPY --from=nomad /bin/nomad /usr/local/bin/nomad
USER node
