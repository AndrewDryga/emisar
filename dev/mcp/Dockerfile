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
#   docker buildx imagetools inspect golang:1.27.3-alpine3.24 --format '{{.Manifest.Digest}}'
# then paste the new digest below (keep the tag in sync).

FROM golang:1.27.3-alpine3.24@sha256:d530cf60723abf1ffae0cd16bb546b379ec0550d2f3815e5b16ed69dbc00fba4 AS builder

WORKDIR /src
COPY mcp/go.mod ./
# mcp/ has no third-party deps so there's no go.sum to copy.
RUN go mod download

COPY mcp/ ./
ARG MCP_VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${MCP_VERSION}" \
    -o /out/emisar-mcp \
    .

# --- runtime -------------------------------------------------------

# Digest-pinned (refresh via the buildx imagetools command noted above).
FROM alpine:3.24.3@sha256:b3413572228e34bd1c9245f5565e6cd127005655e8a7899aef33d8e83255c9e6

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
