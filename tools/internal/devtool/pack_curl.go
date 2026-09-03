package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.yaml.in/yaml/v3"
)

// validatePackCurlURLSafety enforces the globbing/protocol half of
// packs-response-supplied-urls-disable-curl-globbing. Its three sibling packs
// rules each graduated to a lint; this one said "convention only, for now" and
// the convention had drifted — 94 call sites across nine packs passed neither
// flag while the packs building the same URL shape passed both.
//
// Both flags are required of every curl invocation rather than only the ones
// whose URL is visibly response-supplied. Deciding "is this URL attacker
// influenced" from the YAML means reasoning about env defaults, arg
// interpolation, and redirect targets — the exact judgment that produced the
// drift. Requiring them everywhere costs a fixed-URL call nothing.
func validatePackCurlURLSafety(input packActionLintInput) error {
	var failures []string
	note := func(id, reason string) { failures = append(failures, id+" ("+reason+")") }

	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packHTTPAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}

		sources := []string{}
		command := action.Execution.Command
		if command.Binary == "curl" {
			sources = append(sources, "curl "+strings.Join(command.Argv, " "))
		} else {
			sources = append(sources, strings.Join(command.Argv, "\n"))
		}
		if action.Execution.Script.Path != "" {
			script, err := os.ReadFile(filepath.Join(input.packDir, filepath.Clean(action.Execution.Script.Path)))
			if err != nil {
				return err
			}
			sources = append(sources, string(script))
		}

		for _, source := range sources {
			for _, invocation := range curlInvocations(source) {
				// A call that takes its flags indirectly — curl "$@" after a
				// `set --`, or "${curl_args[@]}" — cannot be judged from the
				// invocation alone, so judge the script that assembles them.
				if curlArgsAreIndirect(invocation) {
					invocation = strings.Fields(source)
				}
				if reason := curlURLSafetyGap(invocation); reason != "" {
					note(action.ID, reason)
				}
			}
		}
	}

	if len(failures) > 0 {
		return fmt.Errorf(
			"curl invocations must disable globbing and confine the protocol: %s",
			strings.Join(failures, ", "),
		)
	}
	return nil
}

// curlURLSafetyGap names the missing guard, or "" when the invocation is safe.
// A URL that reaches curl with globbing on expands {a,b} into one transfer per
// alternative; without --proto an operator-set base URL can select file:// or
// another scheme entirely. A redirect-following call needs --proto-redir too,
// because the redirect target is chosen by the response, not the action.
func curlURLSafetyGap(argv []string) string {
	var globoff, proto, protoRedir, follows bool
	for _, arg := range argv {
		switch {
		case arg == "--globoff":
			globoff = true
		case arg == "--proto":
			proto = true
		case arg == "--proto-redir":
			protoRedir = true
		case arg == "--location":
			follows = true
		case strings.HasPrefix(arg, "--"):
			// A long flag we do not model; nothing to infer from it.
		case strings.HasPrefix(arg, "-") && len(arg) > 1:
			// Bundled short flags: -g is --globoff, -L is --location.
			for _, flag := range arg[1:] {
				switch flag {
				case 'g':
					globoff = true
				case 'L':
					follows = true
				}
			}
		}
	}
	switch {
	case !globoff:
		return "no --globoff"
	case !proto:
		return "no --proto"
	case follows && !protoRedir:
		return "follows redirects without --proto-redir"
	}
	return ""
}

// joinShellContinuations folds `\`-continued lines into one, so a flag list
// wrapped for readability is still one invocation to the scanner.
func joinShellContinuations(source string) string {
	lines := strings.Split(source, "\n")
	var out []string
	var pending string
	for _, line := range lines {
		trimmed := strings.TrimRight(line, " \t")
		if strings.HasSuffix(trimmed, "\\") {
			pending += strings.TrimSuffix(trimmed, "\\") + " "
			continue
		}
		out = append(out, pending+line)
		pending = ""
	}
	if pending != "" {
		out = append(out, pending)
	}
	return strings.Join(out, "\n")
}

// curlArgsAreIndirect reports whether the flags come from somewhere else.
func curlArgsAreIndirect(argv []string) bool {
	for _, arg := range argv {
		if strings.Contains(arg, "$@") || strings.Contains(arg, "[@]") {
			return true
		}
	}
	return false
}
