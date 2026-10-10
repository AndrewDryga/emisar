#!/usr/bin/env bash
# Read-only storage metadata from the operator-selected Cassandra config.
set -euo pipefail

exec python3 -I - "$@" <<'PY'
import heapq
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

FIELDS = {"data_file_directories", "commitlog_directory", "local_system_data_file_directory"}
MAX_CONFIG_BYTES = 1024 * 1024

class Failure(Exception):
    pass

def fail(message):
    raise Failure(message)

def quoted(source, pos):
    """Decode one single-line YAML quoted string, returning value/end."""
    quote = source[pos]
    pos += 1
    value = []
    escapes = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "n": "\n",
               "v": "\v", "f": "\f", "r": "\r", "e": "\x1b", " ": " ",
               '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0",
               "L": "\u2028", "P": "\u2029"}
    while pos < len(source):
        char = source[pos]
        if char in "\r\n":
            fail("multiline storage strings are unsupported")
        if char == quote:
            if quote == "'" and source[pos:pos + 2] == "''":
                value.append("'")
                pos += 2
                continue
            return "".join(value), pos + 1
        if quote == '"' and char == "\\":
            pos += 1
            if pos >= len(source):
                fail("unterminated quoted storage string")
            escape = source[pos]
            if escape in escapes:
                value.append(escapes[escape])
            elif escape in ("x", "u", "U"):
                width = {"x": 2, "u": 4, "U": 8}[escape]
                digits = source[pos + 1:pos + 1 + width]
                if len(digits) != width or not re.fullmatch(r"[0-9A-Fa-f]+", digits):
                    fail("invalid quoted storage escape")
                try:
                    value.append(chr(int(digits, 16)))
                except ValueError:
                    fail("invalid quoted storage escape")
                pos += width
            else:
                fail("unsupported quoted storage escape")
        else:
            value.append(char)
        pos += 1
    fail("unterminated quoted storage string")

def header(source):
    if source.startswith(("'", '"')):
        key, end = quoted(source, 0)
        remainder = source[end:].lstrip(" ")
        if not remainder.startswith(":"):
            return None
        if len(remainder) > 1 and not remainder[1].isspace():
            fail("unsupported root mapping separator")
        return key, remainder[1:].lstrip(" ")
    match = re.match(r"^([A-Za-z0-9_][A-Za-z0-9_-]*|<<)[ ]*:(?:[ ]+|$)(.*)$", source)
    return (match.group(1), match.group(2)) if match else None

def storage_records(text):
    """Extract storage fields, not general YAML validation.

    Track unrelated quoted/flow/block-scalar context so embedded field-looking
    text cannot masquerade as a storage setting. Reject ambiguous root syntax.
    """
    records = {}
    current = root_indent = quote = block_indent = None
    flow = []
    started = ended = indentless_list = False

    def scan(source, indent):
        nonlocal quote, block_indent
        pos = 0
        scalar_start = True
        while pos < len(source):
            char = source[pos]
            if quote:
                if quote == '"' and char == "\\":
                    pos += 2
                    continue
                if char == quote:
                    if quote == "'" and source[pos:pos + 2] == "''":
                        pos += 2
                        continue
                    quote = None
                    scalar_start = False
                pos += 1
                continue
            if char == "#" and (pos == 0 or source[pos - 1].isspace()):
                return
            if char.isspace():
                pos += 1
                continue
            if scalar_start and char in "&*!":
                fail("YAML anchors, aliases and tags are unsupported")
            if scalar_start and char in "'\"":
                quote = char
            elif char in "[{" and (scalar_start or flow):
                flow.append(char)
                scalar_start = True
            elif char in "]}" and flow:
                if flow[-1] != {"]": "[", "}": "{"}[char]:
                    fail("unbalanced YAML flow collection")
                flow.pop()
                scalar_start = False
            elif char == "," and flow:
                scalar_start = True
            elif char == ":" and (pos + 1 == len(source) or source[pos + 1].isspace()
                                  or (flow and source[pos + 1] in "[]{},")):
                scalar_start = True
            elif scalar_start and char == "-" and (pos + 1 == len(source) or source[pos + 1].isspace()):
                scalar_start = True
            elif scalar_start and char in "|>" and not flow:
                if re.fullmatch(r"[|>](?:[+-]?[1-9]?|[1-9][+-]?)[ ]*(?:#.*)?", source[pos:]):
                    block_indent = indent
                    return
                scalar_start = False
            else:
                scalar_start = False
            pos += 1

    for line in text.splitlines():
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if stripped.startswith("\t"):
            fail("tab indentation is unsupported")
        if not stripped or stripped.startswith("#"):
            continue
        if block_indent is not None:
            if indent > block_indent:
                continue
            block_indent = None
        if ended:
            fail("multiple YAML documents are unsupported")
        body = stripped
        if not quote and not flow:
            if stripped == "---":
                if started:
                    fail("multiple YAML documents are unsupported")
                started = True
                continue
            if stripped == "...":
                ended = True
                continue
            if root_indent is None:
                root_indent = indent
            if indent < root_indent:
                fail("inconsistent root mapping indentation")
            if indent == root_indent:
                entry = header(stripped)
                if entry:
                    key, body = entry
                    started = True
                    if key == "<<":
                        fail("root YAML merges are unsupported")
                    current = None
                    indentless_list = not body or body.startswith("#")
                    if key in FIELDS:
                        if key in records:
                            fail("duplicate storage setting")
                        current = [body]
                        records[key] = current
                elif stripped == "-" or stripped.startswith("- "):
                    if not indentless_list:
                        fail("unsupported root sequence entry")
                    if current is not None:
                        current.append(line)
                else:
                    fail("unsupported root mapping syntax")
            elif current is not None:
                current.append(line)
        elif current is not None:
            current.append(line)
        scan(body, indent)
    if quote or flow:
        fail("unterminated YAML quoted value or flow collection")
    if root_indent is None:
        fail("Cassandra configuration is empty")
    return records

