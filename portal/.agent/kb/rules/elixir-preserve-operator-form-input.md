# Operator form input survives re-renders, rejected submits, and reloads

**Rule.** Every field an operator can type into a LiveView form is **server-tracked**:
the form's `phx-change` handler assigns the posted params back (`to_form(params)`, or a
tracked assign per bare-named field), and every error branch of a submit handler
re-renders the operator's values, never the stale stored ones. On top of that, console
authoring forms whose content would hurt to lose opt into the **`PreserveInput`**
sessionStorage hook (`phx-hook="PreserveInput"` + a stable form `id`) so a reload or
accidental navigation restores the draft. Identity fields carry real `autocomplete`
tokens (`email`, `name`, `organization`, `one-time-code`) so the browser can do its own
half of not-retyping.

## Why

LiveView's DOM patch resets **every non-focused input** to the server's rendered value —
only the focused input is merged. So any re-render the operator didn't cause (a
co-approver's broadcast, a 5-second poll tick, a refused decision, a conditional reveal)
silently wipes whatever the server wasn't told about. A page refresh loses everything by
construction: the values live in server assigns that die with the socket. An operator
halfway through a deny justification or a runbook dispatch reason loses real work, on a
page where re-renders are the *norm*. This shipped four separate wipe bugs in one sweep:
the approval decision panel's untracked note/match/cap, the activate page's hand-typed
code, the team roster's name editor, and the landing CTA's email dropped on `/sign_up`.

## ✅ Good — tracked fields; the failure path re-renders what was posted

```elixir
# approval_detail_live.ex — bare-named fields, each backed by an assign
def handle_event("grant_form_changed", params, socket) do
  {:noreply,
   socket
   |> assign(:grant_duration, params["duration"] || "once")
   |> assign_decision_fields(params)}
end

defp decision_failed(socket, :self_approval_forbidden, params) do
  # The form stays live (they can still Deny), so the note comes back with it.
  {:noreply,
   socket
   |> assign_decision_fields(params)
   |> put_flash(:error, "You can't approve your own request.")}
end
```

```heex
<form id="approval-decision-form" phx-hook="PreserveInput" phx-submit="decide" phx-change="grant_form_changed">
  <.input type="textarea" name="reason" value={@decision_reason} ... />
</form>
```

## ❌ Bad — uncontrolled fields, or an error branch that re-renders stale state

```heex
<%!-- value={nil}: any re-render — a broadcast, a countdown — wipes the note --%>
<.input type="textarea" name="reason" value={nil} ... />
```

```elixir
# The error branch keeps the OLD form assign; the typed name snaps back.
def handle_event("save_edit", %{"user" => params}, socket) do
  case Accounts.update_user_as_admin(membership, params, subject) do
    {:ok, _user} -> ...
    {:error, _} -> {:noreply, socket}   # @edit_form still holds the stored name
  end
end
```

## PreserveInput boundaries

- **The `skip/1` list is the security boundary** (`assets/js/preserve_input.js`): never
  persisted — `password`/`hidden`/`file` inputs, `one-time-code` and `cc-*` autocomplete
  fields, disabled/readonly fields, anything inside `phx-update="ignore"`, and explicit
  `data-preserve="off"`. Extend the skip list; **never invert it into an allowlist** — a
  new sensitive field must be excluded by default. The `autocomplete` token on a code
  field is load-bearing here: it's what tells the hook to skip it.
- `sessionStorage`, deliberately not `localStorage`: drafts are run arguments, deny
  justifications, and directory config — they die with the tab.
- Only for forms whose **field structure is fixed**. A structure-editing surface (the
  runbook editor's step list, a policy's override rows) can't be faithfully rebuilt from
  a name-keyed snapshot — it needs a server-side draft, not this hook.
- The hook needs a stable form `id` (LiveView requires one for any `phx-hook` anyway);
  the storage key is `form:<pathname>:<id>`, so the path scopes a draft to its account and
  entity.

## Which forms opt in

**Yes** — console forms whose fields are fixed and whose content is the operator's own
work: dispatch (args + reason), runbook dispatch, the approval decision panel, API keys,
enrollment keys, invites, the member name editor, SSO provider config.

**No**, for three distinct reasons:
- **Auth and identity forms** (sign in, sign up, invite acceptance, workspace creation,
  the profile name/email edits) — the browser's own autofill covers
  name/email/organization, so they get the `autocomplete` token instead of our stored
  copy of the operator's PII.
- **Sensitive entry** (MFA challenge, email step-up) — `code_input` is already
  client-owned under `phx-update="ignore"`, and a one-time code must not outlive its
  request.
- **Structure-editing surfaces** — see above; a name-keyed snapshot mis-assigns.

URL-driven filter bars (`LiveTable`) need neither: their state is in the query string, so
a reload already restores them.

## How it's enforced

Judgment + review + tests, not a Credo check (an AST check can't tell an uncontrolled
input from a deliberately client-owned one). Each opted-in form's LiveView test asserts
`phx-hook="PreserveInput"` presence; the wipe fixes carry re-render regression tests
(`approval_detail_live_test.exs`, `team_live_test.exs`, `activate_live_test.exs`,
`user_sign_up_live_test.exs`). On review, sweep for: `value={nil}` or a bare-named input
with no backing assign inside a form that has `phx-change`, and `handle_event` error
branches that neither re-assign the posted params nor navigate away.
