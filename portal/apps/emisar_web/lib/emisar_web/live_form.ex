defmodule EmisarWeb.LiveForm do
  @moduledoc """
  The changeset shape a `phx-change` render should use.

  `Map.put(changeset, :action, :validate)` is what makes `Phoenix.HTML.Form`
  render errors, and a `phx-change` event carries EVERY field in the form — so
  doing it on change accuses the operator of leaving blank the fields they simply
  have not reached yet. Picking `Microsoft Entra` from a provider dropdown put
  "can't be blank" under Issuer URL before the cursor had ever been in it.

  Errors after the operator touches a field or submits, never before.
  """

  @doc """
  Mark a changeset validated for live feedback, keeping only the errors the
  operator has actually earned.

  An error renders when its field either holds a value — a malformed issuer, a
  name that is too long, feedback about their own input — or is the field this
  event came from, so clearing a name still reports blank immediately. Fields
  they have not reached stay quiet.

  `event_params` is the whole `phx-change` payload, not the nested form map:
  LiveView puts the changed field in `"_target"`, which is the only real signal
  for "the operator is editing THIS". Without it, blank-because-untouched and
  blank-because-just-cleared are indistinguishable.

  For `phx-change` only. Submit paths use the changeset as-is, so a blank
  required field still fails there; suppressing an error must never mean
  skipping the validation.
  """
  def on_change(%Ecto.Changeset{} = changeset, event_params \\ %{}) do
    target = changed_field(event_params)

    errors =
      Enum.reject(changeset.errors, fn {field, _error} ->
        blank?(changeset, field) and field != target
      end)

    %{changeset | errors: errors, action: :validate}
  end

  # `_target` is the input's name path — ["provider", "issuer"] — so the field is
  # its last segment. Nested inputs append an index, which no caller needs yet.
  defp changed_field(%{"_target" => path}) when is_list(path) and path != [] do
    path |> List.last() |> to_atom_if_known()
  end

  defp changed_field(_event_params), do: nil

  # Never String.to_atom/1 on a socket payload (IL-14): an unknown name simply
  # matches no field, which correctly means "not the target".
  defp to_atom_if_known(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # Judged from the submitted params, not from the changeset's data or changes:
  # the question is what the operator has put in the form, and an unfilled input
  # arrives as "" (or, for a multi-select, not at all).
  defp blank?(%Ecto.Changeset{params: params}, field) when is_map(params) do
    case Map.get(params, to_string(field)) do
      nil -> true
      "" -> true
      value when is_binary(value) -> String.trim(value) == ""
      [] -> true
      _other -> false
    end
  end

  defp blank?(_changeset, _field), do: true
end
