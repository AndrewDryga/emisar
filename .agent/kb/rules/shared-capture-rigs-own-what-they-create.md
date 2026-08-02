# A capture rig owns what it creates in someone's tenant

**Rule.** A tool that creates anything in a third-party account — an application,
an OAuth client, a project, a user — must be able to LIST what it created and
REMOVE it, and must never report a tenant clean from a filter that could fail to
match. If it cannot list, it cannot claim.

This is not tidiness. These tenants belong to the founder and to customers-facing
certifications; litter accumulates silently, and one class of it actively breaks
later runs.

## Why

Four tenants were left dirty across two sessions, and the founder cleaned all four
by hand:

- **JumpCloud** — nine applications from repeated attempts. The cleanup existed but
  matched only rows labelled exactly `emisar`, so apps that were created without a
  label (a fuzzy field match had typed the name elsewhere) were invisible to the
  check that then reported "nothing to clean up".
- **Google** — OAuth clients from every capture run, plus four throwaway projects.
- **Okta** — app integrations, from a rig with no cleanup at all.
- **Entra** — enterprise applications, from a rig with no cleanup at all.

The JumpCloud case is the instructive one: the tool reported success from a filter
that could not see the failure, which is the same shape as a test that passes
because it never reached the code it claims to cover. A leftover also poisons the
work: JumpCloud's connection test provisions a probe user and deletes it only when
the check passes, so one interrupted run stranded that address and every later run
was refused activation.

## ✅ Good

- One distinctive, verified name for everything created. After typing it, read it
  back — a fuzzy field match that lands on the wrong input creates an object the
  cleanup cannot recognise as ours.
- A cleanup mode that prints EVERY object with a verdict beside it — deleting this,
  sparing that, and why — so a gap in the filter is visible rather than silent.
- Keepers identified by something they carry (a certificate, a known id), not by
  the absence of a match.
- Resources whose lifetime is one run are removed at the end of that run, not left
  for a sweep that may never come.

## ❌ Bad

- `if (!/emisar/.test(label)) continue` as the only filter, with "nothing to clean
  up" printed when it matches nothing.
- A rig that creates apps or users and offers no way to enumerate them.
- Reporting a tenant clean because a cleanup run said so, without listing what is
  actually there.
- A fixed name for a resource the third party requires to be unused (JumpCloud's
  Test User Email); one interrupted run then blocks every later one.

## Debugging a rig is not an exception

The worst instance of this was created while fixing it. Debugging a console flow
means running the rig over and over, and each run creates an object — six
applications accumulated in the founder's tenant during the very session that
introduced this rule, because cleanup was skipped "just while iterating".

So the guard belongs in the tool, not in the operator's intentions: a rig REFUSES
to create another object while earlier ones are still there, and says how many it
found. Iterating then forces a deliberate cleanup between runs instead of relying
on remembering.

Where a flow needs many attempts to learn, drive it with a step-through mode that
navigates and screenshots WITHOUT creating anything (`jumpcloud-capture -explore`),
and read the screen. Encoding a selector, running the whole pipeline and reading
the failure is a three-minute loop per click that also leaves an object behind;
looking at the page is thirty seconds and leaves nothing.

## How it is enforced

Review, and the tools themselves: `jumpcloud-capture -cleanup-apps` prints its full
inventory with a verdict per row, and creation fails loudly if the display label
did not land. `google-capture` has `-cleanup` for clients and `-delete-projects`
for projects.

`okta-capture -inventory`/`-cleanup` and `entra-capture/entra-inventory.mjs` list
and remove what they created, both through the provider's own API rather than the
console DOM — a virtualised list is exactly the surface that under-matches
silently. Okta's inventory covers applications, users AND api-tokens — a
long-lived credential is the last thing that should sit unlisted in a tenant,
whoever created it. Entra's covers both halves of what its rig makes — app
registrations and enterprise applications — follows Graph's paging to the last
row (a page cap under-lists as silently as a bad filter), and spares the one
keeper by the id it carries (the saved `ENTRA_CLIENT_ID` walkthrough app), never
by a name the delete filter happens to miss.

A rig that cannot enumerate says it cannot enumerate; "nothing to clean up" is a
claim, and a claim needs a listing behind it.

## Read the credential from where the rig keeps its credentials

`okta-capture` looked for its API token in the process environment only, while
every other secret it uses comes from its secrets file — where that token already
was. It reported a tenant it could not list, and the founder was asked to create a
credential they had already provided.

A missing-credential message is a claim like any other. Check every place the tool
legitimately stores one before making it.

## An over-broad filter is the same bug pointed the other way

The gap that hides leftovers and the filter that deletes something real are one
mistake: a pattern nobody checked against the actual tenant.

`okta-capture` matched users by `/emisar/` against their email. It created no
users at all — Okta is the identity provider, it pushes accounts outward — so
that pattern found no leftover. It found `andrew@emisar.dev`: the tenant's only
account, and the one the rig signs in WITH. A cleanup run would have deactivated
and deleted the admin that owns the tenant.

So: match what the rig demonstrably creates, never a domain that is also the
founder's; exclude the identity the rig authenticates as, whatever it is called;
and read the verdict column against the real tenant before running the delete.
