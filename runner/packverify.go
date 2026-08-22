package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// verifyReason is the reason recorded on the journal entry every probe
// writes. The probe executes a real action, so it is audited exactly like an
// operator-initiated `action run` — there is no unlogged execution path.
const verifyReason = "pack verify"

// verifyDetailMax bounds the failure detail we print. A pack's target answers
// with whatever it likes; the row stays one line so a fleet-wide run reads as
// a table rather than a wall of vendor error text.
const verifyDetailMax = 160

// Probe outcomes. Skipped is deliberately NOT a failure: a pack whose verify
// action needs an operator-supplied argument, or one this host's admission
// policy refuses, is not a broken pack, and failing the run on it would make
// the whole check noise on any fleet that carries such a pack.
const (
	verifyOK      = "ok"
	verifySkipped = "skipped"
	verifyFailed  = "failed"
)

// verifyResult is one pack's probe outcome. Detail explains a failure or the
// reason for a skip, and is what an operator acts on.
type verifyResult struct {
	PackID     string `json:"pack_id"`
	ActionID   string `json:"action_id,omitempty"`
	Status     string `json:"status"`
	Detail     string `json:"detail,omitempty"`
	DurationMS int64  `json:"duration_ms,omitempty"`
}

// packVerifyReport is the --json form of a verify run: the same rows the human
// table renders, plus counts so fleet tooling branches on the verdict instead
// of parsing columns.
type packVerifyReport struct {
	Status  string         `json:"status"`
	OK      int            `json:"ok"`
	Failed  int            `json:"failed"`
	Skipped int            `json:"skipped"`
	Packs   []verifyResult `json:"packs"`
}

func newPackVerifyReport(results []verifyResult) packVerifyReport {
	report := packVerifyReport{Status: verifyOK, Packs: results}
	for _, r := range results {
		switch r.Status {
		case verifyFailed:
			report.Failed++
		case verifySkipped:
			report.Skipped++
		default:
			report.OK++
		}
	}
	if report.Failed > 0 {
		report.Status = verifyFailed
	}
	return report
}

func packVerifyCmd() *cobra.Command {
	var argList []string
	cmd := &cobra.Command{
		Use:   "verify [<id>...]",
		Short: "Run each installed pack's declared verify action to prove it is configured",
		Long: `Run the low-risk read action each pack declares as setup.verify — the
one that proves the pack can reach and authenticate to its target. With no
arguments every installed pack is probed; name packs to probe only those.

The probe runs locally through the same path as 'action run': the argument
schema, this runner's admission policy, output redaction, and the local audit
journal all apply. Nothing is dispatched from the control plane.

A pack whose verify action needs an argument this host cannot infer (a
project id, a hostname, a pid) is SKIPPED, not failed — probe it directly
with --arg. Admission-blocked packs are skipped too: refusing an action is
the operator's own decision, not a broken pack. Exit status is non-zero only
if a probe actually failed.

A failure means the pack could not complete a read against its target. That is
usually a missing or wrong credential, but a target that is simply down looks
the same — read the detail before concluding the pack is misconfigured.`,
		Example: `  # Probe every installed pack
  emisar pack verify

  # Probe one pack, supplying the argument its verify action requires
  emisar pack verify gcp-dns --arg project=acme-prod`,
		RunE: func(cmd *cobra.Command, args []string) error {
			probeArgs, err := parseArgFlag(argList)
			if err != nil {
				return err
			}
			// --arg names one action's parameters, so it is only meaningful
			// against a single pack. Applied across a set it would feed the
			// same value to unrelated schemas and fail them all as
			// unknown_arg.
			if len(probeArgs) > 0 && len(args) != 1 {
				return fmt.Errorf("--arg needs exactly one pack id (got %d)", len(args))
			}

			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()

			targets, err := verifyTargets(rt, args)
			if err != nil {
				return err
			}
			results := verifyPacks(cmd.Context(), rt, targets, probeArgs)

			report := newPackVerifyReport(results)
			if flagJSONOut {
				if err := printJSON(report); err != nil {
					return err
				}
			} else {
				writeVerifyReport(os.Stdout, report)
			}
			if report.Failed > 0 {
				return fmt.Errorf("%d pack(s) failed verification", report.Failed)
			}
			return nil
		},
	}
	cmd.Flags().StringArrayVar(&argList, "arg", nil, "argument for the verify action as key=value (may repeat; single pack only)")
	return cmd
}

