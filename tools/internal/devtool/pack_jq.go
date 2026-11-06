package devtool

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// jq links its regex family only when it was built against Oniguruma, and jq's
// own ./configure --with-oniguruma=no is a supported build that minimal images
// and appliance hosts use. A filter that reaches one of these builtins there
// raises "jq was compiled without ONIGURUMA regex library" and exits 5 — after
// the command has already run — so the action fails on that host and nowhere
// else, at the same version and the same trusted hash, and
// requires.binaries: [jq] cannot express "a jq with regex". Spell the job with
// core jq instead: see
// .agent/kb/rules/packs-jq-filters-stay-on-core-jq.md.
//
// split/1 is core; only split/2 is part of the optional family, so it is
// recognized by its argument count rather than by name.
var jqOptionalBuiltins = map[string]bool{
	"capture": true,
	"gsub":    true,
	"match":   true,
	"scan":    true,
	"splits":  true,
	"sub":     true,
	"test":    true,
}

// jq 1.7 accepts a keyword as a variable name; jq 1.6, which Debian 12, Ubuntu
// 22.04 and RHEL 9 ship, rejects one at compile time ("syntax error, unexpected
// label, expecting IDENT"), so the action fails on those hosts while a jq 1.7+
// workstation never notices. This is the lexer's keyword set, each rejected
// by jq 1.6 as a binding, a destructured name, a def parameter and a
// reference; `not` is a builtin and jq 1.6 accepts $not. $__loc__ is a valid
// reference in every jq, so only binding it counts.
var jqKeywords = map[string]bool{
	"__loc__": true,
	"and":     true,
	"as":      true,
	"break":   true,
	"catch":   true,
	"def":     true,
	"elif":    true,
	"else":    true,
	"end":     true,
	"foreach": true,
	"if":      true,
	"import":  true,
	"include": true,
	"label":   true,
	"module":  true,
	"or":      true,
	"reduce":  true,
	"then":    true,
	"try":     true,
}

// Programs with their own match/sub/gsub, unaffected by how jq was built. One
// is routinely quoted beside a jq filter in the same pipeline, so what is
// skipped is the span from the command to the end of its pipeline segment
// rather than the whole shell program.
var jqForeignProgramCommands = map[string]bool{
	"awk":  true,
	"gawk": true,
	"mawk": true,
	"perl": true,
	"sed":  true,
}

