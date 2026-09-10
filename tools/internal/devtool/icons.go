package devtool

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/icons"
)

// The icon masters' normalizers. Snap and cut rewrite files under priv/icons
// and print what they touched; analyze only reads. They enter here for the
// same reason the capture rigs do: a command people and agents both run
// belongs on ./run (shared-human-dev-tooling-is-not-agent-state).
func (a *App) icons(args []string) error {
	if len(args) != 1 {
		return usage("usage: ./run icons <snap|cut|analyze>")
	}
	root := filepath.Join(a.Portal, "apps", "emisar_web", "priv", "icons")
	switch args[0] {
	case "snap":
		snapped, err := icons.Snap(root)
		if err != nil {
			return err
		}
		fmt.Fprintf(a.Out, "snapped: %d\n", snapped)
	case "cut":
		report, err := icons.Cut(root)
		if err != nil {
			return err
		}
		fmt.Fprintf(a.Out, "written: %d  hand-kept: %d  skipped: %d\n", report.Written, report.HandKept, len(report.Skipped))
		if len(report.Skipped) > 0 {
			fmt.Fprintf(a.Out, "  skipped: %s\n", strings.Join(report.Skipped, ", "))
		}
	case "analyze":
		rows, err := icons.Analyze(root)
		if err != nil {
			return err
		}
		icons.PrintAudit(a.Out, rows)
	default:
		return usage("usage: ./run icons <snap|cut|analyze>")
	}
	return nil
}
