package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestEngine_ScalarArgIsLiteralArgvNoShell proves an LLM-supplied arg with
// shell metacharacters is passed to the process as ONE literal argv element
// through the full validate→render→exec path — never word-split, never
// shell-evaluated. This locks the argv-array execution model: if a future
// change ever introduced a shell-exec path, the injected `touch` commands
// below would run and fail this test.
func TestEngine_ScalarArgIsLiteralArgvNoShell(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	marker := filepath.Join(root, "PWNED")
	payload := "hi; touch " + marker + " $(touch " + marker + ") `touch " + marker + "` && touch " + marker

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": payload},
		Reason:   "injection probe",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
	}
	// /bin/echo prints its single argv element verbatim + a newline.
	if got := strings.TrimRight(res.Stdout, "\n"); got != payload {
		t.Fatalf("arg was not passed as one literal argv element:\n got=%q\nwant=%q", got, payload)
	}
	// No shell ran, so none of the injected `touch` commands executed.
	if _, err := os.Stat(marker); err == nil {
		t.Fatalf("shell metacharacters were evaluated — %s was created", marker)
	}
}