// verifyTargets resolves the packs to probe. With no ids every installed pack
// is probed, in id order; named ids must all be installed, so a typo is an
// error rather than a silently empty run.
func verifyTargets(rt *runtime, ids []string) ([]*packspec.Pack, error) {
	reg := rt.registry()
	if len(ids) == 0 {
		return reg.Packs(), nil
	}
	out := make([]*packspec.Pack, 0, len(ids))
	for _, id := range ids {
		p, ok := reg.Pack(id)
		if !ok {
			return nil, fmt.Errorf("pack %q not installed (looked in %s)",
				id, strings.Join(rt.cfg.Paths.Packs, ", "))
		}
		out = append(out, p)
	}
	return out, nil
}

// verifyPacks probes each pack in order. One pack's failure never stops the
// run — a single pass surfaces every problem at once, as doctor does.
func verifyPacks(ctx context.Context, rt *runtime, targets []*packspec.Pack, args map[string]any) []verifyResult {
	results := make([]verifyResult, 0, len(targets))
	for _, p := range targets {
		results = append(results, verifyPack(ctx, rt, p, args))
	}
	return results
}

// verifyPack runs one pack's declared setup.verify action and classifies the
// outcome.
func verifyPack(ctx context.Context, rt *runtime, p *packspec.Pack, args map[string]any) verifyResult {
	res := verifyResult{PackID: p.ID, ActionID: p.Setup.Verify}
	if p.Setup.Verify == "" {
		res.Status = verifySkipped
		res.Detail = "declares no verify action"
		return res
	}
	action, ok := rt.registry().Action(p.Setup.Verify)
	if !ok {
		// The loader rejects a setup.verify that isn't one of the pack's own
		// actions, so reaching here means the registry was built some other
		// way. Say so rather than reporting a healthy pack.
		res.Status = verifyFailed
		res.Detail = "declared verify action is not loaded"
		return res
	}
	if missing := missingRequiredArgs(action, args); len(missing) > 0 {
		res.Status = verifySkipped
		res.Detail = fmt.Sprintf("needs %s — probe it with: emisar pack verify %s %s",
			strings.Join(missing, ", "), p.ID, argHint(missing))
		return res
	}

	result, err := rt.engine.Run(ctx, engine.Request{
		ActionID: action.ID,
		Args:     args,
		Reason:   verifyReason,
	})
	if err != nil {
		res.Status = verifyFailed
		res.Detail = truncateDetail(err.Error())
		return res
	}
	res.DurationMS = result.DurationMS
	res.Status, res.Detail = classifyVerify(result)
	return res
}

// classifyVerify maps an engine result onto a probe outcome. Everything that
// isn't a clean success is a failure the operator should read, except an
// admission block — that is this host's own deny rule doing its job.
func classifyVerify(result *engine.Result) (status, detail string) {
	switch result.Status {
	case engine.StatusSuccess:
		return verifyOK, ""
	case engine.StatusBlockedByAdmission:
		return verifySkipped, "blocked by this runner's admission policy"
	case engine.StatusTimedOut:
		return verifyFailed, fmt.Sprintf("timed out after %dms", result.DurationMS)
	}
	return verifyFailed, truncateDetail(verifyFailureDetail(result))
}

// verifyFailureDetail builds the one-line explanation of a failed probe from
// the engine's own redacted output. It is the same text `action run` already
// prints to this terminal, bounded to a row — a pack's auth failure is where
// the actionable message lives ("permission denied", "invalid API key"), so
// dropping it for a bare exit code would make the check unusable.
//
// Stderr leads because it carries the target's own message; Reason is the
// engine's explanation and only wins when the process produced nothing (it
// failed to start, or the arguments never passed validation). Every one of
// these fields is redacted before the engine returns it.
func verifyFailureDetail(result *engine.Result) string {
	status := string(result.Status)
	// A negative exit code means the process never ran, so printing it would
	// read as a real exit status the operator could look up.
	if result.ExitCode > 0 {
		status = fmt.Sprintf("%s (exit %d)", status, result.ExitCode)
	}
	for _, candidate := range []string{result.Stderr, result.Reason, result.Error, result.Stdout} {
		if line := firstLine(candidate); line != "" {
			return status + ": " + line
		}
	}
	return status
}

