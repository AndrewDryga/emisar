#!/bin/bash
# Only cases selecting this directory on PATH replace the port-43 backend.
# RDAP always uses real curl and the independently served HTTP fixture.
set -euo pipefail
curl -fsS -X POST "http://rdap-api:8080/_whois/$1" >/dev/null
case "${PACKTEST_WHOIS_MODE:-failure}" in
failure) printf '%s\n' 'packtest-canary-rdap-contact-62c37' >&2; exit 1 ;;
partial) printf '%s\n' 'Registrar: Partial must not pass'; exit 1 ;;
empty) exit 0 ;;
empty-fields) printf '%s\n' 'Registrar:    ' 'Name Server:' ;;
unrecognized) printf '%s\n' 'WHOIS LIMIT EXCEEDED' ;;
success)
  printf '%s\n' 'Domain Name: EXAMPLE.DEV' 'Registrar: Fixture WHOIS Registrar' \
    'Registry Expiry Date: 2030-01-02T03:04:05Z' 'Name Server: NS1.EXAMPLE.DEV' \
    'Registrar Abuse Contact Email: packtest-canary-rdap-contact-62c37' \
    'Unrelated remark: registrar packtest-canary-rdap-contact-62c37'
  ;;
oversize) head -c 16777217 /dev/zero | tr '\0' x ;;
*) exit 2 ;;
esac
