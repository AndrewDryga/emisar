package main

import (
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
)

type cliDiagnosticKind int

const (
	cliDiagnosticError cliDiagnosticKind = iota
	cliDiagnosticWarning
)

type cliDiagnostic struct {
	Kind    cliDiagnosticKind
	Summary string
	Details []string
	Usage   []string
	Next    []string
}

func writeCLIDiagnostic(writer io.Writer, diagnostic cliDiagnostic) {
	_, _ = io.WriteString(writer, formatCLIDiagnostic(
		diagnostic,
		cliDiagnosticColorEnabled(writer),
	))
}

func formatCLIDiagnostic(diagnostic cliDiagnostic, color bool) string {
	label := "Error"
	colorCode := "31"
	if diagnostic.Kind == cliDiagnosticWarning {
		label = "Warning"
		colorCode = "33"
	}
	if color {
		label = "\x1b[1;" + colorCode + "m" + label + "\x1b[0m"
	}

	var output strings.Builder
	fmt.Fprintf(&output, "%s: %s\n", label, cleanDiagnosticText(diagnostic.Summary))
	wroteDetail := false
	for _, detail := range diagnostic.Details {
		detail = cleanDiagnosticText(detail)
		if detail == "" {
			continue
		}
		if !wroteDetail {
			output.WriteByte('\n')
		}
		output.WriteString(detail)
		output.WriteByte('\n')
		wroteDetail = true
	}
	if len(diagnostic.Usage) > 0 {
		output.WriteString("\nUsage:\n")
		for _, usage := range diagnostic.Usage {
			usage = cleanDiagnosticText(usage)
			if usage == "" {
				continue
			}
			output.WriteString("  ")
			output.WriteString(usage)
			output.WriteByte('\n')
		}
	}
	if len(diagnostic.Next) > 0 {
		output.WriteString("\nNext:\n")
		for _, next := range diagnostic.Next {
			next = cleanDiagnosticText(next)
			if next == "" {
				continue
			}
			output.WriteString("  - ")
			output.WriteString(next)
			output.WriteByte('\n')
		}
	}
	return output.String()
}

func cleanDiagnosticText(value string) string {
	return terminalSafeLine(value)
}

func displayCLIOption(value string) string {
	if name, _, found := strings.Cut(value, "="); found && strings.HasPrefix(name, "--") {
		return name + "=<value>"
	}
	return cleanDiagnosticText(value)
}

func diagnosticSentence(value string) string {
	value = cleanDiagnosticText(value)
	if value != "" && value[0] >= 'a' && value[0] <= 'z' {
		value = string(value[0]-'a'+'A') + value[1:]
	}
	return value
}

func cliDiagnosticColorEnabled(writer io.Writer) bool {
	_, noColor := os.LookupEnv("NO_COLOR")
	return cliDiagnosticColorAllowed(
		writerIsTerminal(writer),
		runtime.GOOS,
		os.Getenv("TERM"),
		noColor,
		os.Getenv("CLICOLOR"),
	)
}

func cliDiagnosticColorAllowed(terminal bool, goos, term string, noColor bool, cliColor string) bool {
	if goos == "windows" || !terminal || term == "dumb" || noColor {
		return false
	}
	return cliColor != "0"
}

func cliStyledText(writer io.Writer, styleCode, value string) string {
	return formatCLIStyledText(styleCode, value, cliDiagnosticColorEnabled(writer))
}

func formatCLIStyledText(styleCode, value string, color bool) string {
	if !color {
		return value
	}
	return "\x1b[" + styleCode + "m" + value + "\x1b[0m"
}

func cliCommandError(stderr io.Writer, summary string, details []string, next ...string) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: summary,
		Details: details,
		Next:    next,
	})
	return 1
}

func cliInputError(stderr io.Writer, summary string, next ...string) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: summary,
		Next:    next,
	})
	return 2
}

func cliUsageBlock(stderr io.Writer, summary, usage string) int {
	usage = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(usage), "usage:"))
	lines := strings.Split(usage, "\n")
	for index, line := range lines {
		lines[index] = strings.TrimSpace(line)
	}
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: summary,
		Usage:   lines,
	})
	return 2
}

