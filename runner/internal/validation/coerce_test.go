package validation

import (
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// The coercion helpers are how the runner accepts the same logical value
// whether it arrived as JSON (float64, []any), YAML (int, []string), or a
// native Go caller. They gate every numeric/enum/array bound check, so each
// type branch is exercised directly here.

func TestToInt(t *testing.T) {
	ok := []struct {
		in   any
		want int64
	}{
		{int(7), 7},
		{int32(7), 7},
		{int64(7), 7},
		{uint(7), 7},
		{uint32(7), 7},
		{uint64(7), 7},
		{float64(7), 7}, // whole float (the JSON number case)
		{float32(7), 7}, // whole float32
		{"7", 7},        // numeric string
		{"-42", -42},    // negative string
	}
	for _, c := range ok {
		got, valid := toInt(c.in)
		if !valid || got != c.want {
			t.Errorf("toInt(%#v) = (%d,%v), want (%d,true)", c.in, got, valid, c.want)
		}
	}

	bad := []any{
		float64(7.5), // fractional float must NOT coerce to int
		float32(7.5),
		"7.5",   // non-integer string
		"abc",   // not a number
		true,    // bool is not an int
		[]any{}, // array is not an int
		nil,
	}
	for _, in := range bad {
		if got, valid := toInt(in); valid {
			t.Errorf("toInt(%#v) = (%d,true), want invalid", in, got)
		}
	}
}

func TestToFloat(t *testing.T) {
	ok := []struct {
		in   any
		want float64
	}{
		{int(3), 3},
		{int32(3), 3},
		{int64(3), 3},
		{float32(2.5), 2.5},
		{float64(2.5), 2.5},
		{"2.5", 2.5},
		{"-1.25", -1.25},
	}
	for _, c := range ok {
		got, valid := toFloat(c.in)
		if !valid || got != c.want {
			t.Errorf("toFloat(%#v) = (%v,%v), want (%v,true)", c.in, got, valid, c.want)
		}
	}
	for _, in := range []any{"nope", true, []any{1}, nil} {
		if got, valid := toFloat(in); valid {
			t.Errorf("toFloat(%#v) = (%v,true), want invalid", in, got)
		}
	}
}

func TestToAnyArray(t *testing.T) {
	cases := []struct {
		in   any
		want []any
	}{
		{[]any{1, "x"}, []any{1, "x"}},
		{[]string{"a", "b"}, []any{"a", "b"}},
		{[]int{1, 2}, []any{int64(1), int64(2)}}, // normalised to int64
		{[]int64{3, 4}, []any{int64(3), int64(4)}},
	}
	for _, c := range cases {
		got, err := toAnyArray(c.in)
		if err != nil {
			t.Errorf("toAnyArray(%#v) error: %v", c.in, err)
			continue
		}
		if len(got) != len(c.want) {
			t.Errorf("toAnyArray(%#v) len %d, want %d", c.in, len(got), len(c.want))
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("toAnyArray(%#v)[%d] = %#v, want %#v", c.in, i, got[i], c.want[i])
			}
		}
	}
	for _, in := range []any{"scalar", 5, map[string]any{}} {
		if _, err := toAnyArray(in); err == nil {
			t.Errorf("toAnyArray(%#v) should error on a non-array", in)
		}
	}
}

func TestEqual(t *testing.T) {
	truthy := [][2]any{
		{"x", "x"},
		{int64(5), int64(5)},
		{int64(5), 5.0}, // int target, float candidate coerces
		{int64(5), "5"}, // int target, string candidate coerces
		{float64(2.5), "2.5"},
		{true, true},
	}
	for _, c := range truthy {
		if !equal(c[0], c[1]) {
			t.Errorf("equal(%#v, %#v) = false, want true", c[0], c[1])
		}
	}
	falsy := [][2]any{
		{"x", "y"},
		{int64(5), int64(6)},
		{int64(5), "abc"}, // uncoercible
		{true, false},
		{true, "true"}, // bool only equals bool
	}
	for _, c := range falsy {
		if equal(c[0], c[1]) {
			t.Errorf("equal(%#v, %#v) = true, want false", c[0], c[1])
		}
	}
}

func TestArrayLen(t *testing.T) {
	cases := []struct {
		in   any
		want int
	}{
		{[]string{"a", "b", "c"}, 3},
		{[]int64{1, 2}, 2},
		{[]any{1}, 1},
	}
	for _, c := range cases {
		got, ok := arrayLen(c.in)
		if !ok || got != c.want {
			t.Errorf("arrayLen(%#v) = (%d,%v), want (%d,true)", c.in, got, ok, c.want)
		}
	}
	if _, ok := arrayLen("not an array"); ok {
		t.Error("arrayLen on a non-array should report false")
	}
}

func TestStringsForAndToString(t *testing.T) {
	a := actionspec.Arg{Name: "p"}
	if got, err := stringsFor(a, "one"); err != nil || len(got) != 1 || got[0] != "one" {
		t.Errorf("stringsFor(string) = (%v,%v)", got, err)
	}
	if got, err := stringsFor(a, []string{"a", "b"}); err != nil || len(got) != 2 {
		t.Errorf("stringsFor([]string) = (%v,%v)", got, err)
	}
	if _, err := stringsFor(a, 42); err == nil {
		t.Error("stringsFor on a non-string value should error")
	}

	if s, ok := toString("hi"); !ok || s != "hi" {
		t.Errorf("toString(string) = (%q,%v)", s, ok)
	}
	if _, ok := toString(7); ok {
		t.Error("toString on a non-string should report false")
	}
}
