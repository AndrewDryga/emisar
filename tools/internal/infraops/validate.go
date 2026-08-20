package infraops

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

type cloudInitDocument struct {
	WriteFiles []struct {
		Path        string `yaml:"path"`
		Permissions string `yaml:"permissions"`
		Encoding    string `yaml:"encoding"`
		Content     string `yaml:"content"`
	} `yaml:"write_files"`
}

func terraformImage(path, name string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	pattern := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(name) + `\s*=\s*"([^"]+)"\s*$`)
	match := pattern.FindSubmatch(data)
	if match == nil {
		return "", fmt.Errorf("%s does not assign %s", path, name)
	}
	return string(match[1]), nil
}

func requirePinnedImage(image string) error {
	if !regexp.MustCompile(`@sha256:[0-9a-f]{64}$`).MatchString(image) {
		return fmt.Errorf("container image must use an immutable sha256 digest: %s", image)
	}
	if imageVersion(image) == "" {
		return fmt.Errorf("container image must keep a readable version tag: %s", image)
	}
	return nil
}

func imageVersion(image string) string {
	tag := strings.SplitN(image, "@", 2)[0]
	index := strings.LastIndex(tag, ":")
	if index < 0 || index < strings.LastIndex(tag, "/") || index == len(tag)-1 {
		return ""
	}
	return tag[index+1:]
}

func requireText(label, text string, needles ...string) error {
	for _, needle := range needles {
		if !strings.Contains(text, needle) {
			return fmt.Errorf("%s does not contain %q", label, needle)
		}
	}
	return nil
}

func forbidText(label, text string, needles ...string) error {
	for _, needle := range needles {
		if strings.Contains(text, needle) {
			return fmt.Errorf("%s must not contain %q", label, needle)
		}
	}
	return nil
}

func requireWriteFile(document cloudInitDocument, path, permissions string) (string, error) {
	var content string
	for _, entry := range document.WriteFiles {
		if entry.Path != path {
			continue
		}
		if content != "" {
			return "", fmt.Errorf("cloud-init writes %s more than once", path)
		}
		if entry.Permissions != permissions || entry.Encoding != "" {
			return "", fmt.Errorf(
				"cloud-init writes %s with permissions %s and encoding %q, want %s and plain text",
				path, entry.Permissions, entry.Encoding, permissions,
			)
		}
		content = entry.Content
	}
	if content == "" {
		return "", fmt.Errorf("cloud-init does not write %s", path)
	}
	return content, nil
}

func extractWriteFiles(
	document cloudInitDocument,
	destination string,
	baseNameOnly bool,
	include func(path, permissions string) bool,
) ([]string, error) {
	var paths []string
	for _, entry := range document.WriteFiles {
		if !include(entry.Path, entry.Permissions) {
			continue
		}
		content := []byte(entry.Content)
		if entry.Encoding == "b64" {
			decoded, err := base64.StdEncoding.DecodeString(entry.Content)
			if err != nil {
				return nil, fmt.Errorf("decoding %s: %w", entry.Path, err)
			}
			content = decoded
		}
		name := filepath.Base(entry.Path)
		if !baseNameOnly {
			name = strings.TrimPrefix(entry.Path, "/")
			name = strings.ReplaceAll(name, "/", "-")
		}
		path := filepath.Join(destination, name)
		for _, existing := range paths {
			if existing == path {
				return nil, fmt.Errorf("cloud-init paths collide at %s", path)
			}
		}
		if err := os.WriteFile(path, content, 0o755); err != nil {
			return nil, err
		}
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths, nil
}

func parseCloudInit(path string) (cloudInitDocument, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return cloudInitDocument{}, err
	}
	var document cloudInitDocument
	var node yaml.Node
	if err := yaml.Unmarshal(data, &node); err != nil {
		return document, fmt.Errorf("parsing %s: %w", path, err)
	}
	var rejectAliases func(*yaml.Node) error
	rejectAliases = func(node *yaml.Node) error {
		if node.Kind == yaml.AliasNode {
			return fmt.Errorf("YAML aliases are not allowed")
		}
		for _, child := range node.Content {
			if err := rejectAliases(child); err != nil {
				return err
			}
		}
		return nil
	}
	if err := rejectAliases(&node); err != nil {
		return document, fmt.Errorf("parsing %s: %w", path, err)
	}
	if err := node.Decode(&document); err != nil {
		return document, fmt.Errorf("parsing %s: %w", path, err)
	}
	return document, nil
}

