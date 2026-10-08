#!/bin/bash
# Same signed Debian source and ABI, only the private interpreter is rebuilt.
set -euo pipefail
cd /python-source
source_tree=(python3.11-*/)
[ "${#source_tree[@]}" -eq 1 ]
cd "${source_tree[0]}"
source_version=$(dpkg-parsechangelog -l debian/changelog -S Version)
[ "$source_version" = "$(dpkg-query -W -f='${source:Version}' python3.11-minimal)" ]
python3 -B -P -S /build/python-identity.py > /python-source/installed-identity.json
# Debian regenerates configure after applying its signed archive patches.
autoconf
install -d private-build/Modules
cd private-build
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export CFLAGS CPPFLAGS LDFLAGS
CFLAGS=$(dpkg-buildflags --get CFLAGS)
CPPFLAGS=$(dpkg-buildflags --get CPPFLAGS)
LDFLAGS=$(dpkg-buildflags --get LDFLAGS)
../configure --prefix=/usr --libdir="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
  --enable-ipv6 --with-computed-gotos --without-ensurepip
# Preserve Debian's minimal static module set: it is not supplied as .so files.
# makesetup is first-rule-wins; restore static mode after the disabled block.
printf '%s\n' '*disabled*' pyexpat _elementtree '*static*' > Modules/Setup.local
modules=$(awk -v ORS='|' '$2 == "extension" && $1 != "pyexpat" && $1 != "_elementtree" {print $1}' ../debian/PVER-minimal.README.Debian.in)
grep -E "^#(${modules}XX)" ../Modules/Setup | \
  sed -e 's/^#//' -e 's/-Wl,-Bdynamic//;s/-Wl,-Bstatic//' >> Modules/Setup.local
../Modules/makesetup -c ../Modules/config.c.in -s Modules \
  Modules/Setup.local Modules/Setup.bootstrap Modules/Setup.stdlib ../Modules/Setup
mv config.c Modules/config.c
make Makefile Modules/config.c
# Exact Debian post-configure repair: the duplicate math rule loses PIC flags.
sed '/^Modules\/_math.o: .*PY_STDMODULE_CFLAGS/d' Makefile > Makefile.fixed
mv Makefile.fixed Makefile
# platform builds the interpreter and its own sysconfig, not distribution modules.
make -j2 platform
./python -B -P -S /build/python-identity.py > /python-source/private-identity.json
python3 -B -P -S - /python-source/installed-identity.json /python-source/private-identity.json <<'PY'
import json
import pathlib
import sys
installed, private = [json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:]]
assert installed["abi"] == private["abi"], (installed["abi"], private["abi"])
assert set(private["builtins"]) == set(installed["builtins"]) - {"pyexpat", "_elementtree"}
PY
if readelf -d python | grep -q 'NEEDED.*libexpat'; then
  echo 'private interpreter still links XML parser' >&2; exit 1
fi
install -m 0755 python /python-source/private-python
# Retain exact configuration and compiler identity for independent inspection.
{ printf 'source_version=%s\n' "$source_version"; printf 'compiler='; gcc --version | sed -n '1p';
  printf 'CFLAGS=%s\nCPPFLAGS=%s\nLDFLAGS=%s\n' "$CFLAGS" "$CPPFLAGS" "$LDFLAGS";
  sha256sum ../configure pyconfig.h; cat Modules/Setup.local;
} > /python-source/private-build.txt
