# Docker inputs enter at their narrowest layer

## Rule

Introduce each `COPY`, build argument, and environment variable immediately
before its first real consumer. Dependency layers contain only toolchain,
dependency manifests, lockfiles, and values that affect dependency resolution or
compilation. Use a stable evaluation stub when a manifest requires unrelated
release metadata to exist. Application compile inputs follow dependency
compilation; runtime configuration follows application compilation; per-build
metadata belongs in the final image layer.

## Why

An `ARG`, `ENV`, `COPY`, or `RUN` changes its Docker layer's cache key. Every
following instruction inherits that changed parent, even when its own inputs are
unchanged. A volatile application input before dependency compilation turns a
small source rebuild into dependency recompilation on every edit.

## Good

```dockerfile
RUN printf '0.0.0-dev\n' > VERSION
COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY VERSION ./
ARG COMPILE_FEATURE=""
ENV COMPILE_FEATURE=${COMPILE_FEATURE}
COPY config/config.exs config/prod.exs config/
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

ARG SOURCE_REVISION=dev
RUN printf '%s\n' "$SOURCE_REVISION" > /app/REVISION
```

## Bad

```dockerfile
ARG SOURCE_REVISION
ENV SOURCE_REVISION=$SOURCE_REVISION
COPY config config
COPY lib lib
RUN mix deps.get
RUN mix deps.compile
```

## Enforcement

Review the first instruction that consumes every Docker build input. For a
cache-sensitive change, build variants that alter one input class at a time and
verify BuildKit reports every preceding expensive step as `CACHED`.
