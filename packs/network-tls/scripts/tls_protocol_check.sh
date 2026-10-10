#!/bin/sh
set -eu

host=$1
port=$2

# One reachability probe before the version loop. Without it a DNS failure, a
# closed port, or a blocked egress path prints FAIL for all four versions, and
# a compliance audit reads that as "every weak protocol is off".
reach=$(openssl s_client -brief -connect "$host:$port" -servername "$host" </dev/null 2>&1 || true)
case $reach in
  *connect:errno=* | *"Connection refused"* | *"Connection timed out"* | \
  *"No route to host"* | *"Name or service not known"* | *getaddrinfo*)
    printf 'cannot reach %s:%s: %s\n' "$host" "$port" \
      "$(printf '%s\n' "$reach" | head -n 1)" >&2
    exit 1
    ;;
esac

# OK           the server completed a handshake at this version.
# REFUSED      this probe did not negotiate; other handshake policy can fail too.
# UNSUPPORTED  this runner's OpenSSL cannot offer the version at all, so the
#              server's position is unknown — never report it as refused.
for version in tls1 tls1_1 tls1_2 tls1_3; do
  set -- "-$version"
  case $version in
    tls1) protocol=TLSv1; set -- "$@" -cipher 'DEFAULT:@SECLEVEL=0' ;;
    tls1_1) protocol=TLSv1.1; set -- "$@" -cipher 'DEFAULT:@SECLEVEL=0' ;;
    tls1_2) protocol=TLSv1.2 ;;
    tls1_3) protocol=TLSv1.3 ;;
  esac
  result=$(openssl s_client -brief -connect "$host:$port" -servername "$host" \
    "$@" </dev/null 2>&1 || true)
  # A certificate can precede a failed handshake. Require OpenSSL's completed
  # connection and negotiated version, even if a later shutdown exits nonzero.
  if printf '%s\n' "$result" | grep -Fx 'CONNECTION ESTABLISHED' >/dev/null &&
    printf '%s\n' "$result" | grep -Fx "Protocol version: $protocol" >/dev/null; then
    verdict=OK
  else
    case $result in
    *"unknown option"* | *"Unknown option"* | *"no protocols available"*)
      verdict=UNSUPPORTED-BY-CLIENT
      ;;
    *) verdict=REFUSED ;;
    esac
  fi
  printf '%s: %s\n' "$version" "$verdict"
done
