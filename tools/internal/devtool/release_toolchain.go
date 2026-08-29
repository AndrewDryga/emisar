package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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
	// The ARG defaults only feed the release build if BUILDER_IMAGE's tag is
	// interpolated FROM them. A hardcoded tag would pass the checks above while
	// building a different toolchain, so require the ${…} references and a pinned
	// @sha256 digest. Docker resolves the digest and ignores the tag, so the tag
	// is documentation and the digest is the real pin — this cannot prove the
	// digest matches the version (that needs a registry lookup at bump time), only
	// that the human-readable tag can never silently diverge from the ARGs.
	builder := firstSubmatch(dockerfile, `(?m)^ARG BUILDER_IMAGE="([^"]+)"`)
	if builder == "" {
		return fmt.Errorf("portal/Dockerfile does not define ARG BUILDER_IMAGE")
	}
	for _, ref := range []string{"${ELIXIR_VERSION}", "${OTP_VERSION}"} {
		if !strings.Contains(builder, ref) {
			return fmt.Errorf("portal/Dockerfile BUILDER_IMAGE does not interpolate %s; a hardcoded "+
				"tag lets the release toolchain drift from the ARG defaults this check verifies", ref)
		}
	}
	if firstSubmatch([]byte(builder), `@sha256:([0-9a-f]{64})`) == "" {
		return fmt.Errorf("portal/Dockerfile BUILDER_IMAGE is not digest-pinned (@sha256:<64 hex>); " +
			"the tag alone is mutable and is not what the release builds from")
	}
	// Hex and rebar3 have no .tool-versions entry, so the CI workflow's env is
	// their pin of record: CI installs exactly those versions for the portal gate
	// it runs, and the release image must build from the same ones. Hold the ARG
	// defaults to the workflow pins, well-formed, so bumping one side alone fails
	// here rather than only after a push. CI greps the Dockerfile for the same
	// agreement; reading the pin here makes it checkable without a registry lookup.
	for _, pin := range []struct{ arg, shape, pattern string }{
		{"HEX_VERSION", "a dotted version", `^[0-9]+(\.[0-9]+)+$`},
		{"REBAR3_VERSION", "a dotted version", `^[0-9]+(\.[0-9]+)+$`},
		{"REBAR3_SHA512", "a 128-character hex sha512", `^[0-9a-f]{128}$`},
	} {
		want, err := workflowPin(a.Root, pin.arg)
		if err != nil {
			return err
		}
		got := firstSubmatch(dockerfile, `(?m)^ARG `+pin.arg+`=(\S+)`)
		if got == "" {
			return fmt.Errorf("portal/Dockerfile does not default ARG %s", pin.arg)
		}
		if !regexp.MustCompile(pin.pattern).MatchString(got) {
			return fmt.Errorf("portal/Dockerfile ARG %s=%s is not %s", pin.arg, got, pin.shape)
		}
		if got != want {
			return fmt.Errorf("portal/Dockerfile defaults %s=%s, but the CI workflow pins %s; "+
				"CI installs its pin for the portal gate while the release image builds from the ARG default — bump both together",
				pin.arg, got, want)
		}
	}
	fmt.Fprintln(a.Out, "verified: BUILDER_IMAGE's tag derives from the .tool-versions toolchain and is digest-pinned, "+
		"and the hex/rebar3 ARG defaults match the CI workflow's pins "+
		"(digest-to-version correctness is confirmed against the registry at bump time)")
	return nil
}

// workflowPin reads a pinned env value from the CI workflow. Hex/rebar3 (portal
// image) and terraform/tflint (infra) have their version and checksum pinned
// there and are installed from it, so the workflow is the reference the gate
// holds the Dockerfile and .tool-versions to — the agreement CI greps for, now
// checkable on a workstation without a registry lookup.
func workflowPin(root, key string) (string, error) {
	workflow, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
	if err != nil {
		return "", err
	}
	value := firstSubmatch(workflow, `(?m)^\s*`+key+`:\s*"?([^"\s]+)"?`)
	if value == "" {
		return "", fmt.Errorf(".github/workflows/ci.yml does not pin %s", key)
	}
	return value, nil
}
