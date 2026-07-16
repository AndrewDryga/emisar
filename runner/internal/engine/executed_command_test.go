package engine

import (
	"context"
	"strings"
	"testing"
)

func TestEngine_LocalAuditKeepsFullExecutedCommand(t *testing.T) {
	engine, journal, root := setupEngine(t)
	defer journal.Close()

	message := strings.Repeat("x", 20*1024)
	result, err := engine.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": message},
		Reason:   "verify full local command evidence",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.ExecutedCommand) <= 16*1024 {
		t.Fatalf("test command bytes=%d, want above remote cap", len(result.ExecutedCommand))
	}

	events := readJournalEvents(t, root)
	terminal := events[len(events)-1]
	if terminal.Execution == nil || terminal.Execution.ExecutedCommand != result.ExecutedCommand {
		t.Fatal("terminal audit did not retain the full masked command")
	}
}