def scalar(source):
    source = source.strip()
    if not source or source.startswith("#"):
        return None
    if source[0] in "'\"":
        value, end = quoted(source, 0)
        remainder = source[end:].strip()
        if remainder and not remainder.startswith("#"):
            fail("unexpected text after storage string")
        return value
    source = re.split(r"(?<!\S)#", source, maxsplit=1)[0].strip()
    if source in ("", "~", "null", "Null", "NULL"):
        return None
    if source[0] in "&*!|>[{":
        fail("unsupported storage value syntax")
    if "\n" in source or "\r" in source:
        fail("multiline storage strings are unsupported")
    if re.search(r":(?:\s|$)", source):
        fail("a storage value must be a path string")
    return source

def flow_paths(source):
    pos = 1
    result = []
    def skip():
        nonlocal pos
        while pos < len(source):
            if source[pos].isspace():
                pos += 1
            elif source[pos] == "#" and (pos == 0 or source[pos - 1].isspace()):
                end = source.find("\n", pos)
                pos = len(source) if end < 0 else end + 1
            else:
                break
    skip()
    while pos < len(source) and source[pos] != "]":
        if source[pos] in "'\"":
            value, pos = quoted(source, pos)
        else:
            start = pos
            while pos < len(source) and source[pos] not in ",]":
                if source[pos] == "#" and (pos == start or source[pos - 1].isspace()):
                    break
                if source[pos] in "[{":
                    fail("nested storage flow values are unsupported")
                pos += 1
            value = scalar(source[start:pos])
        result.append(value)
        skip()
        if pos < len(source) and source[pos] == ",":
            pos += 1
            skip()
        elif pos >= len(source) or source[pos] != "]":
            fail("malformed storage flow sequence")
    if pos >= len(source) or source[pos] != "]":
        fail("unterminated storage flow sequence")
    pos += 1
    skip()
    if pos != len(source):
        fail("unexpected text after storage flow sequence")
    return result

def data_paths(lines):
    first = lines[0].strip()
    if first.startswith("["):
        return flow_paths("\n".join(lines))
    if first and not first.startswith("#"):
        fail("data_file_directories must be a path sequence")
    result = []
    item_indent = None
    for line in lines[1:]:
        body = line.lstrip(" ")
        if not body or body.startswith("#"):
            continue
        indent = len(line) - len(body)
        if item_indent is None:
            item_indent = indent
        if indent != item_indent or not body.startswith("- "):
            fail("unsupported data directory block sequence")
        result.append(scalar(body[2:]))
    if not result:
        fail("null data_file_directories is unsupported")
    return result

def scalar_setting(lines):
    if any(line.strip() and not line.lstrip().startswith("#") for line in lines[1:]):
        fail("multiline storage values are unsupported")
    return scalar(lines[0])

def absolute_path(value):
    if not isinstance(value, str) or not value or not os.path.isabs(value):
        fail("storage paths must be nonempty absolute strings")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail("control characters are unsupported in storage paths")
    return Path(value)

