#!/bin/bash
# Numeric socket diagnostics do not need RPC service-name lookup.
set -euo pipefail
cd /iproute-source
source_tree=(iproute2-*/)
[ "${#source_tree[@]}" -eq 1 ]
cd "${source_tree[0]}"
source_version=$(dpkg-parsechangelog -l debian/changelog -S Version)
[ "$source_version" = "$(dpkg-query -W -f='${source:Version}' iproute2)" ]
# libc development packages bring RPC headers with them. Disable only this
# optional configure probe; preserve detection of the other socket features.
cat > /iproute-source/pkg-config-no-rpc <<'SH'
#!/bin/sh
for argument in "$@"; do
  [ "$argument" != libtirpc ] || exit 1
done
exec /usr/bin/pkg-config "$@"
SH
chmod 0755 /iproute-source/pkg-config-no-rpc
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export CFLAGS CPPFLAGS LDFLAGS
CFLAGS=$(dpkg-buildflags --get CFLAGS)
CPPFLAGS=$(dpkg-buildflags --get CPPFLAGS)
LDFLAGS=$(dpkg-buildflags --get LDFLAGS)
PKG_CONFIG=/iproute-source/pkg-config-no-rpc ./configure
if grep -Eq 'HAVE_RPC|-ltirpc' config.mk; then
  echo 'ss configuration unexpectedly enables RPC' >&2
  exit 1
fi
make -j2 SUBDIRS='lib misc' TARGETS=ss
if readelf -d misc/ss | grep -Eq 'NEEDED.*(tirpc|gssapi|krb5)'; then
  echo 'ss still links RPC or Kerberos' >&2
  exit 1
fi
install -m 0755 misc/ss /usr/local/bin/ss
{
  printf 'source_version=%s\n' "$source_version"
  printf 'compiler='; gcc --version | sed -n '1p'
  printf 'CFLAGS=%s\nCPPFLAGS=%s\nLDFLAGS=%s\n' "$CFLAGS" "$CPPFLAGS" "$LDFLAGS"
  printf '%s\n' "make -j2 SUBDIRS='lib misc' TARGETS=ss; RPC configure probe disabled"
  sha256sum configure misc/ss /iproute-source/pkg-config-no-rpc
  cat /iproute-source/pkg-config-no-rpc
  cat config.mk
} > /iproute-source/private-build.txt
