ARG COOP_BASE_IMAGE=coop-box:latest
FROM ${COOP_BASE_IMAGE}

USER node
ENV MIX_BUILD_ROOT=/home/node/.cache/mix-build/emisar \
    GOMODCACHE=/home/node/.cache/go-mod

# Coop's filtered client image keeps asdf's shims off PATH, so put them back,
# after the client launchers, which nothing may shadow.
ENV PATH="/opt/coop/bin:/home/node/.asdf/shims:${PATH}"

# New boxes and forks should not compile Erlang before doing useful work. This
# layer changes only when the repo's canonical toolchain pins change.
COPY --chown=node:node .tool-versions /home/node/.tool-versions
RUN cd /home/node \
 && awk 'NF && $1 !~ /^#/ {print $1}' .tool-versions | while read -r tool; do asdf plugin add "$tool"; done \
 && MAKEFLAGS="-j$(nproc)" asdf install \
 && asdf reshim \
 && mix local.hex --force \
 && mix local.rebar --force

# Keep project gate and UI packages below the toolchain layer. The Go browser
# driver uses Debian Chromium on every box architecture; no second package
# manager or separately downloaded browser enters the build.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium-headless-shell imagemagick shellcheck \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Login shells reset PATH, so restore the same order after /etc/profile runs.
# This drop-in sorts after Coop's own, which leaves the shims out in a filtered box.
RUN printf 'export PATH="/opt/coop/bin:/home/node/.asdf/shims:$PATH"\n' > /etc/profile.d/zz-asdf.sh

USER node
# Portal deps join the build output in the box cache: Phoenix's compile alias
# writes inside deps/ on every deps.compile, and a box gate must write nothing
# into the mounted repo. Declared after the toolchain layer so tuning it never
# recompiles Erlang; the gate self-heals an empty cache (deps.get --check-locked).
ENV MIX_DEPS_PATH=/home/node/.cache/mix-deps/emisar
WORKDIR /workspace
