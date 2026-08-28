package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// The e2e stack exists to demonstrate the coordinated release the portal calls
// current, and it stamps those versions into the runner and bridge binaries by
// hand. Nothing tied the two, and the bridge had already drifted four minors
// behind — pinned at mcp_minimum, so the stack demonstrated the oldest build
// still accepted rather than the one customers get, and a minimum bump would
// have made it non-compliant with no test noticing.
func (a *App) checkComposeVersionsMatchCompat() error {
	config, err := os.ReadFile(filepath.Join(a.Root, "portal", "config", "config.exs"))
	if err != nil {
		return err
	}
	compose, err := os.ReadFile(filepath.Join(a.Root, "docker-compose.yml"))
	if err != nil {
		return err
	}
	for _, pair := range []struct{ setting, buildArg string }{
		{"runner_current", "RUNNER_VERSION"},
		{"mcp_current", "MCP_VERSION"},
	} {
		want := firstSubmatch(config, `(?m)^\s*`+pair.setting+`:\s*"([^"]+)"`)
		if want == "" {
			return fmt.Errorf("portal/config/config.exs does not set %s", pair.setting)
		}
		got := firstSubmatch(compose, `(?m)^\s*`+pair.buildArg+`:\s*"([^"]+)"`)
		if got == "" {
			return fmt.Errorf("docker-compose.yml does not set the %s build arg", pair.buildArg)
		}
		if got != want {
			return fmt.Errorf("docker-compose.yml builds %s %s, but the portal's %s is %s; "+
				"the stack must run the coordinated release it demonstrates", pair.buildArg, got, pair.setting, want)
		}
	}
	fmt.Fprintln(a.Out, "verified: the e2e stack builds the runner and bridge versions Emisar.Compat calls current")
	return nil
}

func firstSubmatch(data []byte, pattern string) string {
	match := regexp.MustCompile(pattern).FindSubmatch(data)
	if match == nil {
		return ""
	}
	return string(match[1])
}