func cliUsageError(stderr io.Writer, message string) int {
	message = cleanDiagnosticText(message)
	if problem, usage, found := strings.Cut(message, "; usage: "); found {
		return cliUsageBlock(stderr, diagnosticSentence(problem), usage)
	}
	if usage, found := strings.CutPrefix(message, "usage: "); found {
		return cliUsageBlock(stderr, "Invalid command", usage)
	}
	next := []string{"Run `emisar-mcp --help` to see available commands."}
	switch {
	case strings.Contains(message, "JSON") || strings.Contains(message, "JSON object"):
		next = []string{
			"Pass one JSON object, or use `-` to read the object from stdin.",
			"Run `emisar-mcp help <tool>` to see that tool's arguments.",
		}
	case strings.Contains(message, "account"):
		next = []string{"Run `emisar-mcp accounts list --json` to see valid slugs and account IDs."}
	}
	return cliInputError(stderr, diagnosticSentence(message), next...)
}

func cliFailure(stderr io.Writer, action string, err error) int {
	next := []string(nil)
	switch {
	case strings.Contains(action, "list tools"):
		next = []string{"Check the server URL and your network connection, then try again."}
	case strings.Contains(action, "decode") || strings.Contains(action, "render"):
		next = []string{"Upgrade the Emisar server and CLI together, then try again."}
	case strings.Contains(action, "write") || strings.Contains(action, "print"):
		next = []string{"Check that the command's output destination is still available."}
	}
	return cliCommandError(
		stderr,
		"Could not "+cleanDiagnosticText(action),
		[]string{err.Error()},
		next...,
	)
}

func cliConfigurationFailure(stderr io.Writer, err error, account string) int {
	message := strings.TrimSuffix(err.Error(), " (try --help)")
	switch {
	case strings.Contains(message, "no stored CLI credential"):
		summary := "No stored account is available"
		if account != "" {
			summary = fmt.Sprintf("Account %q is not stored", account)
		}
		return cliCommandError(
			stderr,
			summary,
			nil,
			"Run `emisar-mcp auth` to authenticate an account.",
			"Run `emisar-mcp accounts list` to see stored accounts.",
		)
	case strings.Contains(message, "must both be set") ||
		strings.Contains(message, "EMISAR_URL must be set") ||
		strings.Contains(message, "EMISAR_API_KEY must be set"):
		return cliCommandError(
			stderr,
			"Authentication environment is incomplete",
			[]string{message},
			"Set both EMISAR_URL and EMISAR_API_KEY, or unset both to use a stored account.",
		)
	case strings.Contains(message, "cannot be combined"):
		return cliCommandError(
			stderr,
			"Stored accounts and environment credentials cannot be combined",
			[]string{message},
			"Unset EMISAR_URL and EMISAR_API_KEY, or remove --account from the command.",
		)
	case strings.Contains(message, "EMISAR_URL"):
		return cliCommandError(
			stderr,
			"EMISAR_URL is invalid",
			[]string{message},
			"Use an origin such as https://emisar.dev, without a path, query, or credentials.",
		)
	case strings.Contains(message, "EMISAR_CLIENT_METADATA"):
		return cliCommandError(
			stderr,
			"EMISAR_CLIENT_METADATA is invalid",
			[]string{message},
			"Fix the JSON object or unset EMISAR_CLIENT_METADATA, then try again.",
		)
	case strings.Contains(message, "EMISAR_SIGNING_KEY") ||
		strings.Contains(message, "EMISAR_SIGNING_CERT"):
		return cliCommandError(
			stderr,
			"Signing configuration is invalid",
			[]string{message},
			"Set both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT, or unset both to disable signed dispatch.",
		)
	case strings.Contains(message, "credential"):
		return cliCommandError(
			stderr,
			"The stored account could not be used",
			[]string{message},
			"Check the credential file and directory permissions, then run `emisar-mcp auth` again.",
		)
	default:
		return cliCommandError(stderr, "Could not start the command", []string{message})
	}
}

func writeCLIWarning(stderr io.Writer, summary string, details []string, next ...string) {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticWarning,
		Summary: summary,
		Details: details,
		Next:    next,
	})
}
