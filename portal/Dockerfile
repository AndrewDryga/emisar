# Multi-stage build for the emisar control plane.
# Target: minimal runtime image with a release built from source.
#
# Build context is the REPO ROOT (not portal/) so we can also pull in
# the canonical install.sh — InstallController embeds it at compile
# time via @external_resource, resolved via a relative path that
# bottoms out at /install.sh inside the build container.
#
# Invoked by docker-compose as `build: { context: ., dockerfile: portal/Dockerfile }`.

# Toolchain defaults track /.tool-versions (the repo-root single source of
# truth). portal-ci overrides ELIXIR_VERSION/OTP_VERSION via --build-arg derived
# from that file; docker-compose and local builds use these defaults — keep them
# in sync when .tool-versions bumps. (ELIXIR_VERSION drops the asdf `-otp-NN`
# suffix; the hexpm image tag doesn't carry it.)
ARG ELIXIR_VERSION=1.20.1
ARG OTP_VERSION=29.0.2
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
# The runtime base needs to match the builder's libc/ssl; use the same
# debian snapshot so any compiled NIFs link against compatible libs.
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- Build stage ---------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git curl ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Place install.sh / install-mcp.sh where InstallController +
# InstallMcpController's compile-time `Path.expand` resolves to (six
# levels up from each controller's source dir => container root).
# Copying early lets Docker layer-cache them.
COPY install.sh /install.sh
COPY install-mcp.sh /install-mcp.sh

# EmisarWeb.PacksRegistry walks packs/ at compile time; its default
# relative path bottoms out at /packs inside the container. Copy the
# YAMLs there so the registry can scan them. Layer-cached separately so
# pack edits don't bust deps.compile.
COPY packs /packs

# Install deps first so docker layer-caches them.
COPY portal/mix.exs portal/mix.lock ./
COPY portal/apps/emisar/mix.exs apps/emisar/mix.exs
COPY portal/apps/emisar_web/mix.exs apps/emisar_web/mix.exs
RUN mkdir -p config
COPY portal/config/config.exs portal/config/${MIX_ENV}.exs config/
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# `apps` includes each app's own priv/ (migrations, assets, etc).
# The umbrella root has no priv/ of its own, so a stray
# `COPY priv priv` here would break the build.
COPY portal/apps apps
COPY portal/config/runtime.exs config/

# Build assets (esbuild + tailwind)
RUN mix assets.deploy

# Compile + release
RUN mix compile
COPY portal/rel rel
RUN mix release

# --- Runtime stage -------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody:nogroup /app
USER nobody

ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:nogroup /app/_build/${MIX_ENV}/rel/emisar ./

EXPOSE 4000
CMD ["/app/bin/server"]
