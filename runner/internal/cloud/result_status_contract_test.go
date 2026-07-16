package cloud

import "testing"

// This is the portal's @result_statuses map in
// portal/apps/emisar/lib/emisar/runs.ex. It is deliberately kept as a small
// fixture here because runner and portal are separate shipped artifacts; the
// test makes a new runner status fail before it can be silently treated as
// failed by the portal's defensive default.
func TestRunnerResultStatusesMatchPortalMapping(t *testing.T) {
	portalResultStatuses := map[string]string{
		"success":              "success",
		"failed":               "failed",
		"error":                "error",
		"validation_failed":    "validation_failed",
		"unknown_action":       "unknown_action",
		"timed_out":            "timed_out",
		"cancelled":            "cancelled",
		"blocked_by_admission": "refused",
		"signature_invalid":    "refused",
		"pack_hash_mismatch":   "refused",
	}

	seen := make(map[string]struct{}, len(runnerResultStatuses()))
	for _, status := range runnerResultStatuses() {
		status := status
		t.Run(status, func(t *testing.T) {
			if _, duplicate := seen[status]; duplicate {
				t.Fatalf("runner status %q is listed more than once", status)
			}
			seen[status] = struct{}{}

			if mapped, ok := portalResultStatuses[status]; !ok {
				t.Fatalf("runner status %q has no portal mapping", status)
			} else if mapped == "" {
				t.Fatalf("runner status %q has an empty portal mapping", status)
			}
		})
	}

	if len(seen) != len(portalResultStatuses) {
		t.Fatalf("runner statuses = %d, portal mappings = %d; update both sides together", len(seen), len(portalResultStatuses))
	}
}
