package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// A script action naming a non-POSIX interpreter needs that interpreter
// DECLARED, or the pack advertises a capability the host may not have.
//
// `/bin/sh` is on every host we support, so it needs no declaration. `bash` is
// not: a Debian slim image, an Alpine host, or a hardened build may carry only
// busybox ash. Undeclared, the pack installs cleanly, the action appears in the
// catalog, and it fails at dispatch — after an operator approved it. Declared,
// `requires.binaries` is the thing readiness checks and `pack suggest` already
// look at.
//
// Eight packs and 75 actions sat in this gap because the loader validates
// `execution.command.binary` and never looks at `execution.script.interpreter`.
// Fixing them was mechanical; this keeps the next one from reopening it.
var packDeclaredInterpreters = map[string]string{
	"/bin/bash":         "bash",
	"/usr/bin/bash":     "bash",
	"bash":              "bash",
	"/usr/bin/env bash": "bash",
}

// The same gap on the exec side: an action's `execution.command.binary` is a
// host dependency too, and `emisar pack info` LookPaths exactly what
// `requires.binaries` names — so an undeclared `smartctl` or `chronyc` gives
// the operator no pre-flight signal and fails at dispatch instead. Coreutils
// and the POSIX toolbox are on every host we support and would be noise;
// anything outside that list is a real dependency. A binary declared but
// never used as `execution.command.binary` is NOT a finding: packs invoke
// curl, jq, gcloud and aws from inside their own scripts.
var packUbiquitousBinaries = map[string]bool{}

func init() {
	for _, binary := range strings.Fields(`sh bash cat ls cp mv rm mkdir rmdir ln touch chmod chown
chgrp du df stat head tail sort uniq wc cut tr sed awk grep egrep fgrep find xargs printf echo date
sleep true false env test id whoami hostname uname ps kill sync tee basename dirname readlink
realpath timeout base64 od tar gzip gunzip zcat nl comm join paste split expr seq getent locale ip`) {
		packUbiquitousBinaries[binary] = true
	}
}

// The third face of the same gap: what a packaged script or an inline `-c`
// program INVOKES is a host dependency too, and nothing else looks at it. The
// loader validates `execution.command.binary`, the check above covers
// `execution.script.interpreter`, and neither reads the script text — so
// `docker` shipped `docker.compose_config` and `docker.compose_images`, which
// build their whole structured result with jq, declaring only `docker` and
// `bash`. On a host without jq the pack installed cleanly, both actions showed
// up in the catalog, and they failed at dispatch, after an operator or an LLM
// had already selected them.
//
// Only jq is listed, and deliberately: 28 packs run it from their own script
// text and 27 already declared it, so the rule is the catalog's own convention
// rather than a guess about which helpers matter. Add a name here with the same
// kind of evidence — a helper the catalog already treats as declarable, whose
// bare name in shell text is unambiguous enough to attribute. A coreutil from
// packUbiquitousBinaries does not qualify: it is on every host and would be
// noise in hundreds of actions.
var packScriptHelperBinaries = []string{"jq"}

func validatePackScriptHelperBinaries(input packActionLintInput) error {
	missing := make(map[string][]string)
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
		for _, binary := range packScriptHelperBinaries {
			if input.requiredBinaries[binary] || !scriptRunsCommand(source, binary) {
				continue
			}
			missing[binary] = append(missing[binary], action.ID)
		}
	}
	if len(missing) == 0 {
		return nil
	}

	binaries := make([]string, 0, len(missing))
	for binary := range missing {
		binaries = append(binaries, binary)
	}
	sort.Strings(binaries)

	reports := make([]string, 0, len(binaries))
	for _, binary := range binaries {
		reports = append(reports, fmt.Sprintf(
			"%s (run by %s)", binary, strings.Join(missing[binary], ", ")))
	}
	return fmt.Errorf(
		"%s: helper binary run from action shell source not declared in requires.binaries: %s",
		filepath.Base(input.packDir), strings.Join(reports, "; "))
}

