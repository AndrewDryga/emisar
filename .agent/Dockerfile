ARG COOP_BASE_IMAGE=coop-box:latest
FROM ${COOP_BASE_IMAGE}

USER node
ENV MIX_BUILD_ROOT=/home/node/.cache/mix-build/emisar \
    GOMODCACHE=/home/node/.cache/go-mod \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer

# New boxes and forks should not compile Erlang before doing useful work. This
# layer changes only when the repo's canonical toolchain pins change.
COPY --chown=node:node .tool-versions /home/node/.tool-versions
RUN cd /home/node \
 && awk 'NF && $1 !~ /^#/ {print $1}' .tool-versions | while read -r tool; do asdf plugin add "$tool"; done \
 && MAKEFLAGS="-j$(nproc)" asdf install \
 && asdf reshim \
 && mix local.hex --force \
 && mix local.rebar --force

# Keep UI-only packages below the toolchain layer so browser changes do not
# trigger another Erlang/Elixir/Go build. Debian provides native ARM Chromium.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium-headless-shell imagemagick \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Bake the exact pinned browser on amd64. ARM boxes use Debian's native shell;
# Puppeteer's Linux download is x86_64 even when the build host is ARM64.
USER node
ENV PUPPETEER_CACHE_DIR=/home/node/.local/share/puppeteer
COPY --chown=node:node portal/.agent/scripts/package.json \
     portal/.agent/scripts/package-lock.json \
     portal/.agent/scripts/install-browser.mjs \
     /home/node/emisar-screenshot-tooling/
RUN cd /home/node/emisar-screenshot-tooling \
 && npm ci --ignore-scripts \
 && if [ "$(dpkg --print-architecture)" = amd64 ]; then npm run browser:install; fi

WORKDIR /workspace
