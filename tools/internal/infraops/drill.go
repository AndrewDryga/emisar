package infraops

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const probeStartup = `#!/bin/bash
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl postgresql-client
curl -fsSLo /usr/local/bin/cloud-sql-proxy \
  https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.23.0/cloud-sql-proxy.linux.amd64
printf '%s  %s\n' cd689d582b826fa5bc82c01ccc14e45a58200c3cefbf923ce96c422825e4e6f6 \
  /usr/local/bin/cloud-sql-proxy | sha256sum -c -
chmod 0755 /usr/local/bin/cloud-sql-proxy
/usr/local/bin/cloud-sql-proxy --private-ip --auto-iam-authn --address 127.0.0.1 --port 5432 \
  '{{CONNECTION_NAME}}' >/var/log/cloud-sql-proxy.log 2>&1 &
proxy_pid=$!
for _ in $(seq 1 60); do
  pg_isready -h 127.0.0.1 -p 5432 && break
  sleep 2
done
PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -U '{{IAM_USER}}' -d emisar \
  -c 'SELECT session_user, current_user, count(*) AS account_rows FROM accounts;'
PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -U '{{IAM_USER}}' -d emisar -c 'SELECT 1;'
echo EMISAR_DRILL_AUTH_OK

for _ in $(seq 1 120); do
  ready=$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/revocation-ready || true)
  [[ $ready == true ]] && break
  sleep 2
done
[[ ${ready:-} == true ]] || { echo 'revocation signal not received' >&2; exit 1; }

denied=0
for _ in $(seq 1 60); do
  if PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -U '{{IAM_USER}}' -d emisar -c 'SELECT 1;'; then
    denied=0
  elif ! kill -0 "$proxy_pid" 2>/dev/null; then
    # A dead proxy makes every psql fail for a reason that has nothing to do
    # with IAM. Without this branch the loop just ran out its five minutes and
    # blamed revocation, sending the operator to debug the wrong subsystem.
    echo 'cloud-sql-proxy crashed during revocation verification' >&2
    tail -n 50 /var/log/cloud-sql-proxy.log >&2 || true
    exit 1
  elif pg_isready -h 127.0.0.1 -p 5432 >/dev/null; then
    denied=$((denied + 1))
    if [[ $denied -ge 3 ]]; then
      echo EMISAR_DRILL_REVOCATION_OK
      exit 0
    fi
  fi
  sleep 5
done
echo 'fresh IAM connections were not denied after revocation' >&2
exit 1
`

func randomSuffix() (string, error) {
	value := make([]byte, 3)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func (a *App) serialUntil(ctx context.Context, project, zone, vm, marker string) (string, error) {
	var serial string
	for attempt := 0; attempt < 60; attempt++ {
		output, err := a.output(ctx, a.Root, nil, "gcloud", "compute", "instances",
			"get-serial-port-output", vm, "--project="+project, "--zone="+zone)
		if err == nil {
			serial = string(output)
			if strings.Contains(serial, marker) {
				return serial, nil
			}
		}
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return serial, ctx.Err()
		}
	}
	return serial, fmt.Errorf("recovery probe did not report %s:\n%s", marker, serial)
}

func appendManifest(path string, values map[string]string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	for _, key := range []string{
		"drill_id", "project", "clone", "probe_vm", "service_account",
		"restore_time", "drill_started_at", "expires",
		"restored_serving_at", "measured_rto_seconds", "cleanup_verified_at",
	} {
		if value, ok := values[key]; ok {
			if _, err := fmt.Fprintf(file, "%s=%s\n", key, value); err != nil {
				return err
			}
		}
	}
	return file.Close()
}

