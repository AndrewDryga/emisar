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
