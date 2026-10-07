package cloud

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/actionhost"
	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const maxRunnerStateBytes = 2 << 20

// maxDegradedReasonBytes bounds one degraded pack's load-failure reason on
// the wire — the full detail stays in the host log and doctor.
const maxDegradedReasonBytes = 500

func boundDegradedReason(reason string) string {
	if len(reason) <= maxDegradedReasonBytes {
		return reason
	}
	// Cut on a rune boundary so a truncated reason stays valid UTF-8 JSON.
	cut := maxDegradedReasonBytes
	for cut > 0 && !utf8.RuneStart(reason[cut]) {
		cut--
	}
	return reason[:cut] + "…"
}

// StateBuilder constructs the RunnerStateMsg the runner ships on connect
// and on SIGHUP-driven re-advertisement. GetRegistry and GetVerifier are
// each called every Build() so post-reload state reflects the current pack
// set and the current trusted signing keys.
type StateBuilder struct {
	Version     string
	Hostname    string
	Group       string
	Labels      map[string]string
	GetRegistry func() *packs.Registry
	// GetAdmission snapshots mutable host eligibility once per Build. All loaded
	// descriptors remain advertised for complete trusted-manifest comparison.
	// The engine independently enforces the current policy at dispatch.
	GetAdmission func() *admission.Policy
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
	// Packs the loader skipped ride along so the cloud can say "pack X failed
	// to load on runner Y" instead of the pack silently missing from the
	// catalog. Basename only (the manifest may not have parsed, so no id is
	// guaranteed) and a bounded reason — this crosses the wire and renders in
	// the console.
	for _, degraded := range reg.Degraded() {
		msg.DegradedPacks = append(msg.DegradedPacks, DegradedPackState{
			Pack:   filepath.Base(degraded.Dir),
			Reason: boundDegradedReason(degraded.Reason),
		})
	}
	var policy *admission.Policy
	if b.GetAdmission != nil {
		policy = b.GetAdmission()
	}
	for _, a := range reg.Actions() {
		descriptor := descriptorFor(a)
		idAllowed, _ := policy.Admit(a.ID)
		riskAllowed, _ := policy.AdmitRisk(a.Risk)
		descriptor.AdmissionAllowed = idAllowed && riskAllowed
		msg.Actions = append(msg.Actions, descriptor)
	}
	return msg
}

func validateRunnerStateSize(msg RunnerStateMsg) error {
	encoded, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode runner_state: %w", err)
	}
	if len(encoded) > maxRunnerStateBytes {
		return fmt.Errorf(
			"runner_state is %d bytes; maximum is %d bytes: reduce installed packs",
			len(encoded), maxRunnerStateBytes,
		)
	}
	return nil
}

func descriptorFor(a *actionspec.Action) ActionDescriptor {
	primaryExecutableAvailable := actionhost.PrimaryExecutableAvailable(a)
	missingExecutable := ""
	if !primaryExecutableAvailable {
		missingExecutable = actionhost.PrimaryExecutable(a)
	}
	return ActionDescriptor{
		ModelDescriptor:            a.ModelDescriptor(),
		PackID:                     a.PackID,
		PrimaryExecutableAvailable: primaryExecutableAvailable,
		MissingExecutable:          missingExecutable,
	}
}
