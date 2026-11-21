# Multi-stage build for the emisar control plane.
# Target: minimal runtime image with a release built from source.
#
# Build context is the REPO ROOT (not portal/) so we can also pull in
# the canonical install.sh — InstallController embeds it at compile
# time via @external_resource, resolved via a relative path that
# bottoms out at /install.sh inside the build container.
#
# Invoked by docker-compose as `build: { context: ., dockerfile: portal/Dockerfile }`.

# Toolchain pins track /.tool-versions (the repo-root single source of truth).
# These defaults ARE the release toolchain: BUILDER_IMAGE below is digest-pinned,
# so a --build-arg override would only rewrite the tag in front of the digest,
# which Docker ignores, and no build passes one. `./run gate tooling`
# (checkReleaseToolchainPins) fails when these drift from .tool-versions.
# (ELIXIR_VERSION drops the asdf `-otp-NN` suffix; the hexpm image tag doesn't
# carry it.)
ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=bookworm-20261104-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}@sha256:99d1775b9f8f0fdd16e4e64923d2f62273352b22d68bd1e99bb202a511f419a0"
# The runtime base needs to match the builder's libc/ssl; use the same
# debian snapshot so any compiled NIFs link against compatible libs.
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc"

# --- Build stage ---------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

COPY portal/docker/debian.sources /etc/apt/sources.list.d/debian.sources
COPY portal/docker/debian-snapshot.pref /etc/apt/preferences.d/debian-snapshot.pref
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ARG HEX_VERSION=2.7.0
ARG REBAR3_VERSION=3.28.0
ARG REBAR3_SHA512=33bbd38c624f179a507ea0db611217aa3e9d99b6e65a96cdaebd933224e73af271c4d348171698f69c907dcf4f246757c8ea925a4153048bfdb6c7c5ca0835cf
RUN mix local.hex "${HEX_VERSION}" --force \
  && curl -fsSL "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" -o /tmp/rebar3 \
  && printf '%s  %s\n' "$REBAR3_SHA512" /tmp/rebar3 | sha512sum --check -- \
  && mix local.rebar rebar3 /tmp/rebar3 --force \
  && rm -f /tmp/rebar3

ENV MIX_ENV="prod"

# Install dependencies while the cache key contains only files that can change
# dependency resolution or compilation. Every mix.exs requires VERSION to exist,
# but its value is release metadata and does not affect deps, so use a stable
# placeholder until application compilation.
RUN printf '0.0.0-dev\n' > VERSION
COPY portal/mix.exs portal/mix.lock ./
COPY portal/apps/emisar/mix.exs apps/emisar/mix.exs
COPY portal/apps/emisar_web/mix.exs apps/emisar_web/mix.exs
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# The real product version is embedded in the applications and OTP release.
COPY portal/VERSION ./

# Optional dev-only build flag: the docker-compose dev/e2e stack passes
# EMISAR_DEV_HOST_EXCLUDES=1 so config/prod.exs lets its plain-HTTP internal
# hosts (localhost / 127.0.0.1 / the `portal` service) through force_ssl. A
# production build leaves it empty, so prod enforces HTTPS for every request host.
# force_ssl is a compile_env, so this must be set before `mix compile` below.
ARG EMISAR_DEV_HOST_EXCLUDES=""
ENV EMISAR_DEV_HOST_EXCLUDES=${EMISAR_DEV_HOST_EXCLUDES}

# Optional dev-only build flag: the docker-compose dev stack passes
# EMISAR_DEV_ROUTES=1 so config/prod.exs compiles in the /dev routes — the
# /dev/mailbox magic-link preview (passwordless sign-in needs it locally) and
# /dev/dashboard. dev_routes is a compile_env read by the router, so it must be
# set before `mix compile`. A production build leaves it empty, so prod never
# mounts /dev/*. The matching in-memory mailer is switched on at runtime.
ARG EMISAR_DEV_ROUTES=""
ENV EMISAR_DEV_ROUTES=${EMISAR_DEV_ROUTES}

# Place the runner and MCP installers where their controllers can embed them.
# These must stay ABOVE `mix assets.deploy`, however much they look like a
# compile-only input. The install controllers read them in their MODULE BODY
# (install_controller.ex:22), and every mix task compiles the project first — so
# assets.deploy fails with `could not read file "/install.sh"` if they are not
# here yet. Moving them down to sit beside `mix compile` breaks the image build,
# and the portal gate does not catch it because the gate never builds the image.
COPY install.sh /install.sh
COPY install-mcp.sh /install-mcp.sh
COPY install-mcp.ps1 /install-mcp.ps1

