#!/usr/bin/env bash
# Pre-cutover verification for the emisar.dev → Cloud DNS migration.
#
# Run AFTER `terraform apply` (the zone exists) but BEFORE changing the
# nameservers at the registrar. It queries the new Cloud DNS nameserver directly
# and checks every critical record, so you delegate NS only once the new zone is a
# faithful replica of what's live PLUS the intended new security records. Any
# problem exits non-zero — do NOT cut over on a red.
#
# Usage:  ./verify-cutover.sh <new-nameserver>
#   e.g.  ./verify-cutover.sh "$(terraform output -raw nameservers | head -1)"
#
# Smoke-test the script itself first by passing the CURRENT authoritative NS
# (ns55.domaincontrol.com): every PORTED record matches live, and the ADDED
# records correctly report as not-yet-present (they exist only in the new zone).

set -uo pipefail
NEW_NS="${1:?usage: verify-cutover.sh <new-nameserver>}"
DOMAIN="${DOMAIN:-emisar.dev}"

# Ported from GoDaddy — the new zone must answer IDENTICALLY to live.
PORTED=(
  "@:A" "@:AAAA" "@:MX" "@:TXT"
  "www:CNAME" "_acme-challenge:CNAME" "_fly-ownership:TXT"
  "google._domainkey:TXT" "20260603061232pm._domainkey:TXT"
  "pm-bounces:CNAME" "status:CNAME"
)
# Added in this migration — must be PRESENT (non-empty) in the new zone.
ADDED=("_dmarc:TXT" "@:CAA" "_smtp._tls:TXT" "_mta-sts:TXT" "mta-sts:CNAME")

fqdn() { [[ "$1" == "@" ]] && echo "$DOMAIN" || echo "$1.$DOMAIN"; }
# Reassemble multi-string TXT (strip the "chunk" "chunk" joins) so a DKIM key that
# Cloud DNS splits differently than GoDaddy doesn't read as a false mismatch.
ans() { dig "$@" +short 2>/dev/null | sed 's/" "//g' | sort | tr '\n' '|'; }

fail=0
echo "Comparing new nameserver ($NEW_NS) against the live zone…"
for rec in "${PORTED[@]}"; do
  h="${rec%%:*}"; t="${rec##*:}"; f="$(fqdn "$h")"
  new="$(ans "@$NEW_NS" "$f" "$t")"; live="$(ans "$f" "$t")"
  if [[ "$new" == "$live" && -n "$new" ]]; then
    printf '  ok       %-34s %s\n' "$f" "$t"
  else
    printf '  DIFF     %-34s %s\n             new:  %s\n             live: %s\n' \
      "$f" "$t" "${new:-<empty>}" "${live:-<empty>}"
    fail=1
  fi
done
for rec in "${ADDED[@]}"; do
  h="${rec%%:*}"; t="${rec##*:}"; f="$(fqdn "$h")"
  new="$(ans "@$NEW_NS" "$f" "$t")"
  if [[ -n "$new" ]]; then
    printf '  ok       %-34s %s (new)\n' "$f" "$t"
  else
    printf '  MISSING  %-34s %s — expected in the new zone\n' "$f" "$t"
    fail=1
  fi
done

echo
if [[ "$fail" -ne 0 ]]; then
  echo "NOT SAFE — resolve the differences above before delegating nameservers."
  exit 1
fi
echo "All records verified. Safe to delegate nameservers. Then, AFTER NS resolves,"
echo "publish the DNSSEC DS and confirm: dig +dnssec $DOMAIN shows the 'ad' flag."
