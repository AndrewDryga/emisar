package cloud

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestClient_ArgumentFailureCodeAndDiagnosticReachWire(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	sendRunAction(t, conn, cli, "req_invalid_args", "t.echo", map[string]any{})
	result := waitForResult(t, conn, "req_invalid_args", 3*time.Second)
	if result["status"] != "validation_failed" || result["reason"] != "argument_invalid" {
		t.Fatalf("result = %#v, want fixed validation failure", result)
	}
	detail, ok := result["error"].(string)
	if !ok || !strings.Contains(detail, "msg") {
		t.Fatalf("human diagnostic missing on wire: %#v", result)
	}
	requireResultEventID(t, result)
}
