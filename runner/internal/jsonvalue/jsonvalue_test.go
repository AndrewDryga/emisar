package jsonvalue

import (
	"errors"
	"strings"
	"testing"
)

func TestDecodeObjectStrictAndBounded(t *testing.T) {
	limits := Limits{MaxBytes: 64, MaxDepth: 3, MaxNodes: 6}
	if got, err := DecodeObject([]byte(`{"n":9007199254740993}`), limits); err != nil {
		t.Fatal(err)
	} else if got["n"].(interface{ String() string }).String() != "9007199254740993" {
		t.Fatalf("number lost precision: %#v", got["n"])
	}

	cases := []struct {
		name string
		raw  string
		want error
	}{
		{"duplicate", `{"a":1,"a":2}`, nil},
		{"scalar", `1`, ErrRootNotObject},
		{"depth", `{"a":{"b":{"c":1}}}`, ErrTooDeep},
		{"nodes", `{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6}`, ErrTooManyNodes},
		{"bytes", `{"a":"` + strings.Repeat("x", 64) + `"}`, ErrTooLarge},
		{"surrogate", `{"a":"\ud800"}`, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := DecodeObject([]byte(tc.raw), limits)
			if err == nil {
				t.Fatal("invalid JSON accepted")
			}
			if tc.want != nil && !errors.Is(err, tc.want) {
				t.Fatalf("error=%v, want %v", err, tc.want)
			}
		})
	}
}
