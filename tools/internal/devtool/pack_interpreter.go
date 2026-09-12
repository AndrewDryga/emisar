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

// scriptRunsCommand reports whether a shell program runs `name`, looking for the
// bare word outside comments and outside single-quoted spans.
//
// Comments are the case this has to get right, because the scripts that invoke
// jq are also the ones that EXPLAIN jq: docker.compose_config carries three
// comments naming it, one of them about a builtin it deliberately avoids. A `#`
// counts as a comment only at the start of a word — the same rule the jq-builtin
// scanner uses — which keeps a `#` inside a value from swallowing the rest of
// the line. A single-quoted span is skipped because that is where a jq FILTER is
// authored, never a command; skipping it also means quoted filter text can never
// be mistaken for an invocation, which is the conservative direction.
func scriptRunsCommand(program, name string) bool {
	const (
		code = iota
		single
		double
	)
	state := code
	comment := false
	for index := 0; index < len(program); index++ {
		character := program[index]
		switch {
		case comment:
			// The quoting state is untouched across a comment, so a jq comment
			// inside a single-quoted filter resumes that same span at newline.
			if character == '\n' {
				comment = false
			}
		case character == '\\':
			// Unquoted or double-quoted, a backslash escapes the next byte;
			// reading a \' as an opening quote inverts everything after it.
			if state != single {
				index++
			}
		case character == '\'' && state == code:
			state = single
		case character == '\'' && state == single:
			state = code
		case character == '"' && state == code:
			state = double
		case character == '"' && state == double:
			state = code
		case character == '#' && state != double && jqStartsWord(program, index):
			comment = true
		case state != single && strings.HasPrefix(program[index:], name):
			end := index + len(name)
			if (index == 0 || !jqIdentifierByte(program[index-1])) &&
				(end == len(program) || !jqIdentifierByte(program[end])) {
				return true
			}
			index = end - 1
		}
	}
	return false
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
