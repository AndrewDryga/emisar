# Dockerfile for the emisar-mcp stdio bridge.
#
# Normally emisar-mcp runs on the operator's laptop, spawned as a child
# process by Claude Code / Cursor / etc. This image exists so the
# binary is available inside the dev compose stack for ad-hoc testing
# (e.g., feeding JSON-RPC through stdin to verify end-to-end calls
# against a local portal).
#
# Build context is the mcp module (mcp/), so COPY paths are relative.
#
#   docker build -f mcp/Dockerfile -t emisar/mcp mcp/
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
#   docker buildx imagetools inspect golang:1.26-alpine --format '{{.Manifest.Digest}}'
# then paste the new digest below (keep the tag in sync).

FROM golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder

WORKDIR /src
COPY go.mod ./
# mcp/ has no third-party deps so there's no go.sum to copy.
RUN go mod download

COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=dev" \
    -o /out/emisar-mcp \
    .

# --- runtime -------------------------------------------------------

# Digest-pinned (refresh via the buildx imagetools command noted above).
FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

RUN apk add --no-cache ca-certificates \
    && adduser -S -D -H emisar \
    && mkdir -p /config \
    && chown emisar /config

COPY --from=builder /out/emisar-mcp /usr/local/bin/emisar-mcp

ENV XDG_CONFIG_HOME=/config
VOLUME ["/config"]

USER emisar

# No ENTRYPOINT — emisar-mcp speaks JSON-RPC over stdio. Compose drives
# this image with `docker compose run --rm -T mcp` and supplies the
# JSON-RPC payload on stdin.
CMD ["/usr/local/bin/emisar-mcp"]