// Words that precede another command instead of taking their own arguments, so
// the word after one is still a command position: `if jq -e . f`, `! jq …`,
// `{ jq …; }`. Everything else consumes the rest of its simple command as
// arguments, which is what tells `jq -r .` apart from `printf '%s\n' jq`.
var shellCommandPrefixWords = map[string]bool{
	"!": true, "{": true, "}": true, "if": true, "then": true, "elif": true,
	"else": true, "do": true, "while": true, "until": true, "time": true,
}

// shellScanFrame is one command scope: the whole program, or the inside of a
// `$( … )` / backtick substitution. Each scope tracks its own word and its own
// command position, because `detail="$(jq -r . "$f")"` runs jq in a fresh scope
// while the word around it keeps reading as an assignment.
type shellScanFrame struct {
	closer    byte // ')' inside $( … ), '`' inside a backtick span, 0 for the program
	depth     int  // nested ( … ) within this scope
	double    bool // inside a double-quoted span
	command   bool // the next word that ends here starts a command
	inWord    bool
	wordStart int
}

// scriptRunsCommand reports whether a shell program RUNS `name` — the word in a
// COMMAND position, not every mention of it. A word-boundary match anywhere
// outside single quotes attributes a dependency to `printf '%s\n' "jq
// unavailable"`, which invokes only printf; the diagnostic an action prints when
// a helper is missing is the one place the helper's name is guaranteed to appear
// without being run.
//
// The supported static forms, and they are the whole contract:
//
//   - A command position is the start of the program and the word after `\n`,
//     `;`, `|`, `&`, `&&`, `||`, `(`, `)`, a `$( … )` or backtick substitution's
//     opening, one of shellCommandPrefixWords, or a `NAME=value` assignment
//     prefix. Every later word in that simple command is an argument.
//   - A single-quoted span is literal text — where a jq FILTER is authored,
//     never a command — and is skipped whole.
//   - A double-quoted span is NOT skipped: a `$( … )` or backtick inside one
//     opens a real command scope, which is how `"$(jq -r .)"` keeps its
//     attribution. The quoted text itself is part of the surrounding word, so
//     `"jq unavailable"` stays one argument.
//   - `#` opens a comment only at the start of a word and only outside double
//     quotes. Comments matter because the scripts that invoke jq are also the
//     ones that EXPLAIN jq: docker.compose_config carries three such comments.
//   - A command word may be quoted (`'jq' .`) or a path (`/usr/bin/jq .`).
//
// What it deliberately does not model, because this is a token scanner and not a
// shell: a command supplied to another command (`xargs jq`, `sh -c 'jq …'`), a
// command named by expansion (`${JQ:-jq}`), a heredoc body, a `case` pattern,
// and a redirection target in front of the command word (`> jq cmd`). The first
// two under-report and the rest over-report; no shipped pack uses any of them.
func scriptRunsCommand(program, name string) bool {
	frames := []shellScanFrame{{command: true}}
	comment := false
	for index := 0; index < len(program); index++ {
		frame := &frames[len(frames)-1]
		character := program[index]
		switch {
		case comment:
			if character == '\n' {
				comment = false
				frame.command = true
			}
		case character == '\\' && index+1 < len(program) && program[index+1] == '\n':
			// A line continuation joins the two halves of one command, so it
			// must not end the word or reopen a command position.
			index++
		case character == '\\':
			// Unquoted or double-quoted, a backslash escapes the next byte;
			// reading a \' as an opening quote inverts everything after it.
			frame.beginWord(index)
			index++
		case frame.double:
			switch {
			case character == '"':
				frame.double = false
			case character == '$' && index+1 < len(program) && program[index+1] == '(':
				index++
				frames = append(frames, shellScanFrame{closer: ')', command: true})
			case character == '`':
				frames = append(frames, shellScanFrame{closer: '`', command: true})
			}
		case character == '"':
			frame.beginWord(index)
			frame.double = true
		case character == '\'':
			frame.beginWord(index)
			if end := strings.IndexByte(program[index+1:], '\''); end >= 0 {
				index += end + 1
			} else {
				index = len(program)
			}
		case character == '#' && !frame.inWord:
			comment = true
		case character == '$' && index+1 < len(program) && program[index+1] == '(':
			frame.beginWord(index)
			index++
			frames = append(frames, shellScanFrame{closer: ')', command: true})
		case character == '`':
			frame.beginWord(index)
			frames = append(frames, shellScanFrame{closer: '`', command: true})
		case frame.closer != 0 && character == frame.closer && frame.depth == 0:
			if frame.finishWord(program, name, index) {
				return true
			}
			frames = frames[:len(frames)-1]
		case jqShellDelimiter(character):
			if frame.finishWord(program, name, index) {
				return true
			}
			switch character {
			case '\n', ';', '|', '&':
				frame.command = true
			case '(':
				frame.depth++
				frame.command = true
			case ')':
				if frame.depth > 0 {
					frame.depth--
				}
				frame.command = true
			}
			// A space, a tab, and a redirection operator leave the position
			// alone: `cmd > jq` writes a file, it does not run one.
		default:
			frame.beginWord(index)
		}
	}
	// An unterminated substitution still ran what it held, so every open scope's
	// trailing word counts.
	for index := len(frames) - 1; index >= 0; index-- {
		if frames[index].finishWord(program, name, len(program)) {
			return true
		}
	}
	return false
}

