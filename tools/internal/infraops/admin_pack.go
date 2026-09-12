package infraops

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.yaml.in/yaml/v3"
)

// callback.sh drops the action id and refuses more than four remaining
// arguments, so an action with a sixth argv entry passes pack validation,
// deploys, and only fails when an operator runs it mid-incident. The ceiling
// belongs where the author can see it.
const adminActionArgvCeiling = 5

// adminAction is the slice of an action spec this package enforces itself: the
// id the loader's errors name, and the script and argv the argv ceiling bounds.
// Everything else about the schema belongs to the runner's own loader — see
// validateAdminPack.
type adminAction struct {
	File      string `yaml:"-"`
	ID        string `yaml:"id"`
	Execution struct {
		Script struct {
			Path string `yaml:"path"`
		} `yaml:"script"`
		Argv []string `yaml:"argv"`
	} `yaml:"execution"`
}

// validateAdminPack holds the private administration pack to the same schema an
// admin-runner boot holds it to.
//
// The pack lives outside packs/, so `./run gate packs` never globs it and
// `./run pack check` cannot resolve it; cloud-init ships the directory verbatim
// with no pin or hash behind it. Until this ran, the first thing to parse these
// specs was `"$runner" pack list` during boot (runtime/admin-runner/start.sh) —
// a production boot, on the host whose erase actions are risk: critical. A bad
// duration, an invalid risk or parser, a malformed arg validation, or an argv
// template naming an arg no action declares all passed both gates and failed
// there.
//
// Validation therefore runs the runner built from THIS tree rather than a
// second reading of the schema: the loader's checks that catch the template and
// semantic classes live in runner/internal/packs, which no other module may
// import, so any re-implementation here would be a strictly weaker subset that
// drifts. `./run gate packs` validates the public catalog exactly this way.
func (a *App) validateAdminPack(ctx context.Context, pack string) error {
	// bin/ is ignored, so a fresh checkout — every CI run — has none.
	if err := os.MkdirAll(filepath.Join(a.Root, "bin"), 0o755); err != nil {
		return err
	}
	binary := filepath.Join(a.Root, "bin", "emisar")
	if err := a.run(ctx, filepath.Join(a.Root, "runner"), nil,
		"go", "build", "-trimpath", "-o", binary, "."); err != nil {
		return fmt.Errorf("building the runner to validate %s: %w", filepath.Base(pack), err)
	}
	return a.validateAdminPackWith(ctx, binary, pack)
}

// validateAdminPackWith takes the runner binary as an argument so a test can
// build it once and then hold several pack fixtures to it.
func (a *App) validateAdminPackWith(ctx context.Context, binary, pack string) error {
	actions, err := readAdminActions(pack)
	if err != nil {
		return err
	}
	report, err := a.output(ctx, a.Root, nil, binary, "pack", "validate", pack)
	if err != nil {
		return adminPackSpecError(actions, err)
	}
	fmt.Fprint(a.Out, string(report))
	if err := checkAdminActionsDeclared(pack, actions); err != nil {
		return err
	}
	return checkAdminActionArgvCeiling(actions)
}

// readAdminActions decodes every action YAML in the pack's actions directory,
// in directory order.
func readAdminActions(pack string) ([]adminAction, error) {
	entries, err := os.ReadDir(filepath.Join(pack, "actions"))
	if err != nil {
		return nil, err
	}
	var actions []adminAction
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".yaml") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(pack, "actions", entry.Name()))
		if err != nil {
			return nil, err
		}
		action := adminAction{File: entry.Name()}
		if err := yaml.Unmarshal(data, &action); err != nil {
			return nil, fmt.Errorf("reading %s: %w", entry.Name(), err)
		}
		actions = append(actions, action)
	}
	return actions, nil
}

// checkAdminActionsDeclared refuses an action file pack.yaml does not list. The
// runner loads exactly the declared set, so an undeclared file is inert: it
// reviews, deploys, and reads in the repository as a capability this host has,
// while the action simply does not exist on it. The loader cannot report this —
// a file it was never pointed at is not an error to it — and the surface going
// quietly missing here is emisar's own incident response.
func checkAdminActionsDeclared(pack string, actions []adminAction) error {
	data, err := os.ReadFile(filepath.Join(pack, "pack.yaml"))
	if err != nil {
		return err
	}
	var manifest struct {
		Actions []string `yaml:"actions"`
	}
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("reading pack.yaml: %w", err)
	}
	declared := make(map[string]struct{}, len(manifest.Actions))
	for _, relative := range manifest.Actions {
		declared[relative] = struct{}{}
	}
	for _, action := range actions {
		if _, ok := declared["actions/"+action.File]; !ok {
			return fmt.Errorf("actions/%s is not declared in pack.yaml, so the runner never loads it", action.File)
		}
	}
	return nil
}

func checkAdminActionArgvCeiling(actions []adminAction) error {
	for _, action := range actions {
		if !strings.HasSuffix(action.Execution.Script.Path, "callback.sh") {
			continue
		}
		if len(action.Execution.Argv) > adminActionArgvCeiling {
			return fmt.Errorf("%s passes %d argv entries; callback.sh accepts the action id plus at most %d arguments",
				action.File, len(action.Execution.Argv), adminActionArgvCeiling-1)
		}
	}
	return nil
}

// adminPackSpecError names the file an author has to open. The loader reports
// the action by id ("action emisar.admin.account.show: invalid risk"), and an id
// is not a file name here — support_set_slack_channel.yaml declares
// emisar.admin.support.set_slack_channel. The longest matching id wins, so a
// future id that is a prefix of another cannot claim the wrong file.
func adminPackSpecError(actions []adminAction, err error) error {
	message := err.Error()
	file := ""
	matched := 0
	for _, action := range actions {
		if action.ID == "" || len(action.ID) <= matched || !strings.Contains(message, action.ID) {
			continue
		}
		file, matched = action.File, len(action.ID)
	}
	if file == "" {
		return err
	}
	return fmt.Errorf("actions/%s: %w", file, err)
}
