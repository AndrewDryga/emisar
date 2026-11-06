# Rule: a form submit that ends at an identity provider goes through the handoff page

**Rule.** When a browser form submission must end on an external identity
provider (SSO sign-in, step-up, linking, MFA re-verification), post it to a
Portal route that renders the SSO handoff page, and let that page navigate to the
provider. Never answer the form POST with a redirect to the provider.

**Why.** The base browser policy is `form-action 'self'`, and Chromium applies
`form-action` to every redirect a form submission follows. A POST that 302s to
the provider is blocked in the browser even though controller tests, which don't
enforce CSP, pass. The flow then dies silently after the click. This shipped twice:
the second time in the sign-in, MFA setup, profile and Team SSO forms
(fixed in b46d996bb, task 2026-11-05-send-sso-form-submissions-to-the-idp-through-the).

**Good.** The form posts to `SSOController`, which validates the request and
renders `sso_html/identity_redirect.html.heex`; that page navigates to the
provider URL the server just built.

**Bad.** `redirect(conn, external: provider_url)` from a form POST, or a LiveView
`push_navigate`/`redirect(external:)` triggered by a submit that targets the
provider.

**Sweep.** Search form-submit handlers and controller actions reached from forms
for `redirect(conn, external:` and LiveView external redirects to provider URLs;
each must go through the handoff page.

**Enforced.** Controller tests pin that each SSO form route renders the handoff
page (not a 302 to the provider). The real proof is a Chromium run under the
production CSP, which a UI change to these flows needs.
