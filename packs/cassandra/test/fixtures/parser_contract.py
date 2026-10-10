"""Supplemental parser/output contracts, not Cassandra provider substitutes."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

PACK = Path("/packs/cassandra")
checks = 0

def require(condition, message):
    global checks
    assert condition, message
    checks += 1

with tempfile.TemporaryDirectory(prefix="cassandra-parser-") as temporary:
    base = Path(temporary)
    conf = base / "conf"
    conf.mkdir()
    default = base / "default"
    data = default / "data"
    commit = default / "commitlog"
    extra = base / "data with space,#quote'and\"double"
    local = base / "local system"
    for directory in (data, commit, extra, local):
        directory.mkdir(parents=True)
    for directory in (data / "9_keyspace", local / "system", data / "inside"):
        directory.mkdir()
    (data / "inside" / "table-sentinel").write_text("metadata only")
    (data / "alias").symlink_to(data / "inside", target_is_directory=True)
    outside = base / "outside"
    outside.mkdir()
    (outside / "outside-sentinel").write_text("not returned")
    (data / "escapeproof").symlink_to(outside, target_is_directory=True)
    (data / "loop").symlink_to(data / "loop", target_is_directory=True)
    config = conf / "cassandra.yaml"
    env = dict(os.environ, CASSANDRA_CONF=str(conf), CASSANDRA_STORAGE_DIR=str(default))

    def disk(text, succeeds=True, keyspace="", contains=(), absent=()):
        config.write_text(text)
        result = subprocess.run(["bash", str(PACK / "scripts/analyze_disk_pressure.sh"),
                                 "--keyspace-filter", keyspace], env=env, capture_output=True, text=True)
        require((result.returncode == 0) == succeeds, "disk status: " + result.stderr)
        for value in contains:
            require(value in result.stdout, "missing selected root/metadata: " + value)
        for value in absent:
            require(value not in result.stdout + result.stderr, "unintended output: " + value)
        require("private-config-canary" not in result.stdout + result.stderr, "config was returned")
        if not succeeds:
            require("Traceback" not in result.stderr, "unsafe Python diagnostic")
        return result

    disk("cluster_name: packtest\n# private-config-canary\n", contains=(str(data), str(commit)))
    disk("data_file_directories: []\ncommitlog_directory: null\n", contains=(str(data), str(commit)))
    disk("data_file_directories:\n  - " + str(data) + "\ncommitlog_directory: " + str(commit) + "\n")
    disk("'data_file_directories':\n- '" + str(extra).replace("'", "''") + "'\ncommitlog_directory: " + str(commit) + "\n",
         contains=(json.dumps(str(extra)),))
    disk('"data_file_directories": [\n  ' + json.dumps(str(data)) + ", # comment\n  " + json.dumps(str(extra)) + ",\n]\n",
         contains=(json.dumps(str(data)), json.dumps(str(extra))))
    # Nested/flow/scalar-looking storage fields never override root defaults.
    for prefix in (
        "unknown:\n  data_file_directories: [/does-not-exist]\n",
        "unknown: {\n data_file_directories: [/does-not-exist]\n}\n",
        'unknown: "text\ndata_file_directories: [/does-not-exist]\nmore text"\n',
        "unknown: |\n  data_file_directories: [/does-not-exist]\n",
        "seed_provider:\n- class_name: fixture\n  parameters:\n  - data_file_directories: /does-not-exist\n",
    ):
        disk(prefix, contains=(str(data), str(commit)), absent=("/does-not-exist",))
    disk("local_system_data_file_directory: " + str(local) + "\n", keyspace="system",
         contains=("Selected keyspace tables", str(local / "system")))
    disk("cluster_name: packtest\n", keyspace="9_keyspace", contains=(str(data / "9_keyspace"),))
    selected = disk("cluster_name: packtest\n", keyspace="alias", contains=(str(data / "inside"), "table-sentinel"))
    require(str(data / "alias" / "table-sentinel") not in selected.stdout, "selected operand was not canonical")
    for keyspace in ("..", "*", "escapeproof", "loop", "missing"):
        disk("cluster_name: packtest\n", False, keyspace, absent=("outside-sentinel", "Selected keyspace tables"))
    for malformed in (
        "data_file_directories: null\n", "data_file_directories:\n",
        "data_file_directories: /not-a-sequence\n", "data_file_directories: [null]\n",
        "data_file_directories: [\"null\"]\n", "data_file_directories: [/missing]\n",
        "data_file_directories: [/missing\n", "data_file_directories: [[/missing]]\n",
        "data_file_directories: [/missing,,]\n",
        "data_file_directories:\n  - /missing\n - /other\n",
        "data_file_directories: []\ndata_file_directories: []\n",
        "commitlog_directory: relative\n", "commitlog_directory: 'null'\n",
        "commitlog_directory: &storage /missing\n", "commitlog_directory: *storage\n",
        "commitlog_directory: !!str /missing\n", "<<: {commitlog_directory: /missing}\n",
        "commitlog_directory: |\n  /missing\n", "commitlog_directory: /missing\n  continuation\n",
        "commitlog_directory: \"/private-config-canary\\n\"\n",
        "'data_file_directories':[]\n", "cluster_name: packtest\n- /missing\n",
        "---\ncluster_name: packtest\n---\ncommitlog_directory: /missing\n",
        "data_file_directories: [/missing]\ncommitlog_directory: \"unterminated\n",
    ):
        disk(malformed, False, absent=("== Cassandra",))
    disk("#" + "x" * (1024 * 1024) + "\n", False)
    config.unlink()
    missing = subprocess.run(["bash", str(PACK / "scripts/analyze_disk_pressure.sh")], env=env,
                             capture_output=True, text=True)
    require(missing.returncode != 0 and not missing.stdout, "missing config became defaults")
    os.mkfifo(config)
    fifo_result = subprocess.run(["bash", str(PACK / "scripts/analyze_disk_pressure.sh")], env=env,
                                 capture_output=True, text=True, timeout=2)
    require(fifo_result.returncode != 0 and not fifo_result.stdout, "nonregular config was consumed")
    config.unlink()

    # History producer doubles test formatting/exit propagation separately
    # from the plan's real two-table native compactions.
    fake_bin = base / "bin"
    fake_bin.mkdir()
    fake = fake_bin / "nodetool"
    fake.write_text('#!/bin/sh\n[ "$#" = 1 ] && [ "$1" = compactionhistory ] || exit 99\ncat "$PACKTEST_HISTORY"\nexit "${PACKTEST_HISTORY_STATUS:-0}"\n')
    fake.chmod(0o700)
    history = base / "history"
    history_env = dict(os.environ, PATH=str(fake_bin) + ":" + os.environ["PATH"], PACKTEST_HISTORY=str(history))
    heading = "Compaction History: \n"
    fields = "id keyspace_name columnfamily_name compacted_at bytes_in bytes_out rows_merged"
    for suffix in ("", " compaction_properties"):
        history.write_text(heading + fields + suffix + "\n" + "\n".join("row{} k t date 1 2 {{1:2}}".format(i) for i in range(1201)) + "\n")
        output = subprocess.run(["bash", str(PACK / "scripts/nodetool_compactionhistory.sh"), "1000"],
                                env=history_env, capture_output=True)
        require(output.returncode == 0 and output.stdout.endswith(b"showing 1000 of 1201\n"), "history count")
        require(len(output.stdout.splitlines()) == 1003, "history row limit")
    history.write_text(heading + fields + "\n" + "\n".join("\u00e9" * 900 for _ in range(1201)) + "\n")
    output = subprocess.run(["bash", str(PACK / "scripts/nodetool_compactionhistory.sh"), "1000"],
                            env=history_env, capture_output=True)
    require(output.returncode == 0 and len(output.stdout) < 524288, "history display budget")
    decoded = output.stdout.decode("utf-8")
    require(all(len(line.encode()) <= 512 and line.endswith(" ... [clipped]") for line in decoded.splitlines()[2:-1]), "UTF8/visible clipping")
    history.write_text(heading + "There is no compaction history")
    output = subprocess.run(["bash", str(PACK / "scripts/nodetool_compactionhistory.sh"), "1"], env=history_env, capture_output=True)
    require(output.returncode == 0 and output.stdout.endswith(b"showing 0 of 0\n"), "empty history")
    history.write_text(heading + fields + "\nrow k t date 1 2 {1:2}\n")
    output = subprocess.run(["bash", str(PACK / "scripts/nodetool_compactionhistory.sh"), "1"],
                            env=dict(history_env, PACKTEST_HISTORY_STATUS="7"), capture_output=True)
    require(output.returncode == 7 and not output.stdout, "source failure became healthy history")
    for text in ("", "bad\noutput", heading + "unknown header\n", heading + fields + "\n\n"):
        history.write_text(text)
        output = subprocess.run(["bash", str(PACK / "scripts/nodetool_compactionhistory.sh"), "1"], env=history_env, capture_output=True)
        require(output.returncode != 0 and not output.stdout, "malformed history became healthy")

print("{} supplemental storage/history checks passed".format(checks))