def canonical_directory(value):
    try:
        resolved = absolute_path(value).resolve(strict=True)
        if not resolved.is_dir():
            fail("a configured storage root is not a directory")
        return resolved
    except (OSError, RuntimeError):
        fail("a configured storage root cannot be resolved")

def read_configuration():
    directory = absolute_path(os.environ.get("CASSANDRA_CONF", "/etc/cassandra"))
    try:
        fd = os.open(directory / "cassandra.yaml", os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode):
                fail("Cassandra configuration is not a regular file")
            if info.st_size > MAX_CONFIG_BYTES:
                fail("Cassandra configuration exceeds the size limit")
            raw = source.read(MAX_CONFIG_BYTES + 1)
        if len(raw) > MAX_CONFIG_BYTES:
            fail("Cassandra configuration exceeds the size limit")
        return raw.decode("utf-8-sig")
    except (OSError, UnicodeError):
        fail("Cassandra configuration cannot be read as UTF-8")

def top_sizes(directory):
    def sizes():
        with os.scandir(directory) as entries:
            for entry in entries:
                # du does not follow this final child symlink; its parent is
                # already canonical. Keep filenames out of record parsing.
                output = subprocess.run(["du", "-sk", "--", entry.path], check=True,
                                        stdout=subprocess.PIPE, text=True).stdout
                count = output.partition("\t")[0]
                if not count.isdecimal():
                    fail("du returned an unexpected size record")
                yield int(count), entry.path
    largest = heapq.nlargest(20, sizes(), key=lambda item: (item[0], item[1]))
    if not largest:
        print("(empty directory)", flush=True)
    for count, path in largest:
        print("{} KiB\t{}".format(count, json.dumps(path)), flush=True)

def measure(label, directory, children=False):
    print("\n== {}: {} ==".format(label, json.dumps(str(directory))), flush=True)
    subprocess.run(["df", "-P", "-h", "--", str(directory)], check=True)
    subprocess.run(["du", "-sh", "--", str(directory)], check=True)
    if children:
        print("-- largest immediate entries (up to 20) --", flush=True)
        top_sizes(directory)

def main():
    argv = sys.argv[1:]
    if not argv:
        keyspace = ""
    elif len(argv) == 2 and argv[0] == "--keyspace-filter":
        keyspace = argv[1]
    else:
        fail("unsupported disk analysis arguments")
    if keyspace and not re.fullmatch(r"[A-Za-z0-9_]{1,48}", keyspace):
        fail("keyspace name must contain 1-48 ASCII word characters")
    records = storage_records(read_configuration())
    storage = absolute_path(os.environ.get("CASSANDRA_STORAGE_DIR", "/var/lib/cassandra"))
    data = data_paths(records["data_file_directories"]) if "data_file_directories" in records else []
    if not data:
        data = [str(storage / "data")]
    commitlog = scalar_setting(records["commitlog_directory"]) if "commitlog_directory" in records else None
    local_system = scalar_setting(records["local_system_data_file_directory"]) if "local_system_data_file_directory" in records else None
    roots = [canonical_directory(value) for value in data]
    commitlog_root = canonical_directory(commitlog if commitlog is not None else str(storage / "commitlog"))
    local_root = canonical_directory(local_system) if local_system is not None else None
    selections = []
    if keyspace:
        selection_roots = list(dict.fromkeys(roots + ([local_root] if local_root else [])))
        for root in selection_roots:
            candidate = root / keyspace
            if not os.path.lexists(candidate):
                continue
            selected = canonical_directory(str(candidate))
            if root not in selected.parents:
                fail("keyspace path escapes configured data root")
            selections.append(selected)
        if not selections:
            fail("selected keyspace does not exist in configured data roots")
    for root in roots:
        measure("Cassandra data", root, children=True)
    measure("Cassandra commitlog", commitlog_root)
    if local_root is not None:
        measure("Cassandra local system data", local_root, children=True)
    for selected in selections:
        measure("Selected keyspace tables", selected, children=True)

try:
    main()
except Failure as error:
    print("disk analysis failed: {}".format(error), file=sys.stderr)
    sys.exit(1)
except subprocess.CalledProcessError as error:
    print("disk analysis failed: measurement command failed", file=sys.stderr)
    sys.exit(error.returncode if error.returncode > 0 else 1)
except (OSError, UnicodeError):
    print("disk analysis failed: filesystem operation failed", file=sys.stderr)
    sys.exit(1)
PY