func (a *App) pitrDrill(ctx context.Context, args []string) (runErr error) {
	apply := false
	if len(args) == 1 && args[0] == "--apply" {
		apply = true
	} else if len(args) != 0 {
		return usage("usage: ./run ops drill pitr [--apply]")
	}
	project := os.Getenv("PROJECT_ID")
	if project == "" {
		project = "emisar"
	}
	source := os.Getenv("SOURCE_INSTANCE")
	if source == "" {
		source = "emisar"
	}
	zone := os.Getenv("DRILL_ZONE")
	if zone == "" {
		zone = "us-central1-f"
	}
	suffix, err := randomSuffix()
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	prefix := "edrill-" + now.Format("0601021504") + "-" + suffix
	clone := prefix + "-db"
	account := prefix + "@" + project + ".iam.gserviceaccount.com"
	iamUser := prefix + "@" + project + ".iam"
	vm := prefix + "-probe"
	restoreTime := now.Add(-5 * time.Minute).Format(time.RFC3339)
	expires := now.Add(12 * time.Hour).Format("20060102150405")

	fmt.Fprintf(a.Out, "scratch clone: %s at %s\n", clone, restoreTime)
	fmt.Fprintf(a.Out, "scratch probe: %s in %s\n", vm, zone)
	if !apply {
		fmt.Fprintln(a.Out, "dry run only; production remains read-only and --apply trap-cleans every scratch resource")
		fmt.Fprintln(a.Out, "the applied manifest records elapsed restore time through the first emisar_owner query")
		return nil
	}
	if err := a.require("gcloud"); err != nil {
		return err
	}
	temp, err := os.MkdirTemp("", "emisar-pitr-drill-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	manifestDir := os.Getenv("DRILL_MANIFEST_DIR")
	if manifestDir == "" {
		manifestDir = filepath.Join(a.Infra, ".agent", "drills")
	}
	if err := os.MkdirAll(manifestDir, 0o700); err != nil {
		return err
	}
	manifest := filepath.Join(manifestDir, prefix+".env")
	started := time.Now().UTC()
	if err := appendManifest(manifest, map[string]string{
		"drill_id": prefix, "project": project, "clone": clone, "probe_vm": vm,
		"service_account": account, "restore_time": restoreTime,
		"drill_started_at": started.Format(time.RFC3339), "expires": expires,
	}); err != nil {
		return err
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		defer cancel()
		cleanupErr := a.cleanupDrills(cleanupCtx, []string{"--apply", prefix})
		if cleanupErr == nil {
			_ = appendManifest(manifest, map[string]string{
				"cleanup_verified_at": time.Now().UTC().Format(time.RFC3339),
			})
		} else if runErr == nil {
			runErr = fmt.Errorf("drill succeeded but cleanup failed; run ./run ops drill cleanup --apply %s: %w",
				prefix, cleanupErr)
		}
	}()

	condition := map[string]string{
		"title": prefix + "-only", "description": "Temporary non-production recovery drill",
		"expression": fmt.Sprintf(
			"resource.name == 'projects/%s/instances/%s' && resource.type == 'sqladmin.googleapis.com/Instance'",
			project, clone),
	}
	conditionData, _ := json.MarshalIndent(condition, "", "  ")
	conditionPath := filepath.Join(temp, "condition.json")
	if err := os.WriteFile(conditionPath, append(conditionData, '\n'), 0o600); err != nil {
		return err
	}

	if err := a.run(ctx, a.Root, nil, "gcloud", "iam", "service-accounts", "create",
		prefix, "--project="+project, "--display-name=Temporary recovery drill "+prefix); err != nil {
		return err
	}
	for _, role := range []string{"roles/cloudsql.client", "roles/cloudsql.instanceUser"} {
		if err := a.run(ctx, a.Root, nil, "gcloud", "projects", "add-iam-policy-binding",
			project, "--member=serviceAccount:"+account, "--role="+role,
			"--condition-from-file="+conditionPath, "--quiet"); err != nil {
			return err
		}
	}
	if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "instances", "clone",
		source, clone, "--project="+project, "--point-in-time="+restoreTime,
		"--preferred-zone="+zone, "--quiet"); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "instances", "patch",
		clone, "--project="+project,
		"--update-labels=purpose=recovery-drill,drill_id="+prefix+",expires="+expires,
		"--no-deletion-protection", "--quiet"); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "users", "create", iamUser,
		"--project="+project, "--instance="+clone, "--type=CLOUD_IAM_SERVICE_ACCOUNT",
		"--database-roles=emisar_owner"); err != nil {
		return err
	}
	connection, err := a.output(ctx, a.Root, nil, "gcloud", "sql", "instances", "describe",
		clone, "--project="+project, "--format=value(connectionName)")
	if err != nil {
		return err
	}
	startup := strings.NewReplacer(
		"{{CONNECTION_NAME}}", strings.TrimSpace(string(connection)),
		"{{IAM_USER}}", iamUser,
	).Replace(probeStartup)
	startupPath := filepath.Join(temp, "startup.sh")
	if err := os.WriteFile(startupPath, []byte(startup), 0o700); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "gcloud", "compute", "instances", "create", vm,
		"--project="+project, "--zone="+zone, "--machine-type=e2-micro",
		"--image-family=debian-13", "--image-project=debian-cloud",
		"--network=emisar-vpc", "--subnet=emisar-us-central1", "--no-address",
		"--service-account="+account, "--scopes=cloud-platform",
		"--metadata=serial-port-enable=true", "--metadata-from-file=startup-script="+startupPath,
		"--labels=purpose=recovery-drill,drill_id="+prefix+",expires="+expires); err != nil {
		return err
	}
	if _, err := a.serialUntil(ctx, project, zone, vm, "EMISAR_DRILL_AUTH_OK"); err != nil {
		return err
	}
	elapsed := time.Since(started)
	if err := appendManifest(manifest, map[string]string{
		"restored_serving_at":  time.Now().UTC().Format(time.RFC3339),
		"measured_rto_seconds": fmt.Sprint(int(elapsed.Seconds())),
	}); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "restored clone served an emisar_owner query in %s\n", elapsed.Truncate(time.Second))

	if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "users", "delete", iamUser,
		"--project="+project, "--instance="+clone, "--quiet"); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "gcloud", "compute", "instances", "add-metadata",
		vm, "--project="+project, "--zone="+zone, "--metadata=revocation-ready=true", "--quiet"); err != nil {
		return err
	}
	if _, err := a.serialUntil(ctx, project, zone, vm, "EMISAR_DRILL_REVOCATION_OK"); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "PITR, reconnect, IAM owner role, and IAM revocation verified on scratch resources")
	return nil
}