# Application configuration is a compile input, not a dependency input.
RUN mkdir -p config
COPY portal/config/config.exs portal/config/${MIX_ENV}.exs config/

# `apps` includes each app's own priv/ (migrations, MCP schemas, assets, etc).
# The umbrella root has no priv/ of its own, so a stray
# `COPY priv priv` here would break the build.
COPY portal/apps apps

# The Tailwind CLI executes inside this builder, so it is fetched here and
# checked against the release's published SHA-256 (sha256sums.txt, matching
# GitHub's asset digests) for the architecture being built, instead of letting
# `mix tailwind` download it unverified. config/prod.exs points the tailwind
# library at this path. Bump TAILWIND_VERSION with config.exs `:tailwind`
# `version`, and both digests from that release's sha256sums.txt.
ARG TARGETARCH
ARG TAILWIND_VERSION=4.3.5
ARG TAILWIND_SHA256_AMD64=e47695cee3f0d90623a91f3939b08bdee610eb5ad99340adff9d4145b284d6cc
ARG TAILWIND_SHA256_ARM64=ffcd0d21dbd7c605dc12743ff0c0b47debc963c86b399674084c1c8f2c96ecad
RUN case "${TARGETARCH}" in \
      amd64) tailwind_target=x64; tailwind_sha256="${TAILWIND_SHA256_AMD64}" ;; \
      arm64) tailwind_target=arm64; tailwind_sha256="${TAILWIND_SHA256_ARM64}" ;; \
      *) echo "no pinned Tailwind digest for TARGETARCH='${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-linux-${tailwind_target}" -o /usr/local/bin/tailwindcss \
  && printf '%s  %s\n' "$tailwind_sha256" /usr/local/bin/tailwindcss | sha256sum --check -- \
  && chmod 0755 /usr/local/bin/tailwindcss
ENV TAILWIND_PATH=/usr/local/bin/tailwindcss

# Build assets (esbuild + tailwind)
RUN mix assets.deploy

# Compile + release
RUN mix compile
# Sentry reads source context from a PACKAGED sentry.map, not from
# root_source_code_paths at runtime — so without this task every production
# stack frame ships with no surrounding source, while config.exs claims
# enable_source_code_context: true. It has to run after compile (the task
# compiles the project anyway) and before `mix release`, so the map is inside
# the release. Source-context config lives in config.exs rather than
# runtime.exs, so `mix app.config` is not needed first.
RUN mix sentry.package_source_code
# Runtime configuration is evaluated by the assembled release, so changing it
# should invalidate release assembly without rebuilding assets or application
# bytecode.
COPY portal/config/runtime.exs config/
COPY portal/rel rel
RUN mix release

# --- Runtime stage -------------------------------------------------
FROM ${RUNNER_IMAGE}

# The apt snapshot makes package bytes reproducible. The base digest is only as
# fresh as its last hexpm build, so the runtime stage upgrades to the snapshot's
# security fixes; bump the snapshot when the required CI vulnerability scan
# reports a fixed Debian package.
COPY portal/docker/debian.sources /etc/apt/sources.list.d/debian.sources
COPY portal/docker/debian-snapshot.pref /etc/apt/preferences.d/debian-snapshot.pref
# The builder's OTP has SCTP enabled and loads libsctp.so.1 at VM startup; keep
# its runtime library here so migrations and the server boot without warnings.
RUN apt-get update -y \
  && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends libstdc++6 libsctp1 openssl libtinfo6 locales ca-certificates netcat-openbsd \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
COPY portal/docker/prune-runtime-packages.sh /tmp/prune-runtime-packages.sh
RUN /bin/sh /tmp/prune-runtime-packages.sh && rm /tmp/prune-runtime-packages.sh
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody:nogroup /app
USER nobody

ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:nogroup /app/_build/${MIX_ENV}/rel/emisar ./

# Per-build metadata belongs after every reusable build and runtime layer. A
# new commit changes only this tiny layer when the application bytes are stable.
ARG SOURCE_REVISION=dev
RUN test -n "$SOURCE_REVISION" \
  && printf '%s\n' "$SOURCE_REVISION" > /app/REVISION

EXPOSE 4000
CMD ["/app/bin/server"]
