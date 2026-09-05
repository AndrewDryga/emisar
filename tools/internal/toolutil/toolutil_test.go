package toolutil

import (
	"reflect"
	"testing"
)

func TestMergedEnvReplacesExistingValue(t *testing.T) {
	t.Setenv("EMISAR_ENV_FIXTURE", "old")
	env := MergedEnv(map[string]string{"EMISAR_ENV_FIXTURE": "new"})
	matches := 0
	for _, entry := range env {
		if entry == "EMISAR_ENV_FIXTURE=new" {
			matches++
		}
		if entry == "EMISAR_ENV_FIXTURE=old" {
			t.Fatalf("old value remains in environment: %v", env)
		}
	}
	if matches != 1 {
		t.Fatalf("new value appeared %d times", matches)
	}
}

func TestNULFieldsDropsEmptyRecords(t *testing.T) {
	fields := NULFields([]byte("run\x00tools/go.mod\x00"))
	if want := []string{"run", "tools/go.mod"}; !reflect.DeepEqual(fields, want) {
		t.Fatalf("fields = %v, want %v", fields, want)
	}
	if fields := NULFields(nil); len(fields) != 0 {
		t.Fatalf("empty output produced %v", fields)
	}
}

func TestHasAnyPrefix(t *testing.T) {
	if !HasAnyPrefix("tools/internal/ci/select.go", "dev/", "tools/") {
		t.Fatal("matching prefix not reported")
	}
	if HasAnyPrefix("runner/main.go", "dev/", "tools/") {
		t.Fatal("non-matching value reported as prefixed")
	}
}
