package packtest

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type ExitCodes []int

func (codes *ExitCodes) UnmarshalJSON(data []byte) error {
	var single int
	if err := json.Unmarshal(data, &single); err == nil {
		*codes = []int{single}
		return nil
	}
	var many []int
	if err := json.Unmarshal(data, &many); err != nil {
		return fmt.Errorf("expect_exit must be an integer or integer list: %w", err)
	}
	*codes = many
	return nil
}

func (codes ExitCodes) accepts(code int) bool {
	if len(codes) == 0 {
		return code == 0
	}
	for _, allowed := range codes {
		if code == allowed {
			return true
		}
	}
	return false
}

type Case struct {
	Action       string                     `json:"action"`
	Args         map[string]json.RawMessage `json:"args"`
	ExpectExit   ExitCodes                  `json:"expect_exit"`
	ExpectStdout []string                   `json:"expect_stdout_contains"`
	ExpectStderr []string                   `json:"expect_stderr_contains"`
	Reason       string                     `json:"reason"`
	Skip         string                     `json:"skip"`
}

type Cases struct {
	Defaults struct {
		Env map[string]any `json:"env"`
	} `json:"defaults"`
	Cases []Case `json:"cases"`
}

type Config struct {
	Emisar   string
	PacksDir string
	Config   string
	Reports  string
	Pattern  string
	Out      io.Writer
	Err      io.Writer
	BaseEnv  []string
}

type Totals struct {
	Pass, Fail, Skip int
	PacksRun         int
	PacksFailed      int
}

func (totals Totals) Failed() bool { return totals.Fail != 0 || totals.PacksFailed != 0 }

func valueString(raw json.RawMessage) (string, error) {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text, nil
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", err
	}
	compact, err := json.Marshal(value)
	return string(compact), err
}

func envValue(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case nil:
		return ""
	default:
		data, _ := json.Marshal(typed)
		return string(data)
	}
}

func Run(config Config) (Totals, error) {
	if config.Emisar == "" {
		config.Emisar = "/opt/emisar/bin/emisar"
	}
	if config.PacksDir == "" {
		config.PacksDir = "/packs"
	}
	if config.Config == "" {
		config.Config = "/workspace/test-packs/test-config.yaml"
	}
	if config.Reports == "" {
		config.Reports = "/reports"
	}
	if config.Out == nil {
		config.Out = os.Stdout
	}
	if config.Err == nil {
		config.Err = os.Stderr
	}
	if config.BaseEnv == nil {
		config.BaseEnv = os.Environ()
	}
	if info, err := os.Stat(config.Emisar); err != nil || info.Mode()&0o111 == 0 {
		return Totals{}, fmt.Errorf("emisar binary not found or executable at %s", config.Emisar)
	}
	if err := os.MkdirAll(config.Reports, 0o755); err != nil {
		return Totals{}, err
	}
	paths, err := filepath.Glob(filepath.Join(config.PacksDir, "*", "test", "cases.json"))
	if err != nil {
		return Totals{}, err
	}
	sort.Strings(paths)
	totals := Totals{}
	for _, path := range paths {
		pack := filepath.Base(filepath.Dir(filepath.Dir(path)))
		if config.Pattern != "" && !strings.Contains(pack, config.Pattern) {
			continue
		}
		fmt.Fprintf(config.Out, "================================\nPack: %s\n================================\n", pack)
		var log bytes.Buffer
		writer := io.MultiWriter(config.Out, &log)
		packTotals, runErr := runPack(config, pack, path, writer)
		totals.Pass += packTotals.Pass
		totals.Fail += packTotals.Fail
		totals.Skip += packTotals.Skip
		totals.PacksRun++
		if runErr != nil || packTotals.Fail != 0 {
			totals.PacksFailed++
		}
		if runErr != nil {
			fmt.Fprintf(writer, "ERROR %s - %v\n", pack, runErr)
		}
		if err := os.WriteFile(filepath.Join(config.Reports, pack+".log"), log.Bytes(), 0o644); err != nil {
			return totals, err
		}
	}
	fmt.Fprintf(config.Out, "\n===============================\nGRAND TOTAL\n===============================\nPacks run:     %d\nPacks failed:  %d\nTests passed:  %d\nTests failed:  %d\nTests skipped: %d\n",
		totals.PacksRun, totals.PacksFailed, totals.Pass, totals.Fail, totals.Skip)
	if totals.PacksRun == 0 {
		return totals, fmt.Errorf("no pack cases matched %q", config.Pattern)
	}
	if totals.Failed() {
		return totals, fmt.Errorf("pack tests failed")
	}
	return totals, nil
}

