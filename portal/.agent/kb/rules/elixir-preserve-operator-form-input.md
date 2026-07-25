# Operator form input survives re-renders and rejected submits

**Rule.** Every field an operator can type into a LiveView form is **server-tracked**: the
form's `phx-change` handler assigns the posted params back (`to_form(params)`, or a tracked
assign per bare-named field), and every error branch of a submit handler re-renders the
operator's values, never the stale stored ones. Identity fields carry real `autocomplete`
tokens (`email`, `name`, `organization`, `one-time-code`) so the browser can do its own
half of not-retyping.

## Why

LiveView's DOM patch resets **every non-focused input** to the server's rendered value —
only the focused input is merged (`onBeforeElUpdated`'s `isFocusedFormEl` branch). So any
re-render the operator didn't cause by typing in that exact field (a co-approver's
broadcast, an expiry countdown, a sibling `phx-change`, a refused decision) silently wipes
whatever the server wasn't told about. This shipped four separate wipe bugs in one sweep:
the approval decision panel's untracked note/match/cap, the activate page's hand-typed
code, the team roster's name editor, and the landing CTA's email dropped on `/sign_up`.

Server-tracking is also what makes LiveView's **built-in form recovery** work. On a
reconnect (not a reload — `getFormsForRecovery` returns `{}` when `joinCount === 0`)
LiveView replays each `phx-change` form's values to the server, so a field the change
handler ignores is replayed and then dropped on the floor. Adding `phx-change` to a form
that lacked one (the team name editor) fixes the reconnect case for free.

## ✅ Good — tracked fields; the failure path re-renders what was posted

```elixir
# approval_detail_live.ex — bare-named fields, each backed by an assign (the submit
# buttons post `decision=approve|deny` beside them, so a namespaced form would collide)
defp assign_decision_fields(socket, params) do
  socket
  |> assign(:decision_reason, params["reason"] || "")
  |> assign(:grant_scope, params["scope"] || "exact_args")
  |> assign(:grant_max_uses, params["max_uses"] || "")
end

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
<.input type="textarea" name="reason" value={@decision_reason} aria-label="Decision note" />
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

## What this does NOT cover — a full page reload

A reload re-mounts from the database, so unsaved input is gone. That is accepted: we tried
a `sessionStorage` hook (`PreserveInput`) and **removed it**, because for these forms it
cost more than it returned. What it bought was a refresh on nine mostly-short forms; what
it cost was 113 lines of stateful client code whose lifecycle interacted with framework
internals in ways that produced two non-obvious bugs — a patch wiping restored values
before the server knew about them, and `destroyed()` recomputing its storage key after
`push_navigate` had already moved the URL, which left a completed run's args and reason to
prefill the *next* dispatch (a stale justification headed for the audit trail). Both were
findable only by driving the hook in a real browser, which needs test infrastructure this
repo deliberately doesn't have.

**Don't reintroduce a client-side draft store for an ordinary form.** If a surface genuinely
can't afford to lose a reload, that's a server-side draft — and it is only worth its cost
where the authoring session is long: the runbook editor and the policies editor, whose
operator-editable *structure* (steps added, reordered; override rows) a name-keyed client
snapshot could never have rebuilt anyway. Weigh it honestly there too: `phx-change` fires
per keystroke so it needs throttling, and it moves deny justifications and directory config
into Postgres — backups, replication, DR snapshots, plus a retention sweep — a larger
data-at-rest footprint than anything client-side, on a security product.

## How it's enforced

Judgment + review + tests, not a Credo check (an AST check can't tell an uncontrolled input
from a deliberately client-owned one). The wipe fixes carry re-render regression tests
(`approval_detail_live_test.exs`, `team_live_test.exs`, `activate_live_test.exs`,
`user_sign_up_live_test.exs`). On review, sweep for: `value={nil}` or a bare-named input
with no backing assign inside a form that has `phx-change`, and `handle_event` error
branches that neither re-assign the posted params nor navigate away.
