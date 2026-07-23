# Docker inputs enter at their narrowest layer

## Rule

Introduce each `COPY`, build argument, and environment variable immediately
before its first real consumer. Dependency layers contain only toolchain,
dependency manifests, lockfiles, and values that affect dependency resolution or
compilation. Use a stable evaluation stub when a manifest requires unrelated
release metadata to exist. Application compile inputs follow dependency
compilation; runtime configuration follows application compilation; per-build
metadata belongs in the final image layer.

`.dockerignore` belongs to the build context, not to the Dockerfile's location.
Keep one context-level ignore file when every recipe using that context needs
the same exclusions. Add a Dockerfile-specific
`<Dockerfile filename>.dockerignore`, which takes precedence for that recipe,
only when multiple recipes intentionally share one context but require
different inputs.

When first-party images already share an intentionally filtered repository-root
context, use that context consistently unless a narrower context is a real
isolation boundary or materially reduces inputs. Do not preserve a
module-specific context and ignore file solely because its Dockerfile used to
live beside the module.

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

`dev/mcp/Dockerfile` shares the filtered repository-root context with the
packaged Portal and runner images, then copies only `mcp/go.mod` and `mcp/`.
Unrelated repository edits do not invalidate those layers.

## Bad

```dockerfile
ARG SOURCE_REVISION
ENV SOURCE_REVISION=$SOURCE_REVISION
COPY config config
COPY lib lib
RUN mix deps.get
RUN mix deps.compile
```

Keeping `mcp/` as a one-off context with its own `.dockerignore` after every
packaged Compose image adopts the filtered root context creates a second policy
and different path semantics without creating a meaningful isolation boundary.

## Enforcement

Review the first instruction that consumes every Docker build input. For a
cache-sensitive change, build variants that alter one input class at a time and
verify BuildKit reports every preceding expensive step as `CACHED`.
For every ignore file, identify the exact build context and confirm whether any
other Dockerfile shares it before introducing a recipe-specific override.
Before adding a module-local context, compare the filtered context size and the
Dockerfile's actual `COPY` inputs; keep the exception only when the narrower
boundary has a concrete benefit.