func (frame *shellScanFrame) beginWord(index int) {
	if !frame.inWord {
		frame.inWord, frame.wordStart = true, index
	}
}

// finishWord closes the word ending at end and reports whether it was a command
// position holding `name`.
func (frame *shellScanFrame) finishWord(program, name string, end int) bool {
	if !frame.inWord {
		return false
	}
	word := program[frame.wordStart:end]
	frame.inWord = false
	if !frame.command {
		return false
	}
	if shellCommandPrefixWords[word] || shellAssignmentPrefix(word) {
		return false
	}
	frame.command = false
	return jqCommandName(shellUnquoteWord(word)) == name
}

// shellAssignmentPrefix reports whether a word at a command position is a
// `NAME=value` prefix, which keeps the command position open for the word after
// it — and is also how `jq_filter=.Names` stays out of this check.
func shellAssignmentPrefix(word string) bool {
	assign := strings.IndexByte(word, '=')
	if assign <= 0 || !jqIdentifierStart(word[0]) {
		return false
	}
	for index := 1; index < assign; index++ {
		if !jqIdentifierByte(word[index]) {
			return false
		}
	}
	return true
}

// shellUnquoteWord drops the quote characters a command word may carry, so
// `'jq'` and `"jq"` read as the command they run. It is not a general unquote:
// the result is only ever compared against a bare helper name.
func shellUnquoteWord(word string) string {
	if !strings.ContainsAny(word, `'"`) {
		return word
	}
	return strings.NewReplacer("'", "", `"`, "").Replace(word)
}

func validatePackInterpreterBinaries(input packActionLintInput) error {
	missing := make(map[string][]string)
	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packScriptAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if command := action.Execution.Command.Binary; command != "" &&
			!strings.HasPrefix(command, "/") &&
			!packUbiquitousBinaries[command] &&
			!input.requiredBinaries[command] {
			missing[command] = append(missing[command], filepath.Base(path))
		}
		binary, needed := packDeclaredInterpreters[action.Execution.Script.Interpreter]
		if !needed || input.requiredBinaries[binary] {
			continue
		}
		missing[binary] = append(missing[binary], filepath.Base(path))
	}
	if len(missing) == 0 {
		return nil
	}

	binaries := make([]string, 0, len(missing))
	for binary := range missing {
		binaries = append(binaries, binary)
	}
	sort.Strings(binaries)

	reports := make([]string, 0, len(binaries))
	for _, binary := range binaries {
		reports = append(reports, fmt.Sprintf(
			"%s (used by %s)", binary, strings.Join(missing[binary], ", ")))
	}
	return fmt.Errorf(
		"%s: script interpreter not declared in requires.binaries: %s",
		filepath.Base(input.packDir), strings.Join(reports, "; "))
}
