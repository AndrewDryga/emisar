package cloud

import (
	"os"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// StateBuilder constructs the RunnerStateMsg the runner ships on connect
// and on SIGHUP-driven re-advertisement. GetRegistry and GetVerifier are
// each called every Build() so post-reload state reflects the current pack
// set and the current trusted signing keys.
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
	// GetVerifier returns the dispatch verifier (nil = signature enforcement off). When it
	// enforces, Build advertises that this runner verifies a client signature
	// on every dispatch (so the cloud disables its own dispatch to it), plus
	// the trusted key ids and freshness window — derived live so a SIGHUP key
	// swap re-advertises the new set on the next Build.
	GetVerifier func() *signing.Verifier
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
		Envelope: Envelope{Type: MsgRunnerState, ProtocolVersion: ProtocolVersion},
		AgentID:  b.AgentID,
		Version:  b.Version,
		Hostname: hostname,
		Group:    b.Group,
		Labels:   b.Labels,
		Packs:    map[string]PackInfo{},
	}
	// Advertise enforcement + the trusted CA ids / freshness window only when
	// the live verifier enforces — meaningless metadata otherwise.
	if b.GetVerifier != nil {
		if v := b.GetVerifier(); v != nil && v.Enforces() {
			msg.EnforceSignatures = true
			msg.SigningCAIDs = v.CAIDs()
			msg.MaxAttestationAgeSeconds = int(v.MaxAge().Seconds())
		}
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
		// Risk ceiling: a too-risky action is hidden from the catalog (and
		// refused at dispatch, in the engine), so a read-only demo never shows
		// high/critical actions to the operator or the LLM.
		if ok, _ := b.Admission.AdmitRisk(a.Risk); !ok {
			continue
		}
		msg.Actions = append(msg.Actions, descriptorFor(a))
	}
	return msg
}

func descriptorFor(a *actionspec.Action) ActionDescriptor {
	return ActionDescriptor{
		ModelDescriptor: a.ModelDescriptor(),
		PackID:          a.PackID,
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
	}
}
