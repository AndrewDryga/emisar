package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// The comment in which one action names its twin in another pack. The rule
// already requires every twin to carry it, so it doubles as the declaration
// this check reads — there is no second list of pairs to keep in sync, and a
// new twin is enforced the moment its comment is written.
var packTwinReferencePattern = regexp.MustCompile(`\bmatch ([a-z0-9][a-z0-9_-]*\.[a-z0-9_]+)\s*—`)

// checkPackTwinActions holds declared twin actions byte-identical apart from
// their `id:` line and the comment naming the twin.
//
// packs-shared-commands-share-one-contract requires two packs exposing the same
// underlying command to share one execution contract AND one operator-facing
// copy, because the pack an operator happens to install must not change what
// the command does to their host, and the catalog text is what an LLM ranks
// before an operator approves. Enforcement was "review plus the paired
// cross-reference comments", and review missed it twice: the 2026-08-28 sweep
// unified five systemctl twins, the 2026-09-11 pass realigned the `pid_*` copy
// that had drifted to a bare path on one side and a sentence on the other, and
// the line wrapping still diverged until 2026-09-12. Three passes to converge
// is the signal that the human eye is the wrong instrument.
//
// A byte-compare is only available because those two lines are the *complete*
// legitimate difference between twins — everything else, down to where the
// description wraps, is meant to be the same text. That makes the check exact
// and judgment-free, which is the bar for spending a gate check on it.
//
// The reference must be mutual. One side alone would let a reword silently
// retire the check; with both sides naming each other, a reword on one side is
// still caught from the other.
func checkPackTwinActions(root string, manifests []string) error {
	actions, err := loadPackTwinActions(root, manifests)
	if err != nil {
		return err
	}
	ids := make([]string, 0, len(actions))
	for id := range actions {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	var failures []string
	compared := make(map[string]bool)
	for _, id := range ids {
		action := actions[id]
		if action.twinID == "" {
			continue
		}
		twin, ok := actions[action.twinID]
		if !ok {
			failures = append(failures, fmt.Sprintf(
				"%s names twin %s, which no pack declares",
				action.path, action.twinID))
			continue
		}
		if twin.id == action.id {
			failures = append(failures, fmt.Sprintf(
				"%s names itself as its twin", action.path))
			continue
		}
		if twin.twinID != action.id {
			// Either the other side never declared the pair, or it points at a
			// third action — both leave one of the two files unguarded.
			named := "no twin"
			if twin.twinID != "" {
				named = twin.twinID
			}
			failures = append(failures, fmt.Sprintf(
				"%s names twin %s, but %s names %s — the reference must be mutual",
				action.path, twin.id, twin.path, named))
			continue
		}
		// Each pair is compared once, from the lexicographically smaller id.
		pair := action.id + " " + twin.id
		if twin.id < action.id {
			pair = twin.id + " " + action.id
		}
		if compared[pair] {
			continue
		}
		compared[pair] = true
		if failure := comparePackTwins(action, twin); failure != "" {
			failures = append(failures, failure)
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"twin actions must be identical apart from their `id:` line and the "+
				"comment naming the twin: %s",
			strings.Join(failures, "; "),
		)
	}
	return nil
}

// A twin action as this check sees it: its text, plus the position of the two
// lines that are allowed to differ.
type packTwinAction struct {
	id      string
	path    string
	lines   []string
	idLine  int
	refLine int
	twinID  string
}

// loadPackTwinActions indexes every manifest-declared action by its id.
//
// Declared actions only, the way checkPackCatalogSummary counts them: a file on
// disk that no manifest lists is not in the catalog, so a twin comment in one
// could otherwise "satisfy" the mutual reference for an action that ships.
func loadPackTwinActions(root string, manifests []string) (map[string]packTwinAction, error) {
	actions := make(map[string]packTwinAction)
	for _, manifest := range manifests {
		input, err := loadPackActionLintInput(filepath.Dir(manifest))
		if err != nil {
			return nil, err
		}
		for _, path := range input.actionPaths {
			action, err := loadPackTwinAction(root, path)
			if err != nil {
				return nil, err
			}
			if previous, ok := actions[action.id]; ok {
				return nil, fmt.Errorf("%s and %s both declare id %s",
					previous.path, action.path, action.id)
			}
			actions[action.id] = action
		}
	}
	return actions, nil
}

func loadPackTwinAction(root, path string) (packTwinAction, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return packTwinAction{}, err
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return packTwinAction{}, err
	}
	action := packTwinAction{
		path:    filepath.ToSlash(relative),
		lines:   strings.Split(string(data), "\n"),
		idLine:  -1,
		refLine: -1,
	}
	for index, line := range action.lines {
		if value, ok := strings.CutPrefix(line, "id:"); ok {
			if action.idLine >= 0 {
				return packTwinAction{}, fmt.Errorf(
					"%s declares id twice, at lines %d and %d",
					action.path, action.idLine+1, index+1)
			}
			action.id = strings.TrimSpace(value)
			action.idLine = index
			continue
		}
		if !strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		match := packTwinReferencePattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		if action.refLine >= 0 {
			return packTwinAction{}, fmt.Errorf(
				"%s names a twin twice, at lines %d and %d",
				action.path, action.refLine+1, index+1)
		}
		action.twinID = match[1]
		action.refLine = index
	}
	if action.id == "" {
		return packTwinAction{}, fmt.Errorf("%s declares no id", action.path)
	}
	return action, nil
}

// comparePackTwins returns the first real difference between two twins, or "".
func comparePackTwins(left, right packTwinAction) string {
	leftLines, leftNumbers := packTwinComparableLines(left)
	rightLines, rightNumbers := packTwinComparableLines(right)
	for index := range min(len(leftLines), len(rightLines)) {
		if leftLines[index] == rightLines[index] {
			continue
		}
		return fmt.Sprintf("%s: twin %s differs at line %d: %q, where %s line %d has %q",
			left.path, right.id, leftNumbers[index], leftLines[index],
			right.path, rightNumbers[index], rightLines[index])
	}
	if len(leftLines) == len(rightLines) {
		return ""
	}
	// The shorter file matched as far as it went, so the difference is whatever
	// the longer one still has to say. In practice this is the trailing-newline
	// case: content added mid-file diverges against a line that does exist.
	longer, shorter := left, right
	lines, numbers := leftLines, leftNumbers
	if len(rightLines) > len(leftLines) {
		longer, shorter = right, left
		lines, numbers = rightLines, rightNumbers
	}
	extra := min(len(leftLines), len(rightLines))
	return fmt.Sprintf("%s: twin %s differs at line %d: %q — %s has no further lines",
		longer.path, shorter.id, numbers[extra], lines[extra], shorter.path)
}

// packTwinComparableLines drops exactly the two lines a twin may differ on, and
// keeps each surviving line's 1-based number in its own file so the error
// points at a line an editor can open.
func packTwinComparableLines(action packTwinAction) ([]string, []int) {
	lines := make([]string, 0, len(action.lines))
	numbers := make([]int, 0, len(action.lines))
	for index, line := range action.lines {
		if index == action.idLine || index == action.refLine {
			continue
		}
		lines = append(lines, line)
		numbers = append(numbers, index+1)
	}
	return lines, numbers
}
