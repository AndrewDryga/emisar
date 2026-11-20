# Development image for the emisar-mcp stdio bridge. The packaged Compose
# topology and `./run e2e signing` use it to exercise the real bridge on the
# same Docker network as the portal. It is not a published product image.
#
# Build context is the repository root, shared with the other packaged Compose
# images. COPY still introduces only the MCP module's inputs.
#
#   docker build -f dev/mcp/Dockerfile -t emisar/mcp .
#
# Driving it (one-shot JSON-RPC request):
#
#   echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
#     | docker run --rm -i \
#         -e EMISAR_URL=http://portal:4000 \
#         -e EMISAR_API_KEY=emk-... \
#         -e EMISAR_ALLOW_INSECURE=1 \
#         -v emisar-mcp-config:/config \
#         --network emisar_default \
#         emisar/mcp

# --- builder -------------------------------------------------------
#
# Base images are digest-pinned for supply-chain integrity: the tag
# documents the version, the @sha256 pins the exact multi-arch index so a
# rebuild is reproducible and a moved/republished tag can't swap the base
# out. Refresh (when bumping a tag or pulling security patches) with:
#   docker buildx imagetools inspect golang:1.27.4-alpine3.24 --format '{{.Manifest.Digest}}'
# then paste the new digest below (keep the tag in sync).

FROM golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS builder

WORKDIR /src
# mcp/ is stdlib-only (no go.sum), so there is no dependency layer to cache.
COPY mcp/ ./
ARG MCP_VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${MCP_VERSION}" \
    -o /out/emisar-mcp \
    .

# --- runtime -------------------------------------------------------

# Digest-pinned (refresh via the buildx imagetools command noted above).
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache ca-certificates \
    && adduser -S -D -H emisar \
    && mkdir -p /config \
    && chown emisar /config

COPY --from=builder /out/emisar-mcp /usr/local/bin/emisar-mcp

ENV XDG_CONFIG_HOME=/config
VOLUME ["/config"]

USER emisar

# No ENTRYPOINT: emisar-mcp speaks JSON-RPC over stdio. Compose drives
# this image with `docker compose run --rm -T mcp` and supplies the
# JSON-RPC payload on stdin.
CMD ["/usr/local/bin/emisar-mcp"]
