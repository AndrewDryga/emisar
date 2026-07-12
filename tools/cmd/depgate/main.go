// Command depgate fails a dependency bump when the new version is too fresh.
//
// It lives in the tools module — NEVER in runner/ or mcp/. Those modules are
// CLIENT-SHIPPED artifacts: self-hosters install those binaries and audit
// those go.sums, so they carry exactly what a host needs and nothing else.
// Repo/CI/maintainer tooling belongs here (the one sanctioned exception is
// packctl, which must share the runner module for pack-hash parity). This
// module never ships and stays dependency-free unless a tool truly needs one.
//
// What it does: emisar is a security product — a dependency release that
// landed hours ago is a supply-chain risk (a compromised maintainer account,
// a typosquat, a rushed malicious minor), not harmless churn. The native
// package-manager layers help but none of them ENFORCE across every author
// (re-verified 2026-07-12): Hex >= 2.5 has a resolver cooldown, adopted via
// HEX_COOLDOWN — but versions already in mix.lock bypass it by design; Go
// modules and npm (as of 11.17) have no age control at all; Dependabot's
// cooldown only shapes the PRs it opens itself. So CI diffs the committed
// manifests against the base ref and rejects any added/upgraded version
// published more recently than the policy window for its bump type — a human
// bump, another bot, or a hand-edited lockfile all hit the same wall.
//
// The escape hatch for an urgent security fix is an audited entry in
// .dep-age-allow (repo root) — a committed, reviewable paper trail. Windows
// mirror .github/dependabot.yml cooldown; keep them in sync when either
// changes.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "check" {
		fmt.Fprintln(os.Stderr, "usage: depgate check [--base <git ref>]")
		os.Exit(2)
	}

	defaultBase := os.Getenv("DEP_AGE_BASE_REF")
	if defaultBase == "" {
		defaultBase = "origin/main"
	}
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	baseRef := fs.String("base", defaultBase, "base git ref to diff dependency versions against")
	if err := fs.Parse(os.Args[2:]); err != nil {
		os.Exit(2)
	}

	// Exit codes are the contract CI reads: 0 clean, 1 a too-fresh or
	// unverifiable dependency (or an unvetted non-registry source), 2 internal.
	os.Exit(runCheck(*baseRef))
}