func (a *App) cloudInitValidator(ctx context.Context) (bool, error) {
	if _, err := a.LookPath("cloud-init"); err == nil {
		return false, nil
	}
	if _, err := a.output(ctx, a.Root, nil, "docker", "build",
		"--quiet",
		"--tag=emisar/cloud-init-validator:dev",
		"--file="+filepath.Join(a.Root, "dev", "cloud-init", "Dockerfile"),
		filepath.Join(a.Root, "dev", "cloud-init")); err != nil {
		return false, fmt.Errorf("building the cloud-init validator: %w", err)
	}
	return true, nil
}

func (a *App) validateCloudInit(ctx context.Context, path string, containerized bool) error {
	if !containerized {
		return a.run(ctx, a.Root, nil, "cloud-init", "schema", "--config-file", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	command := a.command(ctx, a.Root, nil, "docker", "run", "--rm", "--interactive", "--read-only",
		"--cap-drop=ALL", "--security-opt=no-new-privileges",
		"--tmpfs", "/work:rw,nosuid,nodev,noexec,size=1m",
		"--entrypoint=/bin/sh", "emisar/cloud-init-validator:dev", "-c",
		"cat >/work/cloud-init.yaml && exec cloud-init schema --config-file /work/cloud-init.yaml")
	command.Stdin = file
	if err := command.Run(); err != nil {
		return fmt.Errorf("validating %s with cloud-init: %w", path, err)
	}
	return nil
}

func (a *App) validateTemplates(ctx context.Context) error {
	if err := a.require("docker", "terraform", "bash", "shellcheck"); err != nil {
		return err
	}
	containerizedCloudInit, err := a.cloudInitValidator(ctx)
	if err != nil {
		return err
	}
	proxyImage, err := terraformImage(filepath.Join(a.Infra, "compute.tf"), "cloud_sql_proxy_image")
	if err != nil {
		return err
	}
	gcloudImage, err := terraformImage(filepath.Join(a.Infra, "compute.tf"), "gcloud_image")
	if err != nil {
		return err
	}
	livebookImage, err := terraformImage(filepath.Join(a.Infra, "livebook.tf"), "livebook_image")
	if err != nil {
		return err
	}
	for _, image := range []string{proxyImage, gcloudImage, livebookImage} {
		if err := requirePinnedImage(image); err != nil {
			return err
		}
	}
	terraformIgnore, err := os.ReadFile(filepath.Join(a.Infra, ".terraformignore"))
	if err != nil {
		return err
	}
	if regexp.MustCompile(`(?m)^scripts/$`).Match(terraformIgnore) {
		return fmt.Errorf("infra/.terraformignore must not exclude nested runtime or pack scripts")
	}
	if !regexp.MustCompile(`(?m)^/scripts/$`).Match(terraformIgnore) {
		return fmt.Errorf("infra/.terraformignore must anchor the root scripts exclusion")
	}
	adminCallback := filepath.Join(a.Infra, "packs", "emisar-admin", "scripts", "callback.sh")
	if _, err := os.Stat(adminCallback); err != nil {
		return fmt.Errorf("private admin callback missing from the HCP upload input: %w", err)
	}
	proxyVersion, err := a.output(ctx, a.Root, nil, "docker", "run", "--rm", "--read-only",
		"--cap-drop=ALL", "--security-opt=no-new-privileges", proxyImage, "--version")
	if err != nil {
		return err
	}
	if !strings.Contains(string(proxyVersion), "cloud-sql-proxy version "+imageVersion(proxyImage)+"+container") {
		return fmt.Errorf("unexpected Cloud SQL Auth Proxy version: %s", proxyVersion)
	}
	gcloudVersion, err := a.output(ctx, a.Root, nil, "docker", "run", "--rm", "--network", "host",
		"--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
		"--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=64m", "--env", "CLOUDSDK_CONFIG=/tmp/gcloud",
		gcloudImage, "gcloud", "version")
	if err != nil {
		return err
	}
	if !strings.Contains(string(gcloudVersion), "Google Cloud SDK "+strings.TrimSuffix(imageVersion(gcloudImage), "-stable")) {
		return fmt.Errorf("unexpected Google Cloud CLI version: %s", gcloudVersion)
	}
	livebookVersion, err := a.output(ctx, a.Root, nil, "docker", "run", "--rm", "--read-only",
		"--cap-drop=ALL", "--security-opt=no-new-privileges", "--entrypoint", "/app/bin/livebook",
		livebookImage, "version")
	if err != nil {
		return err
	}
	if !strings.Contains(string(livebookVersion), "livebook "+imageVersion(livebookImage)) {
		return fmt.Errorf("unexpected Livebook version: %s", livebookVersion)
	}

	temp, err := os.MkdirTemp("", "emisar-infra-render-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	renderDir := filepath.Join(a.Infra, "tests", "render")
	state := filepath.Join(temp, "render.tfstate")
	if _, err := a.output(ctx, a.Root, nil, "terraform", "-chdir="+renderDir,
		"init", "-backend=false", "-input=false"); err != nil {
		return err
	}
	if _, err := a.output(ctx, a.Root, nil, "terraform", "-chdir="+renderDir,
		"apply", "-auto-approve", "-input=false", "-state="+state); err != nil {
		return err
	}
	renderedData, err := a.output(ctx, a.Root, nil, "terraform", "-chdir="+renderDir,
		"output", "-state="+state, "-raw", "cloud_init")
	if err != nil {
		return err
	}
	renderedPath := filepath.Join(temp, "cloud-init.yaml")
	if err := os.WriteFile(renderedPath, renderedData, 0o600); err != nil {
		return err
	}
	livebookData, err := a.output(ctx, a.Root, nil, "terraform", "-chdir="+renderDir,
		"output", "-state="+state, "-raw", "livebook_cloud_init")
	if err != nil {
		return err
	}
	livebookPath := filepath.Join(temp, "livebook-cloud-init.yaml")
	if err := os.WriteFile(livebookPath, livebookData, 0o600); err != nil {
		return err
	}
	renderedDocument, err := parseCloudInit(renderedPath)
	if err != nil {
		return err
	}
	beamBridge, err := requireWriteFile(
		renderedDocument, "/var/lib/emisar-admin-runner/beam.sh", "0444",
	)
	if err != nil {
		return err
	}
	livebookDocument, err := parseCloudInit(livebookPath)
	if err != nil {
		return err
	}
	for _, path := range []string{renderedPath, livebookPath} {
		if err := a.validateCloudInit(ctx, path, containerizedCloudInit); err != nil {
			return err
		}
	}

	rendered := string(renderedData)
	if err := requireText("Portal cloud-init", rendered,
		`ensure_image "`+proxyImage+`"`,
		`ensure_image "`+gcloudImage+`"`,
		"--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges "+proxyImage+" --private-ip --auto-iam-authn",
		"Wants=emisar-cloud-sql-proxy.service",
		"runner=/run/emisar-admin-runner/bin/emisar",
		"bundled_packs='linux-core debugging systemd-deep cloud-init docker nic time-sync elixir-beam'",
		"emisar-admin-runner-tfe-token",
		"inherit_env:", "- TFE_TOKEN",
		`- "gcp.*"`, `- "tfc.*"`,
		"cloud-init=0.1.12|sha256:d1225d74b75cf2bffb6ff61cb832a3086c3f23f66776b4d7138aa37776171222",
		"debugging=0.2.17|sha256:cfc2f6aa83108c16bb2256f79dd01cbd03c068c686f5d6ca8749882084b19775",
		"docker=0.2.17|sha256:f09ebfe9b5da673ecbfadd4d2d8a77b1ad2ec9af951c8c58ebeaaca21bdc0852",
		"elixir-beam=0.1.4|sha256:d47cc9856e3585b20564a245d0d508237f2f5378684e7ba190db43473ebd6acd",
		"gcp-certificates=0.1.0|sha256:da73325336f2d11cdff984948bf6f53fe34f43f1bce873c6e01e6a6fc38f792b",
		"gcp-cloudsql=0.3.0|sha256:45cbc52c0088f28a747d80cb2c71879232cb97e95aab65e15efcdd4840c30b32",
		"gcp-compute=0.2.0|sha256:8df5c0c0c759c0a491435e39bb00f91371f2711d54334a3114c097ad21c2c2b2",
		"gcp-dns=0.2.0|sha256:4163dda5066fe4553d38a94d9b1f8eca62595cf7246ee3ef7900de57251ad99b",
		"gcp-iam=0.1.0|sha256:c8bc2db792a56ae123ea865287e029a0ecf6e95e5790722dcae3ff01449d480b",
		"gcp-load-balancing=0.1.0|sha256:d43b24b0767cb62752eb368314fec257755880f6ea860c453a76bf8c3ca5820b",
		"gcp-monitoring=0.3.0|sha256:943bca4673613766ba4ccb593673ffda5d33a91a925aca6d1c02fc1232886c48",
		"gcp-networking=0.1.0|sha256:8aeca131aa12cc7ee244a1c5bb7663a7434919e7f8a8406cd9206d0b9b02062f",
		"gcp-storage=0.1.0|sha256:976ede94963f134ef0cca63eedd4bdb2dedde67d8e820feceac5a5a9c79a306b",
		"hcp-terraform=0.8.0|sha256:5d753dced1595977ce9ec640dea0b26057ce95d38a6dfbcc27b3a0f4e4fc2592",
		"linux-core=0.4.1|sha256:a5852885bec7b265c98bc897b6c45448d88c3cc92b098cd3d221b4c98e20edd4",
		"nic=0.1.1|sha256:fe4e1d8a7e8633d57d95197103c8260d7b1273106595bae24c70efcacf65956d",
		"sentry=0.1.0|sha256:8a33af4a63e08318ed0aad6afefbd3f5a1c84f9636e7a0de1f6a1ad902ef18ee",
		"systemd-deep=0.1.15|sha256:a39bcb7a8172275a5870bf1e69ee4c13b7289f36312a66778d231368e9afdfcd",
		"time-sync=0.1.9|sha256:717e790d5496ff76f9f5dad8fdb05aa08b476147d8e52a9a18579e14cf27f9b3",
		`"$runner" pack install "$pack_ref"`,
		`--hash "$expected_hash"`,
		"/var/lib/emisar-admin-runner/gcloud.sh",
		"/var/lib/emisar-admin-runner/beam.sh",
		`install -m 0755 /var/lib/emisar-admin-runner/beam.sh "$runner_bin_dir/beam-runtime"`,
		`ln -sfn beam-runtime "$runner_bin_dir/elixir"`,
		`ln -sfn beam-runtime "$runner_bin_dir/erl"`,
		`ln -sfn beam-runtime "$runner_bin_dir/epmd"`,
		"declared_dependencies='bash cloud-init curl docker ethtool jq ps ss systemctl'",
		`command -v "$dependency" >/dev/null`,
		"elixir --version >/dev/null",
		`erl -noshell -eval 'io:format("~s~n", [erlang:system_info(system_version)]), halt().' >/dev/null`,
		"epmd -names >/dev/null",
		"--tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m",
		`gcloud "$@"`,
		"x86_64|amd64) runner_arch=amd64",
		"aarch64|arm64) runner_arch=arm64",
		`release_tag="runner-v0.20.1"`,
		`release_name="emisar-0.20.1-linux-${runner_arch}"`,
		`release_base="https://emisar.dev/releases/runner/${release_tag}"`,
		`github_release_base="https://github.com/andrewdryga/emisar/releases/download/${release_tag}"`,
		`"${base}/${tarball}"`,
		`"${base}/SHA256SUMS"`,
		`fetch_release_files "$release_base"`,
		`fetch_release_files "$github_release_base"`,
		`actual_hash=$(sha256sum "${bundle_dir}/${tarball}"`,
		`[ "$actual_hash" = "$expected_hash" ]`,
		`install -m 0755 "${bundle_dir}/${release_name}/emisar" "${runner}.new"`,
		`"$runner" pack install "$bundle_pack"`,
		"emisar version 0.20.1",
		"docker exec emisar /app/bin/emisar pid",
		"test -r /var/lib/emisar-admin-runner/packs/emisar-admin/scripts/callback.sh",
		"rm -rf /var/lib/emisar-admin-runner/packs/firewall",
		`"$runner" pack list --packs-dir /var/lib/emisar-admin-runner/packs`,
		`exec "$runner" connect --config /var/lib/emisar-admin-runner/config.yaml`,
		"Requires=emisar.service", "PartOf=emisar.service",
		"group: emisar-admin", "max_risk: critical",
		"- /var/lib/emisar-admin-runner/packs", `- "beam.*"`,
		"/var/lib/emisar-admin-runner/packs/emisar-admin/pack.yaml",
		// The broad glob allows admit two actions that return this root,
		// portal-colocated host's own secrets. Pin the subtraction so a later
		// allow-list edit cannot quietly restore them.
		"deny:", `- "debugging.pid_environ"`, `- "docker.inspect"`,
	); err != nil {
		return err
	}
	if err := forbidText("Portal cloud-init", rendered,
		"firewall=0.1.12|", `- "fw.*"`,
	); err != nil {
		return err
	}
	if len(renderedData) > 262144 {
		return fmt.Errorf("rendered cloud-init exceeds Compute Engine's per-value metadata limit")
	}
	// Every pack this runner installs is installed WITH its expected hash. An
	// install by bare name pulls whatever the registry currently serves onto the
	// disk of a runner admitted at max_risk: critical, so the pinned form is not
	// merely preferred here — the unpinned one must not exist.
	unpinnedPack := regexp.MustCompile(`pack install "\$(pack|bundle_pack)"(?:[^\n]*\\\n)*[^\n]*`)
	for _, install := range unpinnedPack.FindAllString(string(renderedData), -1) {
		// The bundle path is the offline copy shipped inside the verified release
		// tarball, so it carries the runner's own integrity, not the registry's.
		if !strings.Contains(install, "--hash") && !strings.Contains(install, "bundle_pack") {
			return fmt.Errorf("the admin runner must install packs with --hash, got: %s", install)
		}
	}
	coupledProxy := regexp.MustCompile(`(?m)^\s+(Requires|BindsTo|PartOf|Requisite|PropagatesStopTo)=.*emisar-cloud-sql-proxy`)
	if coupledProxy.Match(renderedData) {
		return fmt.Errorf("the portal service must not restart with the Cloud SQL Auth Proxy")
	}
	// The Cloud SQL proxy, the gcloud helper and Livebook were all asserted to be
	// confined; the internet-facing container was not, and so quietly ran with
	// every capability. Assert the one that faces the internet too — against ITS
	// OWN command, continuations and all. Searching the whole document would pass
	// on the proxy's flags a few lines up and prove nothing.
	portalRun := regexp.MustCompile(`(?s)docker run --rm --name emisar (?:[^\n]*\\\n)*[^\n]*`)
	match := portalRun.Find(renderedData)
	if match == nil {
		return fmt.Errorf("rendered cloud-init no longer starts the portal container")
	}
	for _, flag := range []string{"--cap-drop=ALL", "--security-opt=no-new-privileges"} {
		if !strings.Contains(string(match), flag) {
			return fmt.Errorf("the portal container must run with %s", flag)
		}
	}

	if err := a.validateAdminCallback(ctx, temp); err != nil {
		return err
	}
	probePath := filepath.Join(temp, "pitr-probe.sh")
	probe := strings.NewReplacer(
		"{{CONNECTION_NAME}}", "test-project:us-central1:drill",
		"{{IAM_USER}}", "drill@test-project.iam",
	).Replace(probeStartup)
	if err := os.WriteFile(probePath, []byte(probe), 0o755); err != nil {
		return err
	}
	// Each extraction is filtered, and an empty result is indistinguishable from
	// "everything passed" downstream: bash -n and shellcheck over zero files
	// succeed. A move to runcmd delivery, or a permission change from 0755,
	// would silently drop every script from validation while every requireText
	// literal still matched the raw document. Assert there is something to check.
	portalScripts, err := extractWriteFiles(renderedDocument, temp, false,
		func(path, _ string) bool { return strings.HasSuffix(path, ".sh") })
	if err != nil {
		return err
	}
	if len(portalScripts) == 0 {
		return fmt.Errorf("rendered portal cloud-init delivered no .sh files to validate")
	}
	if err := a.validateAdminBeamBridge(ctx, temp, beamBridge); err != nil {
		return err
	}
	livebookScriptsDir := filepath.Join(temp, "livebook-scripts")
	notebooksDir := filepath.Join(temp, "livebook-notebooks")
	if err := os.MkdirAll(livebookScriptsDir, 0o700); err != nil {
		return err
	}
	// The Livebook container reads these as its own non-root user, so 0700
	// (owner-only) makes the bind mount look like an empty directory.
	if err := os.MkdirAll(notebooksDir, 0o755); err != nil {
		return err
	}
	livebookScripts, err := extractWriteFiles(livebookDocument, livebookScriptsDir, true,
		func(_ string, permissions string) bool { return permissions == "0755" })
	if err != nil {
		return err
	}
	if len(livebookScripts) == 0 {
		return fmt.Errorf("rendered Livebook cloud-init delivered no 0755 scripts to validate")
	}
	renderedNotebooks, err := extractWriteFiles(livebookDocument, notebooksDir, true,
		func(path, _ string) bool { return strings.HasSuffix(path, ".livemd") })
	if err != nil {
		return err
	}
	sourceNotebooks, err := filepath.Glob(filepath.Join(a.Infra, "runtime", "livebook", "notebooks", "*.livemd"))
	if err != nil {
		return err
	}
	// filepath.Glob returns (nil, nil) when nothing matches, so a moved notebook
	// directory made this 0 == 0 and every per-notebook comparison below a no-op.
	if len(sourceNotebooks) == 0 {
		return fmt.Errorf("no source notebooks found under infra/runtime/livebook/notebooks")
	}
	if len(sourceNotebooks) != len(renderedNotebooks) {
		return fmt.Errorf("rendered %d notebooks, expected %d", len(renderedNotebooks), len(sourceNotebooks))
	}
	for _, source := range sourceNotebooks {
		expected, err := os.ReadFile(source)
		if err != nil {
			return err
		}
		renderedPath := filepath.Join(notebooksDir, filepath.Base(source))
		actual, err := os.ReadFile(renderedPath)
		if err != nil {
			return err
		}
		if string(actual) != string(expected) {
			return fmt.Errorf("rendered notebook differs from %s", source)
		}
	}
	if err := a.validateLivebook(ctx, livebookImage, proxyImage, notebooksDir, string(livebookData)); err != nil {
		return err
	}
	scripts := append(portalScripts, livebookScripts...)
	scripts = append(scripts, probePath)
	for _, script := range scripts {
		if err := a.run(ctx, a.Root, nil, "bash", "-n", script); err != nil {
			return err
		}
		if err := a.run(ctx, a.Root, nil, "shellcheck", script); err != nil {
			return err
		}
	}
	return validateMTASTS(filepath.Join(a.Infra, "runtime", "mta-sts", "policy.txt"))
}

func (a *App) validateAdminCallback(ctx context.Context, temp string) error {
	mockBin := filepath.Join(temp, "mock-bin")
	if err := os.MkdirAll(mockBin, 0o700); err != nil {
		return err
	}
	mock := `#!/bin/sh
[ "$1" = exec ] || exit 2
shift
[ "$1" = emisar ] && [ "$2" = /app/bin/emisar ] && [ "$3" = rpc ]
case "$4" in *"Emisar.Admin.execute(action_id, args)"*) ;; *) exit 3 ;; esac
case "$4" in *'System.fetch_env!'*|*'System.get_env('*|*'--env'*) exit 4 ;; esac
case "$4" in *'Base.decode64!("ZW1pc2FyLmFkbWluLmFjY291bnQuc2hvdw==")'*) ;; *) exit 5 ;; esac
case "$4" in *'Enum.map(["YWNjb3VudD1kZW1vPXdlc3Q="], &Base.decode64!/1)'*) ;; *) exit 6 ;; esac
if [ "${MOCK_RPC_ERROR:-0}" = 1 ]; then
  printf '__EMISAR_ADMIN_ERROR__{"ok":false,"error":"not_found"}\n'
else
  printf '__EMISAR_ADMIN_OK__{"ok":true,"result":{"release":"test"}}\n'
fi
`
	if err := os.WriteFile(filepath.Join(mockBin, "docker"), []byte(mock), 0o755); err != nil {
		return err
	}
	callback := filepath.Join(a.Infra, "packs", "emisar-admin", "scripts", "callback.sh")
	pathEnv := mockBin + string(os.PathListSeparator) + os.Getenv("PATH")
	output, err := a.output(ctx, a.Root, map[string]string{"PATH": pathEnv},
		"/bin/sh", callback, "emisar.admin.account.show", "account=demo=west")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != `{"ok":true,"result":{"release":"test"}}` {
		return fmt.Errorf("unexpected admin RPC output: %s", output)
	}
	command := a.command(ctx, a.Root, map[string]string{"PATH": pathEnv, "MOCK_RPC_ERROR": "1"},
		"/bin/sh", callback, "emisar.admin.account.show", "account=demo=west")
	command.Stdout = nil
	command.Stderr = nil
	failure, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(failure), `"error":"not_found"`) {
		return fmt.Errorf("admin RPC domain error did not fail correctly: %s", failure)
	}
	return nil
}

func (a *App) validateAdminBeamBridge(ctx context.Context, temp, bridgeScript string) error {
	bridgeBin := filepath.Join(temp, "beam-bridge-bin")
	mockBin := filepath.Join(temp, "beam-bridge-mock-bin")
	if err := os.MkdirAll(bridgeBin, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(mockBin, 0o700); err != nil {
		return err
	}
	bridge := filepath.Join(bridgeBin, "beam-runtime")
	if err := os.WriteFile(bridge, []byte(bridgeScript), 0o755); err != nil {
		return err
	}
	for _, name := range []string{"elixir", "erl", "epmd"} {
		if err := os.Symlink("beam-runtime", filepath.Join(bridgeBin, name)); err != nil {
			return err
		}
	}

	mock := `#!/bin/sh
[ "$#" -eq 5 ] && [ "$1" = exec ] && [ "$2" = emisar ] && \
  [ "$3" = /app/bin/emisar ] && [ "$4" = rpc ] || exit 10
printf '%s\n' "$5" >>"$BEAM_BRIDGE_CALLS"
	case "$5" in
	  'otp = :erlang.system_info(:otp_release) |> List.to_string(); erts = :erlang.system_info(:version) |> List.to_string(); build = System.build_info(); IO.puts("Erlang/OTP #{otp} [erts-#{erts}]"); IO.puts("Elixir #{build.build}")')
	    printf 'Erlang/OTP 29 [erts-17.0.3]\nElixir 1.20.2 (compiled with Erlang/OTP 29)\n'
    ;;
  'IO.puts(:erlang.system_info(:system_version) |> List.to_string())')
    printf 'Erlang/OTP 29 [erts-17.0.3]\n'
    ;;
	  'case :erl_epmd.names() do {:ok, names} -> IO.puts("epmd: up and running on port 4369 with data:"); Enum.each(names, fn {name, port} -> IO.puts("name #{List.to_string(name)} at port #{port}") end); {:error, reason} -> raise "epmd query failed: #{inspect(reason)}" end')
	    printf 'epmd: up and running on port 4369 with data:\nname emisar at port 9100\n'
    ;;
  *) exit 11 ;;
esac
`
	if err := os.WriteFile(filepath.Join(mockBin, "docker"), []byte(mock), 0o755); err != nil {
		return err
	}
	calls := filepath.Join(temp, "beam-bridge-calls")
	env := map[string]string{
		"BEAM_BRIDGE_CALLS": calls,
		"PATH":              mockBin + string(os.PathListSeparator) + "/usr/bin:/bin",
	}
	accepted := []struct {
		tool string
		args []string
		want string
	}{
		{tool: "elixir", args: []string{"--version"}, want: "Elixir 1.20.2"},
		{
			tool: "erl",
			args: []string{"-noshell", "-eval", `io:format("~s~n", [erlang:system_info(system_version)]), halt().`},
			want: "Erlang/OTP 29 [erts-17.0.3]",
		},
		{tool: "epmd", args: []string{"-names"}, want: "name emisar at port 9100"},
	}
	for _, test := range accepted {
		output, err := a.output(ctx, a.Root, env, filepath.Join(bridgeBin, test.tool), test.args...)
		if err != nil {
			return fmt.Errorf("admin BEAM bridge %s: %w", test.tool, err)
		}
		if !strings.Contains(string(output), test.want) {
			return fmt.Errorf("admin BEAM bridge %s returned %q", test.tool, output)
		}
	}
	before, err := os.ReadFile(calls)
	if err != nil {
		return err
	}
	for _, test := range []struct {
		tool string
		args []string
	}{
		{tool: "elixir", args: []string{"-e", "System.stop()"}},
		{tool: "erl", args: []string{"-noshell", "-eval", "halt()."}},
		{tool: "epmd", args: []string{"-kill"}},
	} {
		if _, err := a.output(ctx, a.Root, env, filepath.Join(bridgeBin, test.tool), test.args...); err == nil {
			return fmt.Errorf("admin BEAM bridge accepted arbitrary %s arguments", test.tool)
		}
	}
	after, err := os.ReadFile(calls)
	if err != nil {
		return err
	}
	if string(after) != string(before) {
		return fmt.Errorf("rejected admin BEAM invocation still reached docker")
	}
	return nil
}

func (a *App) validateLivebook(
	ctx context.Context,
	livebookImage, proxyImage, notebooksDir, rendered string,
) error {
	eval := `
files = Path.wildcard("/notebooks/*.livemd")
files == [] && raise "no Livebook notebooks rendered"
Enum.each(files, fn file ->
  {notebook, %{warnings: warnings}} =
    file |> File.read!() |> Livebook.LiveMarkdown.notebook_from_livemd()
  warnings != [] && raise "#{Path.basename(file)}: #{inspect(warnings)}"
  notebook
  |> Livebook.Notebook.Export.Elixir.notebook_to_elixir()
  |> Code.string_to_quoted!()
end)
`
	if err := a.run(ctx, a.Root, nil, "docker", "run", "--rm", "--read-only",
		"--cap-drop=ALL", "--security-opt=no-new-privileges",
		"--tmpfs", "/data:rw,nosuid,nodev,size=64m",
		"--mount", "type=bind,src="+notebooksDir+",dst=/notebooks,readonly",
		"--entrypoint", "/app/bin/livebook", livebookImage, "eval", eval); err != nil {
		return err
	}
	readmeData, err := os.ReadFile(filepath.Join(a.Infra, "README.md"))
	if err != nil {
		return err
	}
	if err := requireText("Livebook cloud-init", rendered,
		`ensure_image "`+livebookImage+`"`, `ensure_image "`+proxyImage+`"`,
		"LIVEBOOK_IDENTITY_PROVIDER=google_iap:", "LIVEBOOK_TOKEN_ENABLED=false",
		"LIVEBOOK_NODE=livebook@", "PGOPTIONS=-c default_transaction_read_only=on",
		`install -d -o 1000 -g 1000 -m 0750 "$mountpoint/.livebook"`,
		`if [ ! -e "$destination" ]; then`, "product_analytics.exs",
		"--user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges",
		"--tmpfs /app/tmp:rw,nosuid,nodev,size=64m",
		"--tmpfs /home/livebook:rw,exec,nosuid,nodev,size=512m",
		"--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges "+proxyImage+" --private-ip --auto-iam-authn",
	); err != nil {
		return err
	}
	if err := forbidText("Livebook cloud-init", rendered, "LIVEBOOK_PASSWORD", "LIVEBOOK_CLUSTER="); err != nil {
		return err
	}
	if err := requireText("infra README", string(readmeData),
		"/data/notebooks/Emisar Product Analytics",
		`System.cmd("/bin/bash", ["/opt/emisar/list-portal-nodes"])`,
	); err != nil {
		return err
	}
	loadBalancer, err := os.ReadFile(filepath.Join(a.Infra, "load_balancer.tf"))
	if err != nil {
		return err
	}
	if !strings.Contains(string(loadBalancer), "/public/health") {
		return fmt.Errorf("load_balancer.tf lacks the Livebook public health path")
	}
	probe, err := a.output(ctx, a.Root, nil, "docker", "run", "--rm", "--read-only",
		"--user", "1000:1000", "--cap-drop=ALL", "--security-opt=no-new-privileges",
		"--tmpfs", "/home/livebook:rw,exec,nosuid,nodev,size=512m",
		"--entrypoint", "/bin/sh", livebookImage, "-c",
		`probe=/home/livebook/mix-install-exec-probe
printf '#!/bin/sh\nprintf livebook-home-exec-ok\n' >"$probe"
chmod 0700 "$probe"
exec "$probe"`)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(probe)) != "livebook-home-exec-ok" {
		return fmt.Errorf("the Livebook home exec probe returned %q", probe)
	}
	return nil
}

func validateMTASTS(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	required := []string{
		"version: STSv1", "mode: testing", "mx: aspmx.l.google.com",
		"mx: *.aspmx.l.google.com",
	}
	text := string(data)
	for _, line := range required {
		if !regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(line) + `$`).MatchString(text) {
			return fmt.Errorf("%s lacks %q", path, line)
		}
	}
	if !regexp.MustCompile(`(?m)^max_age: [1-9][0-9]*$`).MatchString(text) {
		return fmt.Errorf("%s has no positive max_age", path)
	}
	return nil
}
