package redact

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

var (
	// ErrInvalidJSON means the action did not emit one JSON value. Callers must
	// still text-redact the invalid bytes before recording or returning them.
	ErrInvalidJSON = errors.New("redact: input is not one JSON value")
	// ErrUnsafeJSONRedaction means an authored whole-document rule produced
	// invalid JSON. ApplyJSON returns the safe JSON value null in this case.
	ErrUnsafeJSONRedaction = errors.New("redact: rule produced invalid JSON")
)

// ApplyJSON redacts strings before re-encoding a JSON value, then applies the
// whole rule set once more to preserve rules which intentionally match JSON
// field names or relationships. Re-encoding before the whole-document pass is
// what keeps an assignment inside a quoted string from consuming that string's
// closing quote. The returned document is always valid when err is nil or
// ErrUnsafeJSONRedaction.
func (e *Engine) ApplyJSON(input []byte) ([]byte, []Hit, error) {
	value, err := decodeOneJSON(input)
	if err != nil {
		return nil, nil, ErrInvalidJSON
	}

	value, scalarHits := e.redactJSONStrings(value)
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, scalarHits, fmt.Errorf("redact: encode JSON: %w", err)
	}

	whole, wholeHits := e.Apply(string(encoded))
	hits := MergeHits(scalarHits, wholeHits)
	if !json.Valid([]byte(whole)) {
		return []byte("null"), hits, ErrUnsafeJSONRedaction
	}

	canonical, err := decodeOneJSON([]byte(whole))
	if err != nil {
		return []byte("null"), hits, ErrUnsafeJSONRedaction
	}
	encoded, err = json.Marshal(canonical)
	if err != nil {
		return nil, hits, fmt.Errorf("redact: encode redacted JSON: %w", err)
	}
	return encoded, hits, nil
}

func decodeOneJSON(input []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	return value, nil
}

func (e *Engine) redactJSONStrings(value any) (any, []Hit) {
	switch typed := value.(type) {
	case string:
		redacted, hits := e.Apply(typed)
		return redacted, hits
	case []any:
		var hits []Hit
		for index, item := range typed {
			var itemHits []Hit
			typed[index], itemHits = e.redactJSONStrings(item)
			hits = MergeHits(hits, itemHits)
		}
		return typed, hits
	case map[string]any:
		redacted := make(map[string]any, len(typed))
		var hits []Hit
		for key, item := range typed {
			redactedKey, keyHits := e.Apply(key)
			var redactedItem any
			var itemHits []Hit
			if replacement, fieldHits, matched := e.jsonFieldReplacement(key); matched {
				redactedItem = replacement
				itemHits = fieldHits
			} else {
				redactedItem, itemHits = e.redactJSONStrings(item)
			}
			redacted[redactedKey] = redactedItem
			hits = MergeHits(hits, keyHits, itemHits)
		}
		return redacted, hits
	default:
		return value, nil
	}
}

// jsonFieldReplacement asks the existing rule engine how it treats a string
// under this exact key, using an empty value which cannot itself contain a
// credential. This preserves reviewed rules such as json-secret-field and
// pack-local `("PrivateKey":)"..."` rules without applying regex replacement
// bytes directly inside the caller's potentially escape-heavy JSON string.
func (e *Engine) jsonFieldReplacement(key string) (string, []Hit, bool) {
	probe, err := json.Marshal(map[string]string{key: ""})
	if err != nil {
		return "", nil, false
	}
	redacted, hits := e.Apply(string(probe))
	if len(hits) == 0 {
		return "", nil, false
	}
	var decoded map[string]string
	if json.Unmarshal([]byte(redacted), &decoded) == nil {
		if replacement, ok := decoded[key]; ok && replacement != "" {
			return replacement, hits, true
		}
	}
	// A matching contextual rule which cannot produce a safe scalar is still a
	// redaction signal. Mask the value; the final whole-document pass will mark
	// the action invalid if the authored replacement itself breaks JSON.
	return "[REDACTED]", hits, true
}
