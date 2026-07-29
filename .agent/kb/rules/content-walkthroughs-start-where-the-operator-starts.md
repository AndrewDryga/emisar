# A walkthrough's first step is the operator's first action — and it links there

**Rule.** A third-party setup guide opens with a numbered step for the thing the
operator does first, in our product. It does not put that action in a
prerequisite paragraph, and it does not name a console path in bold without
linking it.

## Why

A prerequisite paragraph reads as background. "Have X open in another tab" is an
*instruction* wearing the clothes of a *precondition*, so it gets skimmed — and
then step 1 asks for a value that only exists on the page the reader never
opened. Numbering it makes it the thing it is.

Naming a path without linking it is the same failure one level down: if we know
where the page is, the reader should not have to go find it. A docs page cannot
know the reader's account slug, which is why the slugless deep links under
`/app/*` exist (`AccountRedirectController` — `/app/agents`, `/app/sso/new`).
Add one rather than describe a path.

## ✅ Good

```heex
<li class="flex gap-4">
  <span class="...">1</span>
  <div class="...">
    <.docs_step_venue>emisar</.docs_step_venue>
    <p class="font-semibold text-zinc-100">Start the connection.</p>
    <p class="mt-1.5">
      Open <a href={~p"/app/sso/new"} class="...">Team → Single sign-on → Add provider</a>
      and choose <strong class="text-zinc-200">Okta</strong>. Leave the page open: the
      callback URL on it is what Okta asks for next.
    </p>
  </div>
</li>
```

The step title does not repeat the venue — `<.docs_step_venue>` already said it.

## ❌ Bad

```heex
<p class="mt-5 ...">
  You need an Okta administrator and an emisar owner or admin, with
  <strong class="text-zinc-200">Team → Single sign-on → Add provider</strong>
  open in another tab so you can copy emisar's callback URL.
</p>
```

An action, unnumbered, unlinked, and filed under prerequisites.

## Sweep

Any `/docs` walkthrough whose opening paragraph contains an imperative ("open",
"keep … open", "have … ready") that names a console path, and any IMPERATIVE
`X → Y → Z` console path in docs prose with no link on it. A descriptive mention
("both are managed from Team → Single sign-on") is prose and stays prose — the
rule is about paths the reader is being told to go to.

## How it's enforced

Review. The five provider guides
(`docs_sso_{okta,entra,jumpcloud,keycloak,google_workspace}.html.heex`) are the
worked examples; they each open with an `IN EMISAR` step 1 linking
`~p"/app/sso/new"`.
