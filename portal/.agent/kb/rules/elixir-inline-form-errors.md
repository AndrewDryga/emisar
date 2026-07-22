# Inline form errors — never a redirect + top-of-page flash

**Rule.** A form's own submission error — one the operator can fix by editing what they
just typed (a wrong code, a rejected field, a failed check) — is shown **inline at the
form**, right by the input. Never bounce it to a top-of-page flash via a
`put_flash(:error, …) |> redirect(…)`.

If the value is only knowable after a server check, **verify it in a LiveView
`handle_event` and `assign` the error** — don't POST to a controller that redirects on
failure. A LiveView can't set the auth session cookie, so on *success* hand off to a
controller (a short-lived, browser-bound handoff); but *failure* stays on the page.

## Why

The operator's attention is on the field they just filled. A redirect throws the "what
went wrong" to the top of a freshly-reloaded page — far from the "what to fix" — and the
reload wipes what they typed. Worse here: our top-right flashes **auto-dismiss** (info 5s
/ error 7s, the `FlashAutoClose` hook), so the redirect-flash often vanishes before it's
read. The magic-link code did exactly this: type 6 chars → auto-submit → wrong → redirect
to `?sent=1` → a far-off flash that fades → and (because the cookie was cleared) a forced
resend. Three separate frustrations, one root cause.

## ✅ Good — verify in the LiveView, error inline

```elixir
# magic_link_live.ex
def handle_event("verify_code", %{"code" => code}, socket) do
  with true <- is_binary(socket.assigns.token_id),
       {:ok, user} <- Auth.verify_magic_link(socket.assigns.token_id, code, socket.assigns.nonce) do
    handoff = MagicLinkHandoff.sign(user.id, socket.assigns.registered?, socket.assigns.token_id)
    {:noreply, redirect(socket, to: ~p"/sign_in/magic/complete?#{[handoff: handoff]}")}  # success navigates — fine
  else
    _ -> {:noreply, assign(socket, :code_error, "That code didn't match or has expired.")}  # stays put, inline
  end
end
```
```heex
<.code_input id="magic-code" name="code" label="Sign-in code" error={@code_error} />
```

## ❌ Bad — controller POST that redirects the error to a top flash

```elixir
def magic_link_verify_code(conn, %{"code" => code}) do
  case Auth.verify_magic_link(...) do
    {:ok, user} -> log_in_user(conn, user)
    _ ->
      conn
      |> put_flash(:error, "That code didn't match. Resend a fresh one below.")
      |> redirect(to: ~p"/sign_in/magic?sent=1")   # reload; error lands at the top, far from the boxes, then fades
  end
end
```

## When `put_flash(:error) |> redirect` IS right

It's correct for what **isn't** a fixable form error and has **no input to return to**: an
auth denial, a dead / expired / rate-limited link click (a GET, not a typed form), an
OAuth/SSO callback failure, a cross-account 404. There's no field there to annotate — a
page-level flash is the honest place. (See `user_confirmation_controller`, `sso_controller`
— link/OAuth flows, deliberately flash-and-redirect.)

## How it's enforced

Judgment + review, not a Credo check (an AST check can't tell a fixable-form-error
`put_flash|>redirect` from a legitimate dead-link one). On review, flag any controller that
handles a **typed form POST** and redirects with an `:error` flash on a user-fixable
failure — move the verification into the LiveView and render the error inline. The
`code_input` component carries an `error` attr for exactly this.