func validatePackJQFilters(input packActionLintInput) error {
	var optional, keywords []string
	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packPipelineAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		source, ok, err := actionShellSource(input.packDir, action)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		// Other embedded languages have their own match/scan/sub functions.
		// With no jq spelling anywhere, this source cannot be a static jq
		// invocation; do not interpret a Python heredoc as a jq filter.
		if !strings.Contains(source, "jq") {
			continue
		}
		builtins, variables := jqFilterFindings(source)
		if len(builtins) > 0 {
			optional = append(optional,
				fmt.Sprintf("%s (%s)", action.ID, strings.Join(builtins, ", ")))
		}
		if len(variables) > 0 {
			keywords = append(keywords,
				fmt.Sprintf("%s (%s)", action.ID, strings.Join(variables, ", ")))
		}
	}
	var problems []string
	if len(optional) > 0 {
		problems = append(problems,
			"jq filters must use only builtins every jq build has; the regex family and split/2 "+
				"need Oniguruma, which jq's own --with-oniguruma=no build omits: "+
				strings.Join(optional, ", "))
	}
	if len(keywords) > 0 {
		problems = append(problems,
			"jq filters must compile on jq 1.6, which rejects a jq keyword as a variable name: "+
				strings.Join(keywords, ", "))
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// Scanner states. A jq filter is authored inside a shell-quoted span, so the
// builtins are looked for there — never in bare shell, where `test -r` is the
// shell's own builtin and a function may legitimately be named sub().
const (
	jqShellCode = iota
	jqShellSingle
	jqShellDouble
	jqStringLiteral
	jqComment
)

// jqFilterFindings returns the optional builtins a shell program's jq filters
// call and the keyword variable names they use, each deduplicated and sorted.
// Comments are skipped in both languages — a shell comment explaining why gsub
// is avoided, and a jq comment inside the single-quoted program saying the
// same — while a `#` inside a string stays part of the string, which is what
// keeps "x5t#S256" from swallowing the rest of the filter.
//
// A keyword variable counts anywhere in a single-quoted span, where the jq
// program is authored, but in bare text (a heredoc filter) only right after
// `as`: there `$end` is just as likely the shell's own variable.
func jqFilterFindings(program string) (builtins, keywords []string) {
	used := make(map[string]bool)
	variables := make(map[string]bool)
	state, resume := jqShellCode, jqShellCode
	foreign := false
	for index := 0; index < len(program); index++ {
		character := program[index]
		switch state {
		case jqComment:
			if character == '\n' {
				state = resume
				if state == jqShellCode {
					foreign = false
				}
			}
		case jqStringLiteral:
			switch character {
			case '\\':
				index++
			case '"':
				state = jqShellSingle
			}
		case jqShellDouble:
			switch {
			case character == '\\':
				index++
			case character == '"':
				state = jqShellCode
			default:
				index = jqRecordCall(program, index, foreign, used)
			}
		case jqShellSingle:
			switch {
			case character == '\'':
				state = jqShellCode
			case character == '"':
				state = jqStringLiteral
			case character == '#' && jqStartsWord(program, index):
				state, resume = jqComment, jqShellSingle
			case character == '$':
				index = jqRecordKeywordVariable(program, index, foreign, false, variables)
			default:
				index = jqRecordCall(program, index, foreign, used)
			}
		default:
			switch {
			// Unquoted, a backslash escapes the next character. Reading the
			// \' in a bash pattern as an opening quote inverts the quoting of
			// everything after it, and every filter below goes unseen.
			case character == '\\':
				index++
			case character == '\'':
				state = jqShellSingle
			case character == '"':
				state = jqShellDouble
			case character == '#' && jqStartsWord(program, index):
				state, resume = jqComment, jqShellCode
			case jqEndsPipelineSegment(character):
				foreign = false
			case character == '$':
				index = jqRecordKeywordVariable(program, index, foreign, true, variables)
			default:
				// A jq program may arrive through a heredoc instead of a
				// quoted argv span. Scan direct call spellings in bare text too;
				// ordinary shell commands such as `test -r` have no immediate
				// parenthesis and remain out of scope.
				if next := jqRecordCall(program, index, foreign, used); next != index {
					index = next
					continue
				}
				if word, next := jqShellWordAt(program, index); word != "" {
					if jqForeignProgramCommands[jqCommandName(word)] {
						foreign = true
					}
					index = next - 1
				}
			}
		}
	}

	return jqSortedNames(used), jqSortedNames(variables)
}

func jqSortedNames(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// jqRecordKeywordVariable records the variable spelled at index, the `$` of
// `$name`, when name is a jq keyword, and returns the last index it consumed.
// bindingOnly limits it to `as $name`, the one spelling bare shell text never
// means as its own variable.
func jqRecordKeywordVariable(program string, index int, foreign, bindingOnly bool, variables map[string]bool) int {
	start := index + 1
	if foreign || start >= len(program) || !jqIdentifierStart(program[start]) {
		return index
	}
	end := start
	for end < len(program) && jqIdentifierByte(program[end]) {
		end++
	}
	name := program[start:end]
	bound := jqFollowsAs(program, index)
	if jqKeywords[name] && (bound || !bindingOnly && name != "__loc__") {
		variables["$"+name] = true
	}
	return end - 1
}

// jqFollowsAs reports whether the `$` at index directly follows the keyword
// `as`, which is how jq binds a variable.
func jqFollowsAs(program string, index int) bool {
	end := index
	for end > 0 && (program[end-1] == ' ' || program[end-1] == '\t' || program[end-1] == '\n') {
		end--
	}
	return end >= 2 && program[end-2:end] == "as" &&
		(end == 2 || !jqIdentifierByte(program[end-3]))
}

// jqRecordCall records the builtin called at index, if any, and returns the
// last index it consumed.
func jqRecordCall(program string, index int, foreign bool, used map[string]bool) int {
	if !jqIdentifierStart(program[index]) ||
		index > 0 && jqIdentifierByte(program[index-1]) {
		return index
	}
	end := index
	for end < len(program) && jqIdentifierByte(program[end]) {
		end++
	}
	open := end
	if open+1 < len(program) && program[open] == '\\' && program[open+1] == '(' {
		open++
	}
	if open >= len(program) || program[open] != '(' || foreign {
		return index
	}
	name := program[index:end]
	if jqOptionalBuiltins[name] {
		used[name] = true
	}
	if name == "split" && jqCallTakesTwoArguments(program, open) {
		used["split/2"] = true
	}
	return end - 1
}

// jqCallTakesTwoArguments reports whether the call whose ( is at open has a
// top-level `;`, which is how split/2 — the optional, regex-taking spelling —
// is told apart from core split/1.
func jqCallTakesTwoArguments(program string, open int) bool {
	depth := 1
	for index := open + 1; index < len(program); index++ {
		switch program[index] {
		case '\\':
			index++
		case '"':
			for index++; index < len(program); index++ {
				if program[index] == '\\' {
					index++
					continue
				}
				if program[index] == '"' {
					break
				}
			}
		case '\'':
			// The shell span ended before the call closed, so there is no
			// argument list left to read.
			return false
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return false
			}
		case ';':
			if depth == 1 {
				return true
			}
		}
	}
	return false
}

// jqShellWordAt returns the shell word starting at index and the offset just
// past it, or "" when index does not begin one.
func jqShellWordAt(program string, index int) (string, int) {
	if jqShellDelimiter(program[index]) || program[index] == '\'' || program[index] == '"' {
		return "", index
	}
	if index > 0 && !jqShellDelimiter(program[index-1]) {
		return "", index
	}
	end := index
	for end < len(program) && !jqShellDelimiter(program[end]) &&
		program[end] != '\'' && program[end] != '"' {
		end++
	}
	return program[index:end], end
}

// jqCommandName reduces a command word to what it invokes, so /usr/bin/awk is
// recognized as awk.
func jqCommandName(word string) string {
	if index := strings.LastIndexByte(word, '/'); index >= 0 {
		return word[index+1:]
	}
	return word
}

func jqEndsPipelineSegment(character byte) bool {
	return character == '\n' || character == ';' || character == '|' || character == '&'
}

func jqShellDelimiter(character byte) bool {
	switch character {
	case ' ', '\t', '\n', '\r', ';', '|', '&', '(', ')', '<', '>':
		return true
	}
	return false
}

// jqStartsWord reports whether index begins a word, which is where both shells
// and jq start a comment — and where `#` inside "x5t#S256" never is.
func jqStartsWord(program string, index int) bool {
	return index == 0 || jqShellDelimiter(program[index-1])
}

func jqIdentifierStart(character byte) bool {
	return character >= 'a' && character <= 'z' ||
		character >= 'A' && character <= 'Z' || character == '_'
}

func jqIdentifierByte(character byte) bool {
	return jqIdentifierStart(character) || character >= '0' && character <= '9'
}
