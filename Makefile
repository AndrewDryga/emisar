# emisar dev Makefile. CI lives in .github/workflows/ — this is for
# local convenience only.
#
# Monorepo layout:
#   runner/   Go module — the on-host runner binary
#   mcp/      Go module — the MCP stdio bridge for LLM clients
#   portal/   Elixir umbrella — the control plane (see portal/README.md)

GO        ?= go
VERSION   ?= dev
LDFLAGS   ?= -s -w -X main.Version=$(VERSION)

.PHONY: all
all: build

.PHONY: build
build:
	cd runner && $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o ../bin/emisar .
	cd mcp    && $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o ../bin/emisar-mcp .

.PHONY: install
install:
	cd runner && $(GO) install -trimpath -ldflags "$(LDFLAGS)" .
	cd mcp    && $(GO) install -trimpath -ldflags "$(LDFLAGS)" .

# Cross-build the four target platforms the release workflow ships.
.PHONY: build-all
build-all:
	@mkdir -p dist
	@set -e; for pair in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do \
	    os="$${pair%/*}"; arch="$${pair#*/}"; \
	    echo "==> $${os}/$${arch}"; \
	    ( cd runner && GOOS=$${os} GOARCH=$${arch} CGO_ENABLED=0 \
	      $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o ../dist/emisar-$${os}-$${arch} . ); \
	    ( cd mcp && GOOS=$${os} GOARCH=$${arch} CGO_ENABLED=0 \
	      $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o ../dist/emisar-mcp-$${os}-$${arch} . ); \
	done

.PHONY: test
test:
	cd runner && $(GO) test -race -count=1 ./...
	cd mcp    && $(GO) test -race -count=1 ./...

.PHONY: cover
cover:
	cd runner && $(GO) test -race -count=1 -coverprofile=../coverage.out ./...
	$(GO) tool cover -func=coverage.out | tail -40

# Run runner tests inside a Debian-based Docker container. Useful from
# macOS for verifying Linux-specific behaviour (Pdeathsig, /var/log
# symlinks).
.PHONY: test-linux
test-linux:
	docker build -f runner/Dockerfile.test -t emisar-test runner/
	docker run --rm emisar-test

.PHONY: vet
vet:
	cd runner && $(GO) vet ./...
	cd mcp    && $(GO) vet ./...

.PHONY: shellcheck
shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed (brew install shellcheck)"; exit 1; }
	shellcheck install.sh
	bash -n install.sh

.PHONY: fmt
fmt:
	gofmt -w -s runner/ mcp/

.PHONY: fmt-check
fmt-check:
	@diff=$$(gofmt -d -s runner/ mcp/ | head -200); \
	  if [ -n "$$diff" ]; then \
	    echo "gofmt diff:"; echo "$$diff"; exit 1; \
	  fi

# Mirror of the CI checks. Run before pushing a branch.
.PHONY: ci-local
ci-local: vet fmt-check shellcheck test

.PHONY: clean
clean:
	rm -rf bin/ dist/ coverage.out runner/examples/var/
