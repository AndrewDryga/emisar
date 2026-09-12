package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The one sentence in packs/README.md that states how big the catalog is. The
// whitespace classes let the paragraph rewrap without escaping the check.
var packCatalogSummaryPattern = regexp.MustCompile(`\*\*([0-9,]+)\s+packs\s+and\s+([0-9,]+)\s+actions\*\*`)

// checkPackCatalogSummary keeps the README's catalog totals equal to what
// packs/ actually contains.
//
// packs/AGENTS.md already tells contributors to verify those totals by hand and
// even names the two commands to do it with. That instruction is exactly what
// failed: bb09b156c removed four actions, the README kept saying 1,788, and
// nothing between authoring and publication disagreed — the numbers are prose,
// so pack validation, the catalog byte-compare, and the portal tests all stay
// green while the public number rots. It is the first line of the pack
// catalog's public page, so the drift is customer-visible.
//
// Counting packs and manifest action entries is exact and carries no judgment,
// which is the bar for spending a gate check on a documentation string.
//
// The count comes from each manifest's declared actions: list — the same list
// packctl feeds the catalog — and never from a walk of actions/*.yaml. A file
// on disk that no manifest lists is not in the catalog, and counting it could
// make a stale README look correct.
func checkPackCatalogSummary(root string, manifests []string) error {
	actions := 0
	for _, manifest := range manifests {
		input, err := loadPackActionLintInput(filepath.Dir(manifest))
		if err != nil {
			return err
		}
		actions += len(input.actionPaths)
	}
	packs := len(manifests)

	readme := filepath.Join(root, "packs", "README.md")
	data, err := os.ReadFile(readme)
	if err != nil {
		return err
	}
	matches := packCatalogSummaryPattern.FindAllSubmatch(data, -1)
	if len(matches) != 1 {
		// Zero means someone reworded the sentence out from under the check;
		// two means a second copy that the next pack change will forget.
		return fmt.Errorf(
			"packs/README.md must state the catalog totals exactly once as "+
				"**%s packs and %s actions**; found %d such statements",
			formatCount(packs), formatCount(actions), len(matches))
	}
	statedPacks, err := parseCount(string(matches[0][1]))
	if err != nil {
		return fmt.Errorf("packs/README.md: pack total: %w", err)
	}
	statedActions, err := parseCount(string(matches[0][2]))
	if err != nil {
		return fmt.Errorf("packs/README.md: action total: %w", err)
	}
	if statedPacks != packs || statedActions != actions {
		return fmt.Errorf(
			"packs/README.md says %s packs and %s actions; packs/ contains %s packs "+
				"and %s actions — update the summary to **%s packs and %s actions**",
			formatCount(statedPacks), formatCount(statedActions),
			formatCount(packs), formatCount(actions),
			formatCount(packs), formatCount(actions))
	}
	return nil
}

// parseCount reads the README's own spelling, which groups thousands.
func parseCount(value string) (int, error) {
	n, err := strconv.Atoi(strings.ReplaceAll(value, ",", ""))
	if err != nil {
		return 0, fmt.Errorf("%q is not a number", value)
	}
	return n, nil
}

// formatCount writes a total the way the README does, so the fix the error
// suggests can be pasted in as-is.
func formatCount(n int) string {
	digits := strconv.Itoa(n)
	var out strings.Builder
	for i, digit := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			out.WriteByte(',')
		}
		out.WriteRune(digit)
	}
	return out.String()
}
