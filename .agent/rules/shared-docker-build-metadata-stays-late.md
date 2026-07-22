# Docker build metadata stays after reusable layers

## Rule

Consume commit SHAs, build IDs, timestamps, and other per-build metadata only
after every source-stable toolchain, dependency, asset, application, and release
layer. Prefer a final runtime file or image-config layer for metadata the running
application must report.

## Why

An `ARG` used by an early `ENV` or `RUN` changes that instruction's cache key.
Every following Docker layer then rebuilds even when its real inputs are
unchanged. A commit SHA before dependency compilation turns a useful BuildKit
cache into a full build on every commit.

## Good

```dockerfile
COPY --from=builder /app/release ./
ARG SOURCE_REVISION=dev
RUN printf '%s\n' "$SOURCE_REVISION" > /app/REVISION
```

## Bad

```dockerfile
ARG SOURCE_REVISION
ENV SOURCE_REVISION=$SOURCE_REVISION
RUN mix deps.get
RUN mix deps.compile
```

## Enforcement

Review the first instruction that consumes each volatile build argument. For a
cache-sensitive change, build twice with only that argument changed and verify
BuildKit reports every preceding expensive step as `CACHED`.
