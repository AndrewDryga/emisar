package devtool

import (
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
	var failures []string
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
		if used := jqOptionalBuiltinsUsed(source); len(used) > 0 {
			failures = append(failures,
				fmt.Sprintf("%s (%s)", action.ID, strings.Join(used, ", ")))
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"jq filters must use only builtins every jq build has; the regex family and split/2 "+
				"need Oniguruma, which jq's own --with-oniguruma=no build omits: %s",
			strings.Join(failures, ", "),
		)
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

// jqOptionalBuiltinsUsed returns the optional builtins a shell program's jq
// filters call, deduplicated and sorted. Comments are skipped in both
// languages — a shell comment explaining why gsub is avoided, and a jq comment
// inside the single-quoted program saying the same — while a `#` inside a
// string stays part of the string, which is what keeps "x5t#S256" from
// swallowing the rest of the filter.
func jqOptionalBuiltinsUsed(program string) []string {
	used := make(map[string]bool)
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

	names := make([]string, 0, len(used))
	for name := range used {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
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
