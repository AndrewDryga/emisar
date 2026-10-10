#!/usr/bin/env bash
set -euo pipefail

exec python3 -I - "$@" <<'PY'
import subprocess
import sys

if len(sys.argv) != 2 or not sys.argv[1].isascii() or not sys.argv[1].isdigit():
    sys.exit("invalid compaction history limit")
limit = int(sys.argv[1])
if not 1 <= limit <= 1000:
    sys.exit("invalid compaction history limit")

# Neither supported nodetool version has a query limit. Capture a successful
# complete result before counting or displaying it; stderr remains diagnostic.
result = subprocess.run(["nodetool", "compactionhistory"], stdout=subprocess.PIPE)
if result.returncode:
    sys.exit(result.returncode if result.returncode > 0 else 1)
try:
    lines = result.stdout.decode("utf-8").splitlines()
except UnicodeDecodeError:
    sys.exit("invalid compaction history output")
if len(lines) < 2 or lines[0].strip() != "Compaction History:":
    sys.exit("invalid compaction history output")
if lines[1].strip() == "There is no compaction history":
    if len(lines) != 2:
        sys.exit("invalid compaction history output")
    rows = []
else:
    fields = ["id", "keyspace_name", "columnfamily_name", "compacted_at",
              "bytes_in", "bytes_out", "rows_merged"]
    if lines[1].split() not in (fields, fields + ["compaction_properties"]):
        sys.exit("invalid compaction history output")
    rows = lines[2:]
    if any(not row.strip() for row in rows):
        sys.exit("invalid compaction history output")

def display(line):
    raw = line.encode("utf-8")
    marker = b" ... [clipped]"
    if len(raw) > 512:
        line = raw[:512 - len(marker)].decode("utf-8", errors="ignore") + marker.decode()
    print(line)

for line in lines[:2] + rows[:limit]:
    display(line)
print("showing {} of {}".format(min(limit, len(rows)), len(rows)))
PY
