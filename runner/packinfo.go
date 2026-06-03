package main

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
	"text/tabwriter"

	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// writePackInfo renders the operator-facing "how to make this pack work"
// summary: what it does, its action/risk profile, host prerequisites, and
// the setup block (auth env vars + notes + a verify command). It is shared
// by `pack install` (printed after a successful install) and `pack info`.
//
// inheritEnv is the runner's configured inherit_env allowlist; haveConfig
// says whether a config was actually resolved. Together they drive the
// "required var missing from inherit_env" cross-check — the single most
// common reason a freshly installed pack can't authenticate.
func writePackInfo(w io.Writer, reg *packs.Registry, p *packspec.Pack, inheritEnv []string, haveConfig bool) {
	fmt.Fprintf(w, "\n%s — %s  (v%s)\n", p.ID, p.Name, p.Version)
	for _, line := range wrapText(collapseSpace(p.Description), 72) {
		fmt.Fprintf(w, "  %s\n", line)
	}

	low, med, high, crit, total := riskCounts(reg, p.ID)
	fmt.Fprintf(w, "\n  Actions:   %d  (%s)\n", total, riskSummary(low, med, high, crit))
	fmt.Fprintf(w, "  Requires:  %s\n", requiresLine(p.Requires))
	if hash, ok := reg.PackHash(p.ID); ok {
		fmt.Fprintf(w, "  Hash:      %s\n", hash)
	}

	writeSetup(w, p, inheritEnv, haveConfig)
}

// writeSetup renders the pack's setup block. A pack with no setup content
// (typically one that acts only on the local host) gets a single honest
// line rather than an empty section.
func writeSetup(w io.Writer, p *packspec.Pack, inheritEnv []string, haveConfig bool) {
	s := p.Setup
	fmt.Fprintf(w, "\n  Setup\n")

	if s.Summary == "" && len(s.Env) == 0 && len(s.Notes) == 0 && s.Verify == "" {
		fmt.Fprintf(w, "    No credentials needed — operates on the local runner host.\n")
		return
	}

	for _, line := range wrapText(collapseSpace(s.Summary), 70) {
		fmt.Fprintf(w, "    %s\n", line)
	}

	if len(s.Env) > 0 {
		fmt.Fprintf(w, "\n    Environment — set on the runner host, then add each to inherit_env:\n")
		tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
		for _, e := range s.Env {
			req := ""
			if e.Required {
				req = "required"
			}
			fmt.Fprintf(tw, "      %s\t%s\t%s\n", e.Name, req, envDetail(e))
		}
		tw.Flush()
	}

	if haveConfig {
		if missing := missingRequiredEnv(s.Env, inheritEnv); len(missing) > 0 {
			fmt.Fprintf(w, "\n    ! Required vars not in this config's inherit_env: %s\n", strings.Join(missing, ", "))
			fmt.Fprintf(w, "      Add them under execution.inherit_env or the pack can't authenticate.\n")
		}
	}

	if len(s.Notes) > 0 {
		fmt.Fprintf(w, "\n    Notes:\n")
		for _, n := range s.Notes {
			writeBullet(w, "      ", collapseSpace(n))
		}
	}

	if s.Verify != "" {
		fmt.Fprintf(w, "\n    Verify it works:\n      emisar action run %s --config %s\n", s.Verify, configPathHint())
	}
}

// envDetail builds the right-hand description column for one env var,
// folding in its default and example when present.
func envDetail(e packspec.EnvVar) string {
	d := strings.TrimSpace(e.Description)
	if e.Default != "" {
		d = strings.TrimSpace(d + fmt.Sprintf(" (default: %s)", e.Default))
	}
	if e.Example != "" {
		d = strings.TrimSpace(d + fmt.Sprintf(" [e.g. %s]", e.Example))
	}
	return d
}

// missingRequiredEnv returns the names of required env vars that are not in
// the inherit_env allowlist — the vars the pack documents but the runner
// would currently drop before exec.
func missingRequiredEnv(env []packspec.EnvVar, inheritEnv []string) []string {
	allow := make(map[string]struct{}, len(inheritEnv))
	for _, k := range inheritEnv {
		allow[k] = struct{}{}
	}
	var missing []string
	for _, e := range env {
		if !e.Required {
			continue
		}
		if _, ok := allow[e.Name]; !ok {
			missing = append(missing, e.Name)
		}
	}
	return missing
}

// requiresLine renders the OS list and each required binary with a live
// PATH check (✓ / ✗). The check runs as the installing user, whose PATH
// may differ from the runner service — it's a hint, not a gate.
func requiresLine(r packspec.Requirements) string {
	var parts []string
	if len(r.OS) > 0 {
		parts = append(parts, strings.Join(r.OS, "/"))
	}
	for _, b := range r.Binaries {
		if _, err := exec.LookPath(b); err == nil {
			parts = append(parts, b+" ✓")
		} else {
			parts = append(parts, b+" ✗ (not on PATH)")
		}
	}
	if len(parts) == 0 {
		return "—"
	}
	return strings.Join(parts, " · ")
}

func riskCounts(reg *packs.Registry, packID string) (low, med, high, crit, total int) {
	for _, a := range reg.Actions() {
		if a.PackID != packID {
			continue
		}
		total++
		switch a.Risk {
		case actionspec.RiskLow:
			low++
		case actionspec.RiskMedium:
			med++
		case actionspec.RiskHigh:
			high++
		case actionspec.RiskCritical:
			crit++
		}
	}
	return
}

func riskSummary(low, med, high, crit int) string {
	var parts []string
	add := func(n int, label string) {
		if n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", n, label))
		}
	}
	add(low, "low")
	add(med, "medium")
	add(high, "high")
	add(crit, "critical")
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, " · ")
}

// configPathHint is the --config value to show in the verify command:
// the one in use if set, else the canonical install location.
func configPathHint() string {
	if flagConfig != "" {
		return flagConfig
	}
	return "/etc/emisar/config.yaml"
}

// collapseSpace folds any run of whitespace (incl. the newlines YAML
// folded scalars leave behind) into single spaces.
func collapseSpace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// wrapText word-wraps s to at most width columns, returning one string per
// line. Empty input yields no lines.
func wrapText(s string, width int) []string {
	words := strings.Fields(s)
	if len(words) == 0 {
		return nil
	}
	lines := make([]string, 0, 4)
	cur := words[0]
	for _, wd := range words[1:] {
		if len(cur)+1+len(wd) > width {
			lines = append(lines, cur)
			cur = wd
		} else {
			cur += " " + wd
		}
	}
	return append(lines, cur)
}

// writeBullet prints a wrapped bullet with a hanging indent so wrapped
// lines align under the text, not the marker.
func writeBullet(w io.Writer, indent, text string) {
	lines := wrapText(text, 70)
	if len(lines) == 0 {
		return
	}
	fmt.Fprintf(w, "%s- %s\n", indent, lines[0])
	for _, l := range lines[1:] {
		fmt.Fprintf(w, "%s  %s\n", indent, l)
	}
}
