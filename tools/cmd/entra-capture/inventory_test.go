package main

import (
	"strings"
	"testing"
)

// A failed delete must read as a failure on its own row, not only in the
// run's final error.
func TestDeleteResult(t *testing.T) {
	for _, tc := range []struct {
		status int
		ok     bool
		prefix string
	}{
		{204, true, "  removed "},
		{403, false, "  FAILED to remove "},
		{404, false, "  FAILED to remove "},
		{200, false, "  FAILED to remove "},
	} {
		line, ok := deleteResult("emisar sso", "applications", tc.status)
		if ok != tc.ok || !strings.HasPrefix(line, tc.prefix) {
			t.Errorf("deleteResult(%d) = %q, %v; want prefix %q, %v", tc.status, line, ok, tc.prefix, tc.ok)
		}
	}
}
