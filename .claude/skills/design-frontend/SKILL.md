---
name: design-frontend
description: Put on the pragmatic front-end hat for the emisar Phoenix UI and marketing HEEx — build correct LiveView/operator UI with CoreComponents and LiveTable, or execute public marketing pages from creative direction with server-rendered HEEx + Tailwind. Use when implementing or changing a LiveView, HEEx template, component, operator UI, or controllers/marketing_html page in apps/emisar_web.
effort: medium
argument-hint: "[LiveView, HEEx, or marketing surface]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Front-end hat (pragmatic LiveView)

Ship the smallest thing that works and reads clearly. LiveView-first for the
operator console: the server holds the state, HEEx renders it, JS only when
LiveView genuinely can't. Marketing pages are different: they are public,
server-rendered HEEx and may have a distinctive visual language directed by
`design-creative-director`, as long as they remain fast, crawlable, accessible, and
honest.

## Pick the surface first

- **Operator console / LiveView:** follow the CoreComponents, LiveTable, and IL-18
  rules below. Consistency and calm matter more than novelty.
- **Marketing pages (`controllers/marketing_html/**`):** use `design-creative-director`
  for art direction and `content-seo` for crawlable positioning. Custom section
  layouts are allowed; generic SaaS templates are not. Keep real content in the
  initial HTML, avoid unnecessary dependencies, and verify with rendered desktop
  and mobile screenshots.

## Reuse before you build

- **`EmisarWeb.CoreComponents` first.** It's large and already covers buttons,
  inputs, tables, modals, flash, etc. Grep it before writing markup; extend it only
  if the primitive is genuinely missing — and then it's shared, not one-off.
- **`EmisarWeb.LiveTable`** for any list/table: it's stateless and URL-driven. Feed
  it `LiveTable.params_to_opts(params, Query.filters())` → `Repo.list/3`. Don't
  hand-roll pagination, sorting, or filtering.
- Match the existing screens' Tailwind utility patterns. Don't invent spacing/color
  scales; reuse what layouts and CoreComponents already use.

## LiveView Iron Law (IL-18 — Credo won't catch these; you must)

- **No unconditional DB/context read in `mount`** — `mount` runs twice. Use
  `assign_async`, or `connected?(socket)` with a cheap disconnected branch.
- **`stream/3` for any list that can grow** (runs, audit events, runners). Never
  `assign(socket, :events, big_list)` — it bloats socket memory per connection.
- **`connected?(socket)` guard before any PubSub `subscribe`** (live runner/run
  status updates), or you double-subscribe.
- **Never `assign_new` for per-mount values** (`current_user`, locale) — use `assign/3`.
- Authorize in **every** `handle_event` by routing through a context call with the
  subject (IL-15). The button being hidden is not authorization.

## Pragmatic rules

- One component, one job. Pass data in via `attr`/`slot`; don't reach into parent
  assigns. Function components for stateless UI; a LiveComponent only when it owns
  state.
- Loading / empty / error states are part of the component, not a later pass (the
  `/design-ux` hat will ask for them).
- Keep markup readable: no deeply nested conditionals in HEEx — compute in the LV,
  render flat. Extract a function component when a block repeats.
- Forms use `to_form/2` + CoreComponents inputs; show changeset errors (IL-18's
  sibling: if a save "silently fails", check `{:error, changeset}` first).

## Finish

`cd portal && mix compile --warnings-as-errors && mix format`, click-test the happy
path + one error path, and confirm lists stream. Then `mix test` the LV test if one
exists. Before a rendered surface is done, run the `design-interface-polish`
micro-craft pass (concentric radius, tabular numbers on live counts, hit areas,
transition specificity) — calm on the console, expressive on marketing. Hand UX
judgment calls to `/design-ux`; keep this hat on the implementation.
