package main

import "testing"

func TestParseDirectTokenUsage(t *testing.T) {
	claude := parseTokenUsage("claude", `{
	  "usage":{"input_tokens":10,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens":5}
	}`)
	if claude.InputTokens != 10 || claude.CachedTokens != 7 ||
		claude.OutputTokens != 5 || claude.TotalTokens != 22 {
		t.Fatalf("claude usage = %#v", claude)
	}

	// An explicit total wins over the summed fields, and a client the switch
	// does not name falls through to this same direct shape.
	totalled := parseTokenUsage("claude", `{
	  "usage":{"input_tokens":11,"cache_read_input_tokens":7,"output_tokens":6,"reasoning_tokens":2,"total_tokens":24}
	}`)
	if totalled.InputTokens != 11 || totalled.CachedTokens != 7 ||
		totalled.ReasoningTokens != 2 || totalled.TotalTokens != 24 {
		t.Fatalf("totalled usage = %#v", totalled)
	}
}

func TestParseCodexTokenUsage(t *testing.T) {
	raw := "{\"type\":\"item.completed\"}\n" +
		`{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":8,"output_tokens":4,"reasoning_output_tokens":2}}`
	got := parseTokenUsage("codex", raw)
	if got.InputTokens != 20 || got.CachedTokens != 8 ||
		got.OutputTokens != 4 || got.ReasoningTokens != 2 || got.TotalTokens != 24 {
		t.Fatalf("codex usage = %#v", got)
	}
}
