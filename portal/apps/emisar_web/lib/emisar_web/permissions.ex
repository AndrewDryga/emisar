defmodule EmisarWeb.Permissions do
  @moduledoc """
  Thin web helper for permission-gated LiveView event handlers.

  Authorization itself is a **domain** concern: ask the relevant context's
  `subject_can_<verb>?/1` predicate (e.g. `Runners.subject_can_manage_auth_keys?/1`)
  and pass its boolean result here. `gated/3` only flashes a denial and
  short-circuits when the action isn't allowed — a backstop for a control the
  template already hid via the same predicate. The context function the handler
  ultimately calls re-checks the permission anyway, so this is pure UX.

      def handle_event("revoke", %{"id" => id}, socket) do
        Permissions.gated(
          socket,
          Runners.subject_can_manage_auth_keys?(socket.assigns.current_subject),
          &do_revoke(&1, id)
        )
      end
  """

  def gated(socket, allowed?, fun) when is_boolean(allowed?) and is_function(fun, 1) do
    if allowed? do
      fun.(socket)
    else
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end
end