// missingRequiredArgs names the required args the probe has no value for.
// A declared default does NOT satisfy a required arg — validation.Validate
// rejects it as missing before ever looking at Default — so this must test
// Required alone.
func missingRequiredArgs(action *actionspec.Action, args map[string]any) []string {
	var missing []string
	for _, a := range action.Args {
		if !a.Required {
			continue
		}
		if _, ok := args[a.Name]; !ok {
			missing = append(missing, a.Name)
		}
	}
	sort.Strings(missing)
	return missing
}

// argHint renders the --arg flags a skipped probe is waiting for, so the row
// carries a command the operator can complete rather than a diagnosis.
func argHint(names []string) string {
	flags := make([]string, 0, len(names))
	for _, n := range names {
		flags = append(flags, "--arg "+n+"=<value>")
	}
	return strings.Join(flags, " ")
}

func firstLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// truncateDetail bounds one detail string by RUNES, so a multi-byte message
// is never cut mid-character into invalid UTF-8.
func truncateDetail(s string) string {
	s = strings.TrimSpace(s)
	runes := []rune(s)
	if len(runes) <= verifyDetailMax {
		return s
	}
	return strings.TrimSpace(string(runes[:verifyDetailMax])) + "…"
}

// writeVerifyReport renders the probe rows as a table plus a count line.
func writeVerifyReport(w io.Writer, report packVerifyReport) {
	style := newStyler(w)
	if len(report.Packs) == 0 {
		fmt.Fprintln(w, "no packs installed")
		return
	}
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	for _, r := range report.Packs {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n",
			verifyStatusLabel(style, r.Status), r.PackID, r.ActionID, verifyRowDetail(r))
	}
	tw.Flush()

	counts := []string{fmt.Sprintf("%d ok", report.OK)}
	if report.Failed > 0 {
		counts = append(counts, style.fail(fmt.Sprintf("%d failed", report.Failed)))
	}
	if report.Skipped > 0 {
		counts = append(counts, style.dim(fmt.Sprintf("%d skipped", report.Skipped)))
	}
	fmt.Fprintf(w, "\n%s\n", strings.Join(counts, " · "))
}

// verifyRowDetail is the row's right-hand column: the failure or skip reason,
// or the probe's duration when it passed — a slow but healthy target is worth
// seeing, and an empty column would read as missing information.
func verifyRowDetail(r verifyResult) string {
	if r.Detail != "" {
		return r.Detail
	}
	if r.Status == verifyOK {
		return fmt.Sprintf("%dms", r.DurationMS)
	}
	return ""
}

func verifyStatusLabel(style styler, status string) string {
	switch status {
	case verifyOK:
		return style.ok(verifyOK)
	case verifyFailed:
		return style.fail(verifyFailed)
	default:
		return style.dim(status)
	}
}

// verifyAfterInstall probes the pack `pack install` just wrote, turning the
// setup block's copy-paste verify hint into a result the operator reads while
// they are still at the terminal — the one moment a wrong credential is cheap
// to fix.
//
// It never changes the install's exit status: the pack IS installed, and a
// failing probe is fixed by correcting the host's environment, not by
// installing again. An installer that retried on this would loop forever.
func verifyAfterInstall(ctx context.Context, w io.Writer, packID string) {
	style := newStyler(w)
	fmt.Fprintf(w, "\n  %s\n", style.bold("Verify"))

	rt, err := boot()
	if err != nil {
		// Installing with --dest and no usable config is legitimate (an image
		// build, a staged tree). Name the verify command instead of failing.
		fmt.Fprintf(w, "    %s\n", style.dim("skipped — no usable runner config; run 'emisar pack verify "+packID+"' on the host"))
		return
	}
	defer rt.journal.Close()

	pack, ok := rt.registry().Pack(packID)
	if !ok {
		fmt.Fprintf(w, "    %s\n", style.dim("skipped — not in this runner's packs dirs; run 'emisar pack verify "+packID+"' after reload"))
		return
	}
	result := verifyPack(ctx, rt, pack, nil)
	fmt.Fprintf(w, "    %s %s  %s\n",
		verifyStatusLabel(style, result.Status), result.ActionID, verifyRowDetail(result))
}
