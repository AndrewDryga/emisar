#!/bin/bash
# Sourced only by the signed-Debian build, never by the production host.
: "${bundle_root:?set the final bundle root}" "${ownership_rows:?set the file-origin output}"

diagnostics_package_identity() {
  local row status
  row=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' -- "$1") || return 1
  status=${row%%$'\t'*}
  [ "$status" = 'ii ' ] || { echo "Debian owner is not installed: $1" >&2; return 1; }
  printf '%s\n' "${row#*$'\t'}"
}

diagnostics_debian_owner() {
  local original=$1 canonical candidate owners package
  canonical=$(readlink -f "$original") || return 1
  # cp -L ships the target bytes, not a possibly differently owned symlink.
  local -a candidates=("$canonical")
  # Bookworm registers /bin and /lib while usr-merge resolves their /usr aliases.
  case "$canonical" in
    /usr/bin/*|/usr/sbin/*|/usr/lib/*) candidates+=("${canonical#/usr}") ;;
    /bin/*|/sbin/*|/lib/*) candidates+=("/usr$canonical") ;;
  esac
  for candidate in "${candidates[@]}"; do
    owners=$(dpkg-query -S -- "$candidate" 2>/dev/null | awk -F ': ' -v path="$candidate" '$2 == path {print $1}') || continue
    [ -n "$owners" ] || continue
    # Reject diversions, multiple owners and ambiguous search results.
    [[ "$owners" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] || {
      echo "ambiguous Debian owner: $original" >&2; return 1;
    }
    package=$(diagnostics_package_identity "$owners") || return 1
    printf '%s\n' "$package"
    return 0
  done
  echo "missing Debian owner: $original" >&2
  return 1
}

diagnostics_record_origin() {
  local destination=$1 kind=$2 source=$3 identity=$4
  [[ "$destination" == "$bundle_root/"* ]] || return 1
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  printf './%s\t%s\t%s\t%s\n' "${destination#"$bundle_root/"}" "$kind" "$source" "$identity" >> "$ownership_rows"
}

diagnostics_record_debian() {
  local source=$1 destination=$2 identity kind=debian owned_source=$1 optimization=0
  # Debian's postinst produces bytecode, which dpkg does not own directly.
  # Bind it to its owned .py source only after verifying the compiled code.
  if [[ "$source" == */__pycache__/*.cpython-311*.pyc ]]; then
    local filename=${source##*/}
    owned_source="${source%/__pycache__/*}/${filename%%.cpython-311*}.py"
    case "$filename" in *.opt-1.pyc) optimization=1 ;; *.opt-2.pyc) optimization=2 ;; esac
    python3 - "$source" "$owned_source" "$optimization" <<'PY' || return 1
import importlib.util
import marshal
import pathlib
import sys
data = pathlib.Path(sys.argv[1]).read_bytes()
assert data[:4] == importlib.util.MAGIC_NUMBER, "foreign Python bytecode"
code = marshal.loads(data[16:])
expected = compile(pathlib.Path(sys.argv[2]).read_bytes(), code.co_filename, "exec", optimize=int(sys.argv[3]))
assert code == expected, "bytecode does not match Debian-owned source"
PY
    kind=debian-bytecode
  fi
  identity=$(diagnostics_debian_owner "$owned_source") || return 1
  diagnostics_record_origin "$destination" "$kind" "$owned_source" "$identity"
}

diagnostics_copy_debian() {
  local source=$1 destination=$2
  cp -L "$source" "$destination" || return 1
  diagnostics_record_debian "$source" "$destination"
}

diagnostics_copy_python_tree() {
  local source=$1 destination=$2 file relative
  [ -d "$source" ] || return 1
  install -d "$destination" || return 1
  while IFS= read -r -d '' file; do
    relative=${file#"$source/"}
    # This private interpreter runs ntpq, not arbitrary Python applications.
    # Omit unsupported consumers before measuring ELF closure, not afterwards.
    case "$relative" in
      sqlite3/*|xml/*|ssl.py|tarfile.py|__pycache__/ssl.cpython-311*.pyc|__pycache__/tarfile.cpython-311*.pyc|lib-dynload/_sqlite3*.so|lib-dynload/_ssl*.so|lib-dynload/pyexpat*.so|lib-dynload/_elementtree*.so) continue ;;
    esac
    install -d "$(dirname "$destination/$relative")" || return 1
    diagnostics_copy_debian "$file" "$destination/$relative" || return 1
  done < <(find -L "$source" -type f -print0)
}
