package devtool

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
)

type pinnedTool struct {
	Name    string
	Pin     string
	Command string
	Args    []string
	Parse   func(string) string
}

var (
	goVersionPattern         = regexp.MustCompile(`\bgo([0-9]+\.[0-9]+\.[0-9]+)\b`)
	elixirVersionPattern     = regexp.MustCompile(`(?m)^Elixir ([^[:space:]]+)`)
	otpMajorPattern          = regexp.MustCompile(`(?m)^Erlang/OTP ([0-9]+)\b`)
	terraformVersionPattern  = regexp.MustCompile(`(?m)^Terraform v([^[:space:]]+)`)
	tflintVersionPattern     = regexp.MustCompile(`(?m)^TFLint version ([^[:space:]]+)`)
	mixVersionPattern        = regexp.MustCompile(`(?m)^Mix ([^[:space:]]+)`)
	shellcheckVersionPattern = regexp.MustCompile(`(?m)^version: ([^[:space:]]+)`)
)

const erlangVersionExpression = `Root = code:root_dir(), Release = erlang:system_info(otp_release), {ok, Data} = file:read_file(filename:join([Root, "releases", Release, "OTP_VERSION"])), io:format("~s", [string:trim(binary_to_list(Data))]), halt().`

func (a *App) checkDevelopmentTools(ctx context.Context) error {
	pins, err := readToolVersions(filepath.Join(a.Root, ".tool-versions"))
	if err != nil {
		return fmt.Errorf("read pinned development tools: %w; run './run bootstrap'", err)
	}
	checks := []pinnedTool{
		{Name: "Go", Pin: "golang", Command: "go", Args: []string{"version"}, Parse: regexpVersion(goVersionPattern)},
		{Name: "Erlang/OTP", Pin: "erlang", Command: "erl", Args: []string{"-noshell", "-eval", erlangVersionExpression}, Parse: strings.TrimSpace},
		{Name: "Elixir", Pin: "elixir", Command: "elixir", Args: []string{"--version"}, Parse: parseElixirVersion},
		{Name: "Terraform", Pin: "terraform", Command: "terraform", Args: []string{"version"}, Parse: regexpVersion(terraformVersionPattern)},
		{Name: "TFLint", Pin: "tflint", Command: "tflint", Args: []string{"--version"}, Parse: regexpVersion(tflintVersionPattern)},
	}

	var failures []string
	for _, check := range checks {
		expected := pins[check.Pin]
		if expected == "" {
			failures = append(failures, fmt.Sprintf("%s has no %s pin in .tool-versions", check.Name, check.Pin))
			fmt.Fprintf(a.Out, "[missing] %-12s no repository pin\n", check.Name)
			continue
		}
		env := map[string]string(nil)
		if check.Command == "go" {
			env = map[string]string{"GOTOOLCHAIN": "local"}
		}
		output, outputErr := a.output(ctx, a.Root, env, check.Command, check.Args...)
		if outputErr != nil {
			failures = append(failures, fmt.Sprintf("%s %s is required: %v", check.Name, expected, outputErr))
			fmt.Fprintf(a.Out, "[missing] %-12s need %s\n", check.Name, expected)
			continue
		}
		actual := check.Parse(string(output))
		if actual != expected {
			failures = append(failures, fmt.Sprintf("%s is %q, need exact pin %q", check.Name, actual, expected))
			fmt.Fprintf(a.Out, "[mismatch] %-11s %s (need %s)\n", check.Name, actual, expected)
			continue
		}
		fmt.Fprintf(a.Out, "[ok] %-16s %s\n", check.Name, actual)
	}

	for _, tool := range []struct {
		name    string
		command string
		args    []string
		host    bool
		parse   func(string) string
	}{
		{name: "Git", command: "git", args: []string{"--version"}},
		{name: "Mix", command: "mix", args: []string{"--version"}, parse: regexpVersion(mixVersionPattern)},
		{name: "ShellCheck", command: "shellcheck", args: []string{"--version"}, parse: regexpVersion(shellcheckVersionPattern)},
		{name: "Coop", command: "coop", args: []string{"version"}, host: true},
		{name: "Docker", command: "docker", args: []string{"version", "--format", "{{.Client.Version}}"}, host: true},
	} {
		if tool.host && a.inBox() {
			continue
		}
		output, outputErr := a.output(ctx, a.Root, nil, tool.command, tool.args...)
		if outputErr != nil {
			failures = append(failures, fmt.Sprintf("%s is required: %v", tool.name, outputErr))
			fmt.Fprintf(a.Out, "[missing] %s\n", tool.name)
			continue
		}
		version := firstVersionLine(string(output))
		if tool.parse != nil {
			version = tool.parse(string(output))
		}
		fmt.Fprintf(a.Out, "[ok] %-16s %s\n", tool.name, version)
	}

	if chrome, chromeErr := devbrowser.ResolveChrome(); chromeErr != nil {
		failures = append(failures, fmt.Sprintf("Chrome/Chromium is required: %v", chromeErr))
		fmt.Fprintln(a.Out, "[missing] Chrome/Chromium")
	} else {
		version, versionErr := a.output(ctx, a.Root, nil, chrome, "--version")
		if versionErr != nil {
			failures = append(failures, fmt.Sprintf("read browser version: %v", versionErr))
			fmt.Fprintf(a.Out, "[missing] Browser version at %s\n", chrome)
		} else {
			fmt.Fprintf(a.Out, "[ok] Browser          %s (%s)\n", firstVersionLine(string(version)), chrome)
		}
	}
	if imageErr := a.ensureImageTools(); imageErr != nil {
		failures = append(failures, imageErr.Error())
		fmt.Fprintln(a.Out, "[missing] ImageMagick")
	} else {
		command := "magick"
		if _, pathErr := exec.LookPath(command); pathErr != nil {
			command = "identify"
		}
		version, versionErr := a.output(ctx, a.Root, nil, command, "-version")
		if versionErr != nil {
			failures = append(failures, fmt.Sprintf("read ImageMagick version: %v", versionErr))
			fmt.Fprintln(a.Out, "[missing] ImageMagick version")
		} else {
			fmt.Fprintf(a.Out, "[ok] ImageMagick      %s\n", firstVersionLine(string(version)))
		}
	}

	if len(failures) != 0 {
		sort.Strings(failures)
		return fmt.Errorf("development prerequisites are not ready:\n  - %s\nrun './run bootstrap' for exact installation commands", strings.Join(failures, "\n  - "))
	}
	return nil
}

func readToolVersions(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	versions := make(map[string]string)
	for lineNumber, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("line %d must contain one tool and one version", lineNumber+1)
		}
		if _, exists := versions[fields[0]]; exists {
			return nil, fmt.Errorf("line %d repeats %s", lineNumber+1, fields[0])
		}
		versions[fields[0]] = fields[1]
	}
	return versions, nil
}

func regexpVersion(pattern *regexp.Regexp) func(string) string {
	return func(output string) string {
		match := pattern.FindStringSubmatch(output)
		if len(match) != 2 {
			return strings.TrimSpace(output)
		}
		return match[1]
	}
}

func parseElixirVersion(output string) string {
	elixir := regexpVersion(elixirVersionPattern)(output)
	otp := regexpVersion(otpMajorPattern)(output)
	if elixir == strings.TrimSpace(output) || otp == strings.TrimSpace(output) {
		return strings.TrimSpace(output)
	}
	return elixir + "-otp-" + otp
}

func firstVersionLine(output string) string {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "license:") {
			return line
		}
	}
	return "available"
}
