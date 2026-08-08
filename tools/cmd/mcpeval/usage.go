package main

import (
	"bytes"
	"encoding/json"
	"strings"
)

// parseTokenUsage normalizes the machine-readable usage each pinned client
// emits. Absence remains zero-valued; usage is evidence, not a pass condition,
// because subscription-backed clients do not always return billing counters.
func parseTokenUsage(provider, raw string) tokenUsage {
	switch provider {
	case "codex":
		return parseCodexUsage(raw)
	default:
		return parseDirectUsage(raw)
	}
}

func parseDirectUsage(raw string) tokenUsage {
	payload := decodeObject(raw)
	usage, _ := payload["usage"].(map[string]any)
	input := number(usage, "input_tokens", "inputTokens")
	cached := number(usage, "cache_read_input_tokens", "cached_input_tokens", "cachedTokens")
	cached += number(usage, "cache_creation_input_tokens")
	output := number(usage, "output_tokens", "outputTokens")
	reasoning := number(usage, "reasoning_tokens", "reasoning_output_tokens")
	total := number(usage, "total_tokens", "totalTokens")
	if total == 0 {
		total = input + cached + output
	}
	return tokenUsage{
		InputTokens: input, CachedTokens: cached, OutputTokens: output,
		ReasoningTokens: reasoning, TotalTokens: total,
	}
}

func parseCodexUsage(raw string) tokenUsage {
	var result tokenUsage
	for _, line := range strings.Split(raw, "\n") {
		payload := decodeObject(line)
		if payload["type"] != "turn.completed" {
			continue
		}
		usage, _ := payload["usage"].(map[string]any)
		result.InputTokens = number(usage, "input_tokens")
		result.CachedTokens = number(usage, "cached_input_tokens")
		result.OutputTokens = number(usage, "output_tokens")
		result.ReasoningTokens = number(usage, "reasoning_output_tokens")
		result.TotalTokens = number(usage, "total_tokens")
		if result.TotalTokens == 0 {
			result.TotalTokens = result.InputTokens + result.OutputTokens
		}
	}
	return result
}

func decodeObject(raw string) map[string]any {
	decoder := json.NewDecoder(bytes.NewBufferString(strings.TrimSpace(raw)))
	decoder.UseNumber()
	var payload map[string]any
	if decoder.Decode(&payload) != nil {
		return map[string]any{}
	}
	return payload
}

func number(value map[string]any, keys ...string) int64 {
	for _, key := range keys {
		switch candidate := value[key].(type) {
		case json.Number:
			parsed, _ := candidate.Int64()
			return parsed
		case float64:
			return int64(candidate)
		}
	}
	return 0
}
