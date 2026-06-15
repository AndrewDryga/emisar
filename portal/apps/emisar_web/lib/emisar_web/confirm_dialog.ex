defmodule EmisarWeb.ConfirmDialog do
  @moduledoc """
  Live-state helper for `CoreComponents.confirm_dialog/1`'s typed-confirm.

  The dialog's type-to-confirm field is a `phx-change="confirm_typed"` form, so
  the page holds the typed value in the `@typed` assign and the Confirm button
  renders `disabled={@typed != confirm_token}`. This module is the one place
  that state lives, so the four pages wiring the dialog don't each re-implement
  it. It is **pure UX** — the typed value gates only whether Confirm dispatches
  the event in the browser; every destructive `handle_event` stays
  server-authz-gated (its `Permissions.gated` / context `%Subject{}` check) and
  refuses a crafted event that bypasses the dialog.

  A LiveView using a confirm dialog calls `init/1` in `mount` and delegates the
  two shared events:

      def handle_event("confirm_typed", params, socket),
        do: {:noreply, ConfirmDialog.put_typed(socket, params)}

      def handle_event("confirm_reset", _params, socket),
        do: {:noreply, ConfirmDialog.reset(socket)}
  """
  alias Phoenix.Component

  @doc "Seed the `@typed` assign. Call once in `mount`."
  def init(socket), do: Component.assign(socket, :typed, "")

  @doc """
  Store the field value from the dialog's `phx-change` (`%{"confirm_token" => v}`).
  """
  def put_typed(socket, %{"confirm_token" => value}) when is_binary(value),
    do: Component.assign(socket, :typed, value)

  def put_typed(socket, _params), do: socket

  @doc "Clear the typed value — fired when the dialog opens, cancels, or closes."
  def reset(socket), do: Component.assign(socket, :typed, "")
end
