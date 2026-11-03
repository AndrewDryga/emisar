#!/usr/bin/env bash
# Show Medusa's version and the settings that decide where backups go and how
# long they stay. Values come from an allowlist of Medusa's own keys; secrets,
# commands, and credential overrides are named, never printed.
set -euo pipefail

status=0
version=$(medusa --version 2>&1) || status=$?
if [ "$status" -ne 0 ]; then
    printf '%s\n' "$version" >&2
    exit "$status"
fi
# Cassandra Medusa prints only its version. Anything else is another program
# named medusa, such as the login tool Debian and Kali ship.
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "The medusa on PATH is not Cassandra Medusa; it printed no version number." >&2
        exit 1
        ;;
esac
printf 'Medusa %s\n' "$version"

exec python3 -I - <<'PY'
import configparser
import os
import sys

PATH = "/etc/medusa/medusa.ini"

# Medusa 0.31.1 (medusa/config.py) defaults for the keys shown below.
DEFAULTS = {
    "storage": {
        "secure": "True",
        "ssl_verify": "False",
        "region": "default",
        "max_backup_age": "0",
        "max_backup_count": "0",
        "backup_grace_period_in_days": "10",
        "transfer_max_bandwidth": "50MB/s",
        "concurrent_transfers": "1",
        "use_sudo_for_restore": "True",
        "s3_addressing_style": "auto",
    },
    "cassandra": {
        "config_file": "/etc/cassandra/cassandra.yaml",
        "resolve_ip_addresses": "True",
        "nodetool_executable": "nodetool",
        "start_cmd": "sudo service cassandra start",
        "stop_cmd": "sudo service cassandra stop",
    },
    "logging": {"enabled": "false", "file": "medusa.log", "level": "INFO"},
}

SHOWN = {
    "storage": [
        "storage_provider", "bucket_name", "prefix", "fqdn", "host", "port",
        "region", "secure", "ssl_verify", "storage_class", "base_path",
        "key_file", "api_profile", "max_backup_age", "max_backup_count",
        "backup_grace_period_in_days", "transfer_max_bandwidth",
        "concurrent_transfers", "use_sudo_for_restore", "s3_addressing_style",
    ],
    "cassandra": [
        "config_file", "cql_username", "nodetool_username", "nodetool_host",
        "nodetool_port", "nodetool_ssl", "nodetool_executable",
        "resolve_ip_addresses",
    ],
    "logging": ["enabled", "file", "level"],
}

# Shown by name only: credentials, encryption material, and commands Medusa
# runs, whose text the operator wrote.
NAMED = {
    "storage": ["sse_c_key", "kms_id"],
    "cassandra": [
        "cql_password", "nodetool_password", "nodetool_password_file_path",
        "sstableloader_tspw", "sstableloader_kspw", "certfile", "usercert",
        "userkey", "stop_cmd", "start_cmd",
    ],
    "checks": ["query"],
}

# Environment variables Medusa or its storage clients read in place of the file.
OVERRIDES = [
    "MEDUSA_CQL_USERNAME", "MEDUSA_CQL_PASSWORD", "CQL_USERNAME", "CQL_PASSWORD",
    "MEDUSA_NODETOOL_USERNAME", "MEDUSA_NODETOOL_PASSWORD",
    "MEDUSA_SSTABLELOADER_TSPW", "MEDUSA_SSTABLELOADER_KSPW",
    "MEDUSA_RESOLVE_IP_ADDRESSES", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_SHARED_CREDENTIALS_FILE",
    "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_STORAGE_ACCOUNT",
]

# Medusa parses the file the same way (no interpolation, no inline comments).
config = configparser.ConfigParser(interpolation=None)
try:
    with open(PATH, encoding="utf-8") as handle:
        config.read_file(handle)
except FileNotFoundError:
    sys.exit(f"No Medusa configuration at {PATH}.")
except PermissionError:
    sys.exit(f"The runner cannot read {PATH}; see this pack's host access.")
except (configparser.Error, UnicodeDecodeError) as error:
    sys.exit(f"Medusa cannot parse {PATH}: {error.__class__.__name__}.")

print(f"Configuration: {PATH}")
for section, keys in SHOWN.items():
    print(f"\n[{section}]")
    for key in keys:
        if config.has_option(section, key):
            print(f"{key} = {config.get(section, key)}")
        elif key in DEFAULTS.get(section, {}):
            print(f"{key} = {DEFAULTS[section][key]} (default)")
        elif section == "storage" and key == "fqdn":
            print("fqdn is not set; Medusa derives it from this host's name")

set_names, default_names, unset_names = [], [], []
for section, keys in NAMED.items():
    for key in keys:
        if config.has_option(section, key) and config.get(section, key).strip():
            set_names.append(key)
        elif key in DEFAULTS.get(section, {}):
            default_names.append(key)
        else:
            unset_names.append(key)

print()
print("Set in the file, not shown: " + (", ".join(set_names) or "none"))
if default_names:
    print("Using Medusa's default, not shown: " + ", ".join(default_names))
print("Not set: " + (", ".join(unset_names) or "none"))
present = [name for name in OVERRIDES if name in os.environ]
print("Environment overrides passed to Medusa, not shown: " + (", ".join(present) or "none"))
PY
