package cloud

import (
	"os"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// StateBuilder constructs the RunnerStateMsg the runner ships on connect
// and on SIGHUP-driven re-advertisement. GetRegistry is called every
// Build() so post-reload state reflects the current pack set.
type StateBuilder struct {
	AgentID     string
	Version     string
	Hostname    string
	Group       string
	Labels      map[string]string
	GetRegistry func() *packs.Registry
	// Admission, if set, filters the advertised action list — any
	// action rejected by the host operator's allow/deny policy is
	// hidden from the cloud catalog entirely. The engine ALSO enforces
	// admission at run time, so a compromised portal trying to dispatch
	// a hidden id still gets a hard refusal; this filter just keeps
	// the UI honest.
	Admission *admission.Policy
	// EnforceSignatures advertises that this runner verifies a client
	// signature on every dispatch — the cloud disables its own dispatch to it.
	EnforceSignatures bool
}

// Build snapshots the current registry into a wire-shaped state
// advertisement.
func (b *StateBuilder) Build() RunnerStateMsg {
	hostname := b.Hostname
	if hostname == "" {
		if h, err := os.Hostname(); err == nil {
			hostname = h
		}
	}
	msg := RunnerStateMsg{
		Envelope:          Envelope{Type: MsgRunnerState, ProtocolVersion: ProtocolVersion},
		AgentID:           b.AgentID,
		Version:           b.Version,
		Hostname:          hostname,
		Group:             b.Group,
		Labels:            b.Labels,
		Packs:             map[string]PackInfo{},
		EnforceSignatures: b.EnforceSignatures,
	}
	if b.GetRegistry == nil {
		return msg
	}
	reg := b.GetRegistry()
	if reg == nil {
		return msg
	}
	for _, p := range reg.Packs() {
		info := PackInfo{Version: p.Version}
		if h, ok := reg.PackHash(p.ID); ok {
			info.Hash = h
		}
		msg.Packs[p.ID] = info
	}
	for _, a := range reg.Actions() {
		if ok, _ := b.Admission.Admit(a.ID); !ok {
			continue
		}
		msg.Actions = append(msg.Actions, descriptorFor(a))
	}
	return msg
}

func descriptorFor(a *actionspec.Action) ActionDescriptor {
	return ActionDescriptor{
		ID:          a.ID,
		PackID:      a.PackID,
		Title:       a.Title,
		Kind:        string(a.Kind),
		Risk:        string(a.Risk),
		Description: a.Description,
		SideEffects: a.SideEffects,
		Args:        a.Args,
		Limits: DescriptorLimits{
			DefaultTimeout: a.Execution.Timeout,
			TimeoutMin:     a.Execution.TimeoutMin,
			TimeoutMax:     a.Execution.TimeoutMax,
		},
		Output: DescriptorOutput{
			Parser:            a.Output.Parser,
			MaxStdoutBytes:    a.Output.MaxStdoutBytes,
			MaxStdoutBytesMin: a.Output.MaxStdoutBytesMin,
			MaxStdoutBytesMax: a.Output.MaxStdoutBytesMax,
			MaxStderrBytes:    a.Output.MaxStderrBytes,
			MaxStderrBytesMin: a.Output.MaxStderrBytesMin,
			MaxStderrBytesMax: a.Output.MaxStderrBytesMax,
		},
		Examples: a.Examples,
	}
}
