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
- **Okta** — app integrations, and USERS, from a rig with no cleanup at all.
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

## How it is enforced

Review, and the tools themselves: `jumpcloud-capture -cleanup-apps` prints its full
inventory with a verdict per row, and creation fails loudly if the display label
did not land. `google-capture` has `-cleanup` for clients and `-delete-projects`
for projects.

`okta-capture` and `entra-capture` still have NO inventory or cleanup — they create
app integrations, users and enterprise applications with no way to find them again.
That is tracked, and until it is closed, do not claim either tenant is clean.
