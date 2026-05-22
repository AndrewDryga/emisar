package cloud

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

const echoAction = `
schema_version: 1
id: t.echo
title: Echo
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: msg
    type: string
    required: true
execution:
  command:
    binary: /bin/echo
    argv: ["{{ args.msg }}"]
  timeout: 5s
  timeout_min: 1s
  timeout_max: 30s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

const packManifest = `schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
`

func setupRegistry(t *testing.T) *packs.Registry {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(packManifest), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoAction), 0o644))
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	must(err)
	return reg
}

func TestStateBuilder_AdvertisesActionsAndPacks(t *testing.T) {
	reg := setupRegistry(t)
	b := &StateBuilder{
		AgentID:     "agt_test",
		Version:     "0.2.0",
		Labels:      map[string]string{"role": "test"},
		GetRegistry: func() *packs.Registry { return reg },
	}
	msg := b.Build()
	if msg.Type != MsgRunnerState {
		t.Fatalf("type=%s", msg.Type)
	}
	if msg.ProtocolVersion != ProtocolVersion {
		t.Fatalf("protocol version=%d", msg.ProtocolVersion)
	}
	if len(msg.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(msg.Actions))
	}
	a := msg.Actions[0]
	if a.ID != "t.echo" {
		t.Fatalf("action id=%q", a.ID)
	}
	if a.Limits.DefaultTimeout.String() != "5s" {
		t.Fatalf("default timeout=%s", a.Limits.DefaultTimeout)
	}
	if a.Limits.TimeoutMin.String() != "1s" || a.Limits.TimeoutMax.String() != "30s" {
		t.Fatalf("timeout bounds: min=%s max=%s", a.Limits.TimeoutMin, a.Limits.TimeoutMax)
	}
	if pi, ok := msg.Packs["t"]; !ok || pi.Hash == "" {
		t.Fatalf("pack info missing or no hash: %+v", msg.Packs)
	}
}

func TestPeekType_AndEnvelope(t *testing.T) {
	m := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "r1"},
		ActionID: "x.y",
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	mt, err := PeekType(raw)
	if err != nil {
		t.Fatal(err)
	}
	if mt != MsgRunAction {
		t.Fatalf("got %q", mt)
	}
}
