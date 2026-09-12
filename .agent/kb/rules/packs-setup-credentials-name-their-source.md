# Rule: a required credential says where it comes from

**Rule.** A `setup.env` var the pack cannot run without names the console
location or the exact command that mints it, alongside the permission or scope
it needs — `Settings → Auth Tokens`; `mc admin user add <alias> <access>
<secret>`; `GRANT pg_monitor TO emisar`. A var that is a filesystem path or an
address (`GIT_REPO`, `KAFKA_BOOTSTRAP`, `HAPROXY_SOCK`) is not a credential and
needs no such note.

**Why.** "Requires an API token with read access" is useless to an operator who
does not know how to obtain one, and `setup` is rendered on the public
`/packs/<id>` page — read BEFORE installing — as well as by `emisar pack info`
on the host. That page is the one that has to answer it; there is no later step
where we explain the credential.

**Keep it durable, and do not restate the summary.** Name the object to create
and the privilege to give it, not a deep menu path that rots with the vendor's
next redesign. Text the pack's `setup` summary already carries is not repeated
in the env description.

## Setup prose is lightly formatted

`/packs/<id>` renders each authored setup string through
`EmisarWeb.PacksRegistry.setup_segments/1` (`setup_text/1` in
`portal/apps/emisar_web/lib/emisar_web/controllers/marketing_html.ex`), so
write for that renderer:

- Wrap identifiers in markdown backticks — env var names, config keys such as
  `execution.inherit_env`, paths, and commands.
- Link with `[label](https://…)` when the vendor has a stable page that mints
  the credential, ideally one that pre-selects the scope:
  `https://github.com/settings/tokens/new?scopes=repo`.
- Only `https://` links render — anything else stays literal, which is also
  what keeps a pack from putting a hostile scheme on a public page.
- A bare URL is never auto-linked. Several packs deliberately put example
  connection strings in their prose, and those must stay inert text.
- A link label carries no backticks of its own.

**How it's enforced.** Review. The loader cannot tell a credential var from an
address var, and it cannot judge whether the named source really mints the
credential.