func runPack(config Config, pack, path string, output io.Writer) (Totals, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Totals{}, err
	}
	var cases Cases
	if err := json.Unmarshal(data, &cases); err != nil {
		return Totals{}, fmt.Errorf("parse %s: %w", path, err)
	}
	envValues := make(map[string]string)
	for _, entry := range config.BaseEnv {
		key, value, found := strings.Cut(entry, "=")
		if found {
			envValues[key] = value
		}
	}
	keys := make([]string, 0, len(cases.Defaults.Env))
	for key := range cases.Defaults.Env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		envValues[key] = envValue(cases.Defaults.Env[key])
	}
	keys = keys[:0]
	for key := range envValues {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, key := range keys {
		env = append(env, key+"="+envValues[key])
	}
	totals := Totals{}
	for _, test := range cases.Cases {
		if test.Skip != "" {
			fmt.Fprintf(output, "SKIP %s - %s\n", test.Action, test.Skip)
			totals.Skip++
			continue
		}
		reason := test.Reason
		if reason == "" {
			reason = "smoke"
		}
		arguments := []string{"--config", config.Config, "action", "run", test.Action}
		argKeys := make([]string, 0, len(test.Args))
		for key := range test.Args {
			argKeys = append(argKeys, key)
		}
		sort.Strings(argKeys)
		for _, key := range argKeys {
			value, valueErr := valueString(test.Args[key])
			if valueErr != nil {
				return totals, fmt.Errorf("%s argument %s: %w", test.Action, key, valueErr)
			}
			arguments = append(arguments, "--arg", key+"="+value)
		}
		arguments = append(arguments, "--reason", reason, "--stream")
		command := exec.Command(config.Emisar, arguments...)
		command.Env = env
		var stdout, stderr bytes.Buffer
		command.Stdout, command.Stderr = &stdout, &stderr
		runErr := command.Run()
		exitCode := 0
		if runErr != nil {
			var exitErr *exec.ExitError
			if !errors.As(runErr, &exitErr) {
				return totals, runErr
			}
			exitCode = exitErr.ExitCode()
		}
		passed := test.ExpectExit.accepts(exitCode)
		for _, needle := range test.ExpectStdout {
			passed = passed && strings.Contains(stdout.String(), needle)
		}
		for _, needle := range test.ExpectStderr {
			passed = passed && strings.Contains(stderr.String(), needle)
		}
		if passed {
			fmt.Fprintf(output, "PASS %s  (exit=%d)\n", test.Action, exitCode)
			totals.Pass++
			continue
		}
		fmt.Fprintf(output, "FAIL %s  (exit=%d, expected=%v)\n  --- stdout ---\n%s  --- stderr ---\n%s",
			test.Action, exitCode, test.ExpectExit, indent(stdout.String()), indent(stderr.String()))
		totals.Fail++
	}
	fmt.Fprintf(output, "\n[%s] pass=%d fail=%d skip=%d total=%d\n", pack, totals.Pass, totals.Fail, totals.Skip, len(cases.Cases))
	if totals.Fail != 0 {
		return totals, fmt.Errorf("%s failed", pack)
	}
	return totals, nil
}

func indent(value string) string {
	if value == "" {
		return ""
	}
	return "  " + strings.ReplaceAll(value, "\n", "\n  ") + "\n"
}
