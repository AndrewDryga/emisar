package main

import (
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"text/tabwriter"

	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// writePackInfo renders the operator-facing "how to make this pack work"
// summary: what it does, its action/risk profile, host prerequisites, and
// the setup block (auth env vars + notes). It is shared by `pack install`
// (printed after a successful install) and `pack info`.
//
// The verify step is deliberately NOT part of it: `pack install` runs the
// probe and prints its result, while `pack info` prints the command. Each
// caller appends whichever of the two it owns.
//
// inheritEnv is the runner's configured inherit_env allowlist; haveConfig
// says whether a config was actually resolved. Together they drive the
// "required var missing from inherit_env" cross-check — the single most
// common reason a freshly installed pack can't authenticate.
func writePackInfo(w io.Writer, reg *packs.Registry, p *packspec.Pack, inheritEnv []string, haveConfig bool) {
	style := newStyler(w)
	fmt.Fprintf(w, "\n%s — %s  (v%s)\n", style.bold(p.ID), p.Name, p.Version)
	for _, line := range wrapText(collapseSpace(p.Description), 72) {
		fmt.Fprintf(w, "  %s\n", line)
	}

	low, med, high, crit, total := riskCounts(reg, p.ID)
	fmt.Fprintf(w, "\n  %s   %d  (%s)\n", style.bold("Actions:"), total, riskSummary(style, low, med, high, crit))
	fmt.Fprintf(w, "  %s  %s\n", style.bold("Requires:"), requiresLine(style, p.Requires))
	if hash, ok := reg.PackHash(p.ID); ok {
		fmt.Fprintf(w, "  %s      %s\n", style.bold("Hash:"), style.dim(hash))
	}
	// The pack names its own page — the runner never derives one, because a
	// self-hosted registry's packs do not live on our site. A pack that
	// declares no homepage simply gets no line.
	if p.Homepage != "" {
		fmt.Fprintf(w, "  %s      %s\n", style.bold("Docs:"), p.Homepage)
	}

	writeSetup(w, style, p, inheritEnv, haveConfig)
}

// writeSetup renders the pack's setup block. A pack with no setup content
// (typically one that acts only on the local host) gets a single honest
// line rather than an empty section.
func writeSetup(w io.Writer, style styler, p *packspec.Pack, inheritEnv []string, haveConfig bool) {
	s := p.Setup
	fmt.Fprintf(w, "\n  %s\n", style.bold("Setup"))

	if s.Summary == "" && len(s.Env) == 0 && len(s.Notes) == 0 && len(s.HostAccess) == 0 && s.Verify == "" {
		fmt.Fprintf(w, "    No credentials needed — operates on the local runner host.\n")
		return
	}

	summary, summaryLinks := setupProse(collapseSpace(s.Summary))
	for _, line := range wrapText(summary, 70) {
		fmt.Fprintf(w, "    %s\n", line)
	}
	writeLinks(w, "    ", summaryLinks)

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
			warning := fmt.Sprintf("! Required vars not in this config's inherit_env: %s", strings.Join(missing, ", "))
			fmt.Fprintf(w, "\n    %s\n", style.warn(warning))
			fmt.Fprintf(w, "      Add them under execution.inherit_env or the pack can't authenticate.\n")
		}
	}

	if len(s.HostAccess) > 0 {
		fmt.Fprintf(w, "\n    %s\n", style.bold("Host access:"))
		for _, line := range wrapText("Run these commands yourself on the runner host; Emisar never runs setup recipes.", 66) {
			fmt.Fprintf(w, "      %s\n", line)
		}
		for _, access := range s.HostAccess {
			requirement, requirementLinks := setupProse(collapseSpace(access.Requirement))
			fmt.Fprintf(w, "\n      %s\n", style.bold(requirement))
			writeLinks(w, "        ", requirementLinks)
			for _, line := range wrapText("Actions: "+strings.Join(access.Actions, ", "), 62) {
				fmt.Fprintf(w, "        %s\n", line)
			}
			for _, recipe := range access.Recipes {
				name, nameLinks := setupProse(collapseSpace(recipe.Name))
				fmt.Fprintf(w, "\n        %s\n", style.bold(name))
				writeLinks(w, "          ", nameLinks)
				for _, command := range recipe.Commands {
					fmt.Fprintf(w, "          %s\n", command)
				}
				fmt.Fprintf(w, "          Verify:\n")
				for _, command := range recipe.Verify {
					fmt.Fprintf(w, "            %s\n", command)
				}
				impact, impactLinks := setupProse(collapseSpace(recipe.Impact))
				for _, line := range wrapText("Impact: "+impact, 60) {
					fmt.Fprintf(w, "          %s\n", line)
				}
				writeLinks(w, "            ", impactLinks)
			}
		}
	}

	if len(s.Notes) > 0 {
		fmt.Fprintf(w, "\n    %s\n", style.bold("Notes:"))
		for _, n := range s.Notes {
			note, noteLinks := setupProse(collapseSpace(n))
			writeBullet(w, "      ", note)
			writeLinks(w, "        ", noteLinks)
		}
	}

}

