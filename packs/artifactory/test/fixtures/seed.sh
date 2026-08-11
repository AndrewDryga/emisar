#!/bin/bash
# Arrange the state the behavior cases read. The admin canary password is
# set by bootstrap.creds before access first boots (written by the compose
# entrypoint wrapper); this waits until that identity works, then deploys
# one artifact into the shipped example-repo-local — repository creation
# over REST is an Artifactory Pro API, so the fixture leans on the repo OSS
# ships — and downloads it once so download stats are non-zero. The marker
# file is what lets the container healthcheck go healthy.
set -euo pipefail

base=http://localhost:8082/artifactory

req() {
  printf 'user = "admin:%s"\n' "${PACKTEST_ADMIN_PASSWORD}" |
    curl -q --config - --fail --silent --show-error --max-time 30 "$@"
}

until req "$base/api/repositories" >/dev/null 2>&1; do
  sleep 3
done

printf 'hello from packtest\n' | req --upload-file - "$base/example-repo-local/smoke/hello.txt"
req --output /dev/null "$base/example-repo-local/smoke/hello.txt"

touch /tmp/packtest-seeded
