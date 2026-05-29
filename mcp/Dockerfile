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
#         --network emisar_default \
#         emisar/mcp

# --- builder -------------------------------------------------------

FROM golang:1.26-alpine AS builder

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

FROM alpine:3.20

RUN apk add --no-cache ca-certificates

COPY --from=builder /out/emisar-mcp /usr/local/bin/emisar-mcp

# No ENTRYPOINT — emisar-mcp speaks JSON-RPC over stdio. Compose drives
# this image with `docker compose run --rm -T mcp` and supplies the
# JSON-RPC payload on stdin.
CMD ["/usr/local/bin/emisar-mcp"]
