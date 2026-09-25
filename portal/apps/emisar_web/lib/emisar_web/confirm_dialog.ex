defmodule EmisarWeb.ConfirmDialog do
  @moduledoc """
  Live-state helper for `CoreComponents.confirm_dialog/1`'s typed-confirm.

  The dialog's type-to-confirm field is a `phx-change="confirm_typed"` form, so
  the page holds the typed value in the `@typed` assign and the Confirm button
  renders `disabled={@typed != confirm_token}`. This module is the one place
  that state lives, so the pages wiring the dialog don't each re-implement
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

  `init/1` also clears `@typed` when a typed dialog's form submits its action.
  That submit is the only push that reaches the server: LiveView drops every
  later push from the same submit while it is in flight, so a `confirm_reset`
  chained after the action never arrives, and the next dialog would open with
  the text typed for the previous one.
  """
  alias Phoenix.{Component, LiveView}

  @doc "Seed the `@typed` assign and clear it on each typed dialog's submit. Call once in `mount`."
  def init(socket) do
    socket
    |> Component.assign(:typed, "")
    |> LiveView.attach_hook(:confirm_dialog, :handle_event, &reset_on_confirm/3)
  end

  # `confirm_dialog` marks its typed form with a hidden `confirm_dialog` field,
  # so a typed step-up form that reuses `confirm_token` keeps its value on a retry.
  defp reset_on_confirm("confirm_typed", _params, socket), do: {:cont, socket}
  defp reset_on_confirm(_event, %{"confirm_dialog" => _}, socket), do: {:cont, reset(socket)}
  defp reset_on_confirm(_event, _params, socket), do: {:cont, socket}

  @doc """
  Store the field value from the dialog's `phx-change` (`%{"confirm_token" => v}`).
  """
  def put_typed(socket, %{"confirm_token" => value}) when is_binary(value),
    do: Component.assign(socket, :typed, value)

  def put_typed(socket, _params), do: socket

  @doc "Clear the typed value — fired when the dialog opens, cancels, closes, or confirms."
  def reset(socket), do: Component.assign(socket, :typed, "")
end
