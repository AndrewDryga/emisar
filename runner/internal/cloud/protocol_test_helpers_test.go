package cloud

import (
	"encoding/json"
	"fmt"
)

func marshalRunActionMsg(m RunActionMsg) ([]byte, error) {
	raw := m.ArgsRaw
	if len(raw) == 0 {
		var err error
		raw, err = json.Marshal(m.Args)
		if err != nil {
			return nil, fmt.Errorf("marshal run_action args: %w", err)
		}
		if string(raw) == "null" {
			raw = json.RawMessage(`{}`)
		}
	}
	return json.Marshal(runActionMsgWire{
		Envelope: m.Envelope, ActionID: m.ActionID,
		ExpectedPackHash: m.ExpectedPackHash, PackRef: m.PackRef,
		Args: raw, Opts: m.Opts, Reason: m.Reason, OperationID: m.OperationID,
		Attestation: m.Attestation,
	})
}
