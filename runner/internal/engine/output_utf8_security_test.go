package engine

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/executor"
)

func TestBoundedOutput_PreservesUTF8Prefix(t *testing.T) {
	const input = "xé€😀z"
	for limit := 0; limit < len(input); limit++ {
		t.Run(fmt.Sprintf("limit_%d", limit), func(t *testing.T) {
			want := input[:limit]
			for !utf8.ValidString(want) {
				want = want[:len(want)-1]
			}
			buf := boundedOutput{limit: limit}
			if got := string(buf.take([]byte(input))); got != want || !buf.truncated {
				t.Fatalf("got %q truncated=%t, want %q", got, buf.truncated, want)
			}
			if got := buf.take([]byte("later")); len(got) != 0 || buf.String() != want {
				t.Fatal("output resumed after an omitted rune")
			}
			if limit > 0 && truncatePreview(input, limit) != want+"\n...[truncated]" {
				t.Fatal("journal preview split a rune")
			}
		})
	}
}

func TestEngine_OutputCapsKeepUTF8AndHashesConsistent(t *testing.T) {
	const action = `
schema_version: 1
id: t.unicode
title: Unicode output
kind: exec
risk: low
description: Echo synthetic Unicode output to both streams.
side_effects: [none]
args:
  - {name: value, type: string, required: true}
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "printf '%s%s' \"$VALUE\" \"$VALUE\"; printf '%s%s' \"$VALUE\" \"$VALUE\" >&2"]
  env:
    VALUE: "{{ args.value }}"
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 65536
  max_stdout_bytes_min: 1
  max_stderr_bytes: 65536
  max_stderr_bytes_min: 1
`
	for _, parser := range []string{"text", "json"} {
		e, journal, root := setupEngineExtra(t, map[string]string{"unicode.yaml": strings.Replace(action, "parser: text", "parser: "+parser, 1)})
		t.Cleanup(func() { _ = journal.Close() })
		for _, limit := range []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 32768} {
			for _, streaming := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s_%d_streaming_%t", parser, limit, streaming), func(t *testing.T) {
					input := strings.Repeat("xé€😀", 4000)
					want := input[:limit]
					for !utf8.ValidString(want) {
						want = want[:len(want)-1]
					}
					streams := map[executor.Stream]*strings.Builder{executor.StreamStdout: {}, executor.StreamStderr: {}}
					req := Request{ActionID: "t.unicode", Args: map[string]any{"value": input[:len(input)/2]}, Reason: "test", Opts: Opts{MaxStdoutBytes: limit, MaxStderrBytes: limit}}
					if streaming {
						req.OnProgress = func(stream executor.Stream, data []byte) { streams[stream].Write(data) }
					}
					result, err := e.Run(t.Context(), req)
					if err != nil {
						t.Fatal(err)
					}
					if result.Status != StatusSuccess || result.Stdout != want || result.Stderr != want || !result.TruncatedOut || !result.TruncatedErr {
						t.Fatalf("output cap changed bytes: status=%s stdout=%d stderr=%d want=%d truncated=%t/%t", result.Status, len(result.Stdout), len(result.Stderr), len(want), result.TruncatedOut, result.TruncatedErr)
					}
					if streaming && (streams[executor.StreamStdout].String() != want || streams[executor.StreamStderr].String() != want) {
						t.Fatal("progress differs from retained output")
					}
					encoded, err := json.Marshal(result)
					if err != nil {
						t.Fatal(err)
					}
					var decoded Result
					if err := json.Unmarshal(encoded, &decoded); err != nil {
						t.Fatal(err)
					}
					hash := fmt.Sprintf("%x", sha256.Sum256([]byte(want)))
					if decoded.Stdout != want || decoded.Stderr != want || decoded.StdoutBytes != len(want) || decoded.StderrBytes != len(want) || decoded.StdoutSHA256 != hash || decoded.StderrSHA256 != hash {
						t.Fatal("JSON roundtrip changed output or hash accounting")
					}
					events := readJournalEvents(t, root)
					terminal := events[len(events)-1]
					if terminal.EventID != result.EventID || terminal.Execution.StdoutSHA256 != hash || terminal.Execution.StderrSHA256 != hash || terminal.Execution.StdoutBytes != len(want) || terminal.Execution.StderrBytes != len(want) {
						t.Fatal("journal accounting differs from emitted bytes")
					}
				})
			}
		}
	}
}
