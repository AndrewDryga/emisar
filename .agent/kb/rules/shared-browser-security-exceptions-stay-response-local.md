# Rule: browser security exceptions stay response-local

**Rule.** A browser security-policy relaxation added for an external integration
is assigned only after the request's client, destination, and other trust inputs
are validated. Scope it to the exact response that needs compatibility, retain
the strict base policy everywhere else, and keep relaxed navigation or form
targets application-controlled.

**Why.** Moving an integration workaround into a shared CSP or rendering a
caller-controlled target turns one compatibility exception into a repository-wide
exfiltration path. Rejected requests are especially important because validation
has not established the external party's identity or destination.

**Good.** A validated OAuth consent response adds its required form-action source
through response-local state, while the form posts to a fixed application route
and rejected requests retain the base policy.

**Bad.** Add an external scheme to the global CSP, assign the exception before
redirect validation, or render an untrusted URL into the relaxed form target.

**Sweep.** Search controller-assigned CSP extras, response-header overrides,
external redirect handling, and integration-specific form actions. Verify the
validation order, rejected response, fixed target, and escaping at each site.

**Enforced.** Focused controller and CSP tests pin the successful integration
response, rejected request policy, and fixed form action; security review covers
new response-level exceptions.