// writeVerifyHint names the command that proves the pack is configured. It
// points at `pack verify`, not the raw `action run` behind it: that command
// supplies the reason, reports a required argument the host cannot infer as a
// completable command rather than a validation error, and reads the same on
// every pack.
func writeVerifyHint(w io.Writer, p *packspec.Pack) {
	if p.Setup.Verify == "" {
		return
	}
	style := newStyler(w)
	fmt.Fprintf(w, "\n  %s\n    emisar pack verify %s\n", style.bold("Verify it works:"), p.ID)
}

// envDetail builds the right-hand description column for one env var,
// folding in its default and example when present.
func envDetail(e packspec.EnvVar) string {
	description, _ := setupProse(e.Description)
	d := strings.TrimSpace(description)
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
func requiresLine(style styler, r packspec.Requirements) string {
	var parts []string
	if len(r.OS) > 0 {
		parts = append(parts, strings.Join(r.OS, "/"))
	}
	for _, b := range r.Binaries {
		if _, err := exec.LookPath(b); err == nil {
			parts = append(parts, b+" "+style.ok("✓"))
		} else {
			parts = append(parts, b+" "+style.fail("✗ (not on PATH)"))
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

func riskSummary(style styler, low, med, high, crit int) string {
	var parts []string
	add := func(n int, tier string) {
		if n > 0 {
			parts = append(parts, style.riskLabel(fmt.Sprintf("%d %s", n, tier), tier))
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

// collapseSpace folds any run of whitespace (incl. the newlines YAML
// folded scalars leave behind) into single spaces.
func collapseSpace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// wrapText word-wraps s to at most width columns, returning one string per
// line. Empty input yields no lines.
// setupLink matches the same opt-in link syntax the pack page renders. Only
// https, so an authored `javascript:` or `file:` target is never presented as
// somewhere to go.
var setupLink = regexp.MustCompile(`\[([^\]\n]+)\]\((https://[^\s)]+)\)`)

// setupProse renders one authored setup string for a terminal. Pack setup text
// carries light markdown so the public pack page can format it; here that
// markup would be noise or, worse, damage:
//
//   - Inline-code ticks are dropped. A terminal has no code chip, and an ANSI
//     style is not an option — wrapText measures with len(), so escape bytes
//     would count toward the width and wrap the line early.
//   - A [label](url) link becomes its label, with the URL returned separately
//     to print UNWRAPPED on its own line. Left inline it wraps mid-URL, which
//     is neither clickable nor copyable — the whole reason to print it.
func setupProse(text string) (prose string, links []string) {
	prose = setupLink.ReplaceAllStringFunc(text, func(match string) string {
		parts := setupLink.FindStringSubmatch(match)
		links = append(links, parts[2])
		return parts[1]
	})
	return strings.ReplaceAll(prose, "`", ""), links
}

// writeLinks prints each URL alone on its own line, never wrapped, so a
// terminal can linkify it and an operator can select it whole.
func writeLinks(w io.Writer, indent string, links []string) {
	for _, link := range links {
		fmt.Fprintf(w, "%s%s\n", indent, link)
	}
}

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
