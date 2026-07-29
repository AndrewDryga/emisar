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

	grok := parseTokenUsage("grok", `{
	  "usage":{"input_tokens":11,"cache_read_input_tokens":7,"output_tokens":6,"reasoning_tokens":2,"total_tokens":24}
	}`)
	if grok.InputTokens != 11 || grok.CachedTokens != 7 ||
		grok.ReasoningTokens != 2 || grok.TotalTokens != 24 {
		t.Fatalf("grok usage = %#v", grok)
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

func TestParseGeminiTokenUsage(t *testing.T) {
	raw := `{"stats":{"models":{
	  "gemini-a":{"tokens":{"input":12,"prompt":17,"candidates":3,"cached":5,"thoughts":2,"total":20}},
	  "gemini-b":{"tokens":{"input":7,"prompt":7,"candidates":2,"cached":0,"thoughts":1,"total":9}}
	}}}`
	got := parseTokenUsage("gemini", raw)
	if got.InputTokens != 19 || got.CachedTokens != 5 ||
		got.OutputTokens != 5 || got.ReasoningTokens != 3 || got.TotalTokens != 29 {
		t.Fatalf("gemini usage = %#v", got)
	}
}
