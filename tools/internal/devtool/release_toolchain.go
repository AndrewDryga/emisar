package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// The portal release image builds from portal/Dockerfile's digest-pinned
// BUILDER_IMAGE, so its ELIXIR_VERSION and OTP_VERSION defaults are the real
// toolchain pin — a `--build-arg` override only rewrites the tag in front of
// the digest, which Docker ignores. Nothing tied those defaults to
// .tool-versions, so a toolchain bump upgraded dev and CI while the release
// image silently kept shipping the old one.
func (a *App) checkReleaseToolchainPins() error {
	pins, err := readToolVersions(filepath.Join(a.Root, ".tool-versions"))
	if err != nil {
		return fmt.Errorf("read pinned development tools: %w", err)
	}
	elixir, _, _ := strings.Cut(pins["elixir"], "-otp-")
	erlang := pins["erlang"]
	if elixir == "" || erlang == "" {
		return fmt.Errorf(".tool-versions does not pin elixir and erlang")
	}
	dockerfile, err := os.ReadFile(filepath.Join(a.Root, "portal", "Dockerfile"))
	if err != nil {
		return err
	}
	for _, pin := range []struct{ arg, want string }{
		{"ELIXIR_VERSION", elixir},
		{"OTP_VERSION", erlang},
	} {
		got := firstSubmatch(dockerfile, `(?m)^ARG `+pin.arg+`=(\S+)`)
		if got == "" {
			return fmt.Errorf("portal/Dockerfile does not default ARG %s", pin.arg)
		}
		if got != pin.want {
			return fmt.Errorf("portal/Dockerfile defaults %s=%s, but .tool-versions pins %s; "+
				"update the ARG default AND the BUILDER_IMAGE digest together — the digest is "+
				"what the release actually builds from", pin.arg, got, pin.want)
		}
	}
	fmt.Fprintln(a.Out, "verified: the portal release image defaults to the .tool-versions toolchain")
	return nil
}
