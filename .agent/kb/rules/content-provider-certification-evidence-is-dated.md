# Provider certification evidence is dated

## Rule

Every third-party SSO provider guide ends with a literal evidence footer stating
what the guide was checked against and when.

- Live-org or live-tenant verification wording, with its date, is allowed only
  when durable evidence records that verification against the real provider.
- Without that evidence, the footer uses guide-review wording and makes no
  certification claim.
- Any evidence claim in the `/docs/sso` overview repeats the provider footer's
  wording and date; it never states a stronger level or a different date.
- A recertification changes the owning HEEx footer and its exact marketing-test
  sentence in the same change. Dates are never advanced by editorial work,
  screenshot recapture, or assumption.

## Why

"Verified against a live tenant" is a compatibility promise a buyer uses to
decide whether the integration will work in their own directory. An undated
claim cannot be aged out, and a date advanced from an unrelated copy edit turns
that promise into a guess. Keeping the two wordings distinct means a reader can
tell which guides someone actually ran end to end and which ones were only read.
The overview inherits the same limit, so a summary cannot promise more than the
page it links to.

## Good

```heex
<.docs_layout
  current="integrations-okta"
  updated="July 31, 2026"
  evidence="Verified against a live Okta Integrator org on July 27, 2026."
  source_path="…/docs_sso_okta.html.heex"
>
```

```heex
<.docs_layout
  current="integrations-keycloak"
  updated="July 31, 2026"
  evidence="Guide reviewed July 31, 2026."
  source_path="…/docs_sso_keycloak.html.heex"
>
```

## Bad

```heex
<%!-- No evidence footer at all; the reader cannot age the claim. --%>
<.docs_layout current="integrations-entra" updated="July 31, 2026" source_path="…">
```

```text
— one custom application carries sign-in and provisioning together. Certified on
a live tenant.
```

An undated certification sentence, and — worse — one on a provider whose guide
footer only claims a review.

## Enforcement

`portal/apps/emisar_web/test/emisar_web/marketing_test.exs` maps each provider
route to its exact evidence sentence, so a reworded or re-dated footer fails the
suite. Sweep target when a claim changes: the five provider pages
(`docs_sso_okta`, `docs_sso_jumpcloud`, `docs_sso_entra`,
`docs_sso_google_workspace`, `docs_sso_keycloak` `.html.heex`), the provider
guides list in `docs_sso.html.heex`, and that route map in `marketing_test.exs`.
