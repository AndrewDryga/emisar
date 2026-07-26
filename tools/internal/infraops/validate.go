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
	livebookImage, err := terraformImage(filepath.Join(a.Infra, "livebook.tf"), "livebook_image")
	if err != nil {
		return err
	}
	for _, image := range []string{proxyImage, livebookImage} {
		if err := requirePinnedImage(image); err != nil {
			return err
		}
	}
	proxyVersion, err := a.output(ctx, a.Root, nil, "docker", "run", "--rm", "--read-only",
		"--cap-drop=ALL", "--security-opt=no-new-privileges", proxyImage, "--version")
	if err != nil {
		return err
	}
	if !strings.Contains(string(proxyVersion), "cloud-sql-proxy version "+imageVersion(proxyImage)+"+container") {
		return fmt.Errorf("unexpected Cloud SQL Auth Proxy version: %s", proxyVersion)
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
		"--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges "+proxyImage+" --private-ip --auto-iam-authn",
		"Wants=emisar-cloud-sql-proxy.service",
		"runner=/run/emisar-admin-runner/bin/emisar",
		"BIN_DIR=/run/emisar-admin-runner/bin",
		"http://127.0.0.1:4000/install.sh",
		`/bin/bash "$installer"`,
		"required_packs='linux-core debugging systemd-deep cloud-init docker firewall nic time-sync elixir-beam'",
		`--version "0.14.0"`, "--no-service", "emisar version 0.14.0",
		"docker exec emisar /app/bin/emisar pid",
		"test -r /var/lib/emisar-admin-runner/packs/emisar-admin/scripts/callback.sh",
		`"$runner" pack install "$pack"`,
		`"$runner" pack list --packs-dir /var/lib/emisar-admin-runner/packs`,
		`exec "$runner" connect --config /var/lib/emisar-admin-runner/config.yaml`,
		"Requires=emisar.service", "PartOf=emisar.service",
		"group: emisar-admin", "max_risk: critical",
		"- /var/lib/emisar-admin-runner/packs", `- "beam.*"`,
		"/var/lib/emisar-admin-runner/packs/emisar-admin/pack.yaml",
	); err != nil {
		return err
	}
	if len(renderedData) > 262144 {
		return fmt.Errorf("rendered cloud-init exceeds Compute Engine's per-value metadata limit")
	}
	coupledProxy := regexp.MustCompile(`(?m)^\s+(Requires|BindsTo|PartOf|Requisite|PropagatesStopTo)=.*emisar-cloud-sql-proxy`)
	if coupledProxy.Match(renderedData) {
		return fmt.Errorf("Portal service must not restart with the Cloud SQL Auth Proxy")
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
	portalScripts, err := extractWriteFiles(renderedDocument, temp, false,
		func(path, _ string) bool { return strings.HasSuffix(path, ".sh") })
	if err != nil {
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
	renderedNotebooks, err := extractWriteFiles(livebookDocument, notebooksDir, true,
		func(path, _ string) bool { return strings.HasSuffix(path, ".livemd") })
	if err != nil {
		return err
	}
	sourceNotebooks, err := filepath.Glob(filepath.Join(a.Infra, "runtime", "livebook", "notebooks", "*.livemd"))
	if err != nil {
		return err
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
		return fmt.Errorf("Livebook home exec probe returned %q", probe)
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
