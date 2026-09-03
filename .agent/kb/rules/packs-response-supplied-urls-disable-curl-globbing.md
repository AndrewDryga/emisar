# Rule: Response-supplied URLs reach curl with globbing off

**Rule.** A URL the pack author did not write — one that arrives in an API
response (a presigned link, a pagination cursor URL, a discovery document's
URI) or is assembled from variable input — is fetched with curl globbing
disabled (`--globoff`) and the scheme confined (`--proto '=https'`, or
`'=http,https'` where the provider legitimately presigns plain HTTP; pin
`--proto-redir` and bound `--max-redirs` when redirects are followed). A URL
that is itself a credential — a presigned signature, a token in the query
string — additionally reaches curl through a config document on stdin
(`--config -`), never argv, output, stderr, or the audit trail. An anchored
shape check that rejects braces complements `--globoff`; it never replaces it.

**Why.** curl treats `{a,b}` and `[1-9]` in a URL as globs and expands them
into one transfer per alternative, so a response-controlled URL can fan a
single fetch out to hosts the response chose — handing a presigned signature
or an authenticated request to every host in the list. This is a reproduced
leak, not a theory: fetching `http://127.0.0.1:{18081,18082}/tail?sig=SECRET`
without `--globoff` delivered the signature to both listeners. Scheme
confinement keeps the same response from steering curl at `file://` or another
non-HTTP protocol, and argv is world-readable in process listings for the
duration of the transfer, which is what makes it the wrong place for a
credential-bearing URL. `--globoff` is also what lets a literal IPv6 host
(`[::1]`) through unexpanded, so a shape check need not — and must not —
admit braces to accommodate one.

**Good.** All four catalog instances comply; write the next one from them.

- `packs/hcp-terraform/scripts/tfc.sh` (`fetch_log_tail`) — the canonical
  case: the phase's presigned log-read URL arrives in the HCP API response,
  passes a brace-rejecting shape check, and is fetched with
  `curl -q --fail -s --globoff --proto '=http,https' … -K -`, the URL
  entering through the stdin config document.
- `packs/oidc-jwks/scripts/oidc.sh` (`fetch_json`) — the discovery document's
  `jwks_uri` is re-fetched only after an anchored HTTPS-only regex (no braces,
  no query, no userinfo), with `--globoff --proto '=https'
  --proto-redir '=https' --max-redirs 0`.
- `packs/gcp-billing/scripts/billing_export_query.sh` and
  `packs/gcp-monitoring/scripts/monitoring_api.sh` — the URL is built from a
  variable endpoint override plus arg-derived segments; both pass
  `--globoff --proto '=https'` and feed credentials through `--config -` on
  stdin.

```sh
printf 'url = "%s"\n' "$url" |
  curl -q --fail --silent --show-error --globoff --proto '=https' \
    --connect-timeout 10 --max-time 60 --config -
```

**Bad.**

```sh
curl --fail -sS "$log_read_url"
```

When the response supplies
`https://logs.example.com/{a.example,b.evil.example}/x?sig=…`, curl performs
one transfer per brace alternative and the presigned signature reaches the
host the response chose; the URL is also visible to every process on the box
while the transfer runs.

**Sweep.** Any curl invocation — an inline `execution.command` shell program
or a referenced `scripts/*.sh` — lacking `--globoff` (short form `-g`) or
`--proto`, or following redirects (`-L`) without `--proto-redir`.

**Enforced.** `validatePackCurlURLSafety` in
`tools/internal/devtool/pack_curl.go`, reached through `./run check packs`,
`./run pack check <name>`, and the packs gate, beside the response-error,
pipeline, and jq lints. The shared loader follows the action paths declared by
`pack.yaml`, not a filesystem glob.

Both flags are required of **every** curl invocation, not only the ones whose
URL is visibly response-supplied. Deciding that from the YAML means reasoning
about env defaults, argument interpolation, and redirect targets — and that
judgment is exactly what let the convention drift: when the check was written,
94 call sites across nine packs passed neither flag while sibling packs
building the same URL shape passed both. A fixed-URL call loses nothing by
carrying them.

The scanner folds `\`-continued lines before reading an invocation, and falls
back to judging the whole script when the flags arrive indirectly (`curl "$@"`
after a `set --`, or `"${curl_args[@]}"`).
