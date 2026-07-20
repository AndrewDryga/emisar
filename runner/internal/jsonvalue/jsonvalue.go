// Package jsonvalue validates bounded JSON values at hostile-input boundaries.
package jsonvalue

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

var (
	ErrTooLarge      = errors.New("JSON exceeds byte limit")
	ErrTooDeep       = errors.New("JSON exceeds nesting limit")
	ErrTooManyNodes  = errors.New("JSON exceeds node limit")
	ErrRootNotObject = errors.New("JSON root is not an object")
)

// Limits bounds both encoded input and its decoded structure. Zero disables a
// particular bound.
type Limits struct {
	MaxBytes int
	MaxDepth int
	MaxNodes int
}

// Validate checks one complete JSON value, rejects duplicate object keys and
// malformed Unicode escapes, and enforces structural limits without retaining
// a second decoded copy.
func Validate(raw []byte, limits Limits) error {
	if limits.MaxBytes > 0 && len(raw) > limits.MaxBytes {
		return ErrTooLarge
	}
	if !utf8.Valid(raw) {
		return fmt.Errorf("JSON is not valid UTF-8")
	}
	if err := validateUnicodeSurrogates(raw); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	nodes := 0
	if err := consumeUniqueValue(decoder, 1, &nodes, limits); err != nil {
		return err
	}
	if token, err := decoder.Token(); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("unexpected trailing token %v", token)
	}
	return nil
}

// DecodeObject validates then decodes one JSON object while preserving exact
// JSON numbers.
func DecodeObject(raw []byte, limits Limits) (map[string]any, error) {
	if err := Validate(raw, limits); err != nil {
		return nil, err
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, ErrRootNotObject
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value map[string]any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return value, nil
}

// CheckValue verifies that an already-decoded value is JSON-encodable and
// obeys the same encoded and structural limits.
func CheckValue(value any, limits Limits) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode JSON value: %w", err)
	}
	return Validate(raw, limits)
}

func consumeUniqueValue(decoder *json.Decoder, depth int, nodes *int, limits Limits) error {
	if limits.MaxDepth > 0 && depth > limits.MaxDepth {
		return ErrTooDeep
	}
	*nodes++
	if limits.MaxNodes > 0 && *nodes > limits.MaxNodes {
		return ErrTooManyNodes
	}

	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]struct{}{}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("object key is not a string")
			}
			if _, duplicate := seen[key]; duplicate {
				return fmt.Errorf("duplicate object key %q", key)
			}
			seen[key] = struct{}{}
			if err := consumeUniqueValue(decoder, depth+1, nodes, limits); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim('}') {
			return fmt.Errorf("object has invalid closing delimiter")
		}
	case '[':
		for decoder.More() {
			if err := consumeUniqueValue(decoder, depth+1, nodes, limits); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim(']') {
			return fmt.Errorf("array has invalid closing delimiter")
		}
	default:
		return fmt.Errorf("unexpected delimiter %q", delim)
	}
	return nil
}

func validateUnicodeSurrogates(raw []byte) error {
	inString := false
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '"':
			inString = !inString
		case '\\':
			if !inString || i+1 >= len(raw) {
				continue
			}
			if raw[i+1] != 'u' {
				i++
				continue
			}
			code, ok := decodeHex4(raw, i+2)
			if !ok {
				continue
			}
			i += 5
			switch {
			case code >= 0xd800 && code <= 0xdbff:
				if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
					return fmt.Errorf("JSON string contains an unpaired high surrogate")
				}
				low, ok := decodeHex4(raw, i+3)
				if !ok || low < 0xdc00 || low > 0xdfff {
					return fmt.Errorf("JSON string contains an unpaired high surrogate")
				}
				i += 6
			case code >= 0xdc00 && code <= 0xdfff:
				return fmt.Errorf("JSON string contains an unpaired low surrogate")
			}
		}
	}
	return nil
}

func decodeHex4(raw []byte, start int) (uint16, bool) {
	if start+4 > len(raw) {
		return 0, false
	}
	var value uint16
	for _, char := range raw[start : start+4] {
		value <<= 4
		switch {
		case char >= '0' && char <= '9':
			value |= uint16(char - '0')
		case char >= 'a' && char <= 'f':
			value |= uint16(char-'a') + 10
		case char >= 'A' && char <= 'F':
			value |= uint16(char-'A') + 10
		default:
			return 0, false
		}
	}
	return value, true
}
