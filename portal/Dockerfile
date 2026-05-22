# Multi-stage build for the emisar control plane.
# Target: minimal runtime image with a release built from source.

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1
ARG DEBIAN_VERSION=bookworm-20241016-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
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

# Install deps first so docker layer-caches them.
COPY mix.exs mix.lock ./
COPY apps/emisar/mix.exs apps/emisar/mix.exs
COPY apps/emisar_web/mix.exs apps/emisar_web/mix.exs
RUN mkdir -p config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# `apps` includes each app's own priv/ (migrations, assets, etc).
# The umbrella root has no priv/ of its own, so a stray
# `COPY priv priv` here would break the build.
COPY apps apps
COPY config/runtime.exs config/

# Build assets (esbuild + tailwind)
RUN mix assets.deploy

# Compile + release
RUN mix compile
COPY rel rel
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
