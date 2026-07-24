# Rule: HTTP API actions fail on response errors

**Rule.** A pack action that calls an HTTP API with `curl` uses `-f`/`--fail`
or explicitly validates that the returned status is 2xx. A 4xx or 5xx response
must produce a failed action result. The only exception is an action whose
declared job is to inspect and report an arbitrary HTTP response, such as the
`network-tls` probes.

**Why.** Curl treats a completed HTTP exchange as process success by default.
Without response-status enforcement, missing credentials, insufficient
permissions, invalid paths, and server failures can all be recorded as
successful infrastructure work. This is especially dangerous for mutations:
an operator or agent may continue under the false belief that the requested
change occurred.

**Good.**

```sh
curl -fsS -H @- "$API_URL/resource"
```

```sh
code=$(curl -sS -o "$body" -w '%{http_code}' "$API_URL/resource")
case "$code" in
	2*) ;;
	*) exit 1 ;;
esac
```

**Bad.**

```sh
curl -sS -H @- "$API_URL/resource"
```

This exits zero after a 401, 403, 404, or 500 response.

**Sweep.** Inspect `execution.command` and every referenced `execution.script`
under `packs/*/actions/`. Look for curl invocations without a short option
containing `f`, `--fail`, or an explicit 2xx status check. For credentialed
packs, exercise one invalid credential in the pack behavior plan when a
disposable service model exists.

**Enforced.** `./run check packs`, `./run pack check <name>`, and
`./run gate packs` reject curl-backed actions that neither fail on HTTP errors
nor belong to the narrow status-reporting exception set. Unit fixtures cover
inline shell commands, direct curl argv, packaged scripts, manual 2xx checks,
and diagnostic exceptions.
