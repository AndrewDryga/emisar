# Staticcheck Go 1.27.2 compatibility backport

The gate builds official Staticcheck `honnef.co/go/tools v0.8.1` (2026.2.1)
with released `golang.org/x/tools v0.50.0`. The latter understands Go's V5
export data, including generic method ordering. No analyzer is replaced.

`classify_call.go.original` is the exact released source at
`internal/xtools-internal/typesinternal/classify_call.go`, SHA256
`2cdb89a64e8fbcd62730f1c6a1ea1e68f0ee3311cad9aacaa5d3c42a9ad78952`.
The patched file removes its two links to private x/tools functions and copies
the corresponding released implementations from
[x/tools v0.50.0](https://github.com/golang/tools/blob/v0.50.0/internal/typesinternal/classify_call.go).
This is the call-classification repair proposed in
[upstream PR 1834](https://github.com/dominikh/go-tools/pull/1834), not a pin
to that fork or to unrelated unreleased analyzer changes.

The gate verifies module checksums and the original file hash, copies source
to a private temporary tree, patches only this file, builds the unchanged
official command using a version-scoped temporary replacement, then runs it
from the original analysis directory. The module cache and target manifests
remain unchanged. Gate output identifies the patched source hash; ordinary
Go build information alone does not identify that patch. The Go Authors'
BSD license is retained here.

Remove the backport and temporary-build helper when an official Staticcheck
release supports V5 and has cleared the dependency age window. Continue to
invoke the pinned tool inside every canonical Go gate.
