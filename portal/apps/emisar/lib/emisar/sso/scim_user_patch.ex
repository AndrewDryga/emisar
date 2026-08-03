defmodule Emisar.SSO.SCIMUserPatch do
  @moduledoc """
  The typed SCIM `PATCH /Users/{id}` command: reduce an IdP's ordered RFC 7644
  §3.5.2 operation list into the one `%SCIMUserUpdate{}` desired state
  `Emisar.SSO.scim_patch_user/3` applies as a single transition.

  The operation list is attacker-supplied and every entry is scanned, so it is
  bounded before anything reads it. No IdP sends a batch anywhere near the cap.

  RFC 7644 §3.5.2 applies a PatchOp's operations IN ORDER, so the LAST one that
  touches an attribute decides its final value. Halting on the first match read a
  batch backwards: `[active: true, active: false]` — an IdP reinstating and then
  offboarding in one request — left the member active.

  The three refusals are distinct because the wire boundary answers each
  differently: a batch over the cap, an `active` value that cannot be parsed, and
  a batch asking for nothing this connection models.
  """
  alias Emisar.SSO.SCIMUserUpdate

  @max_operations 100

  @type error :: :too_many_scim_operations | :invalid_scim_active | :unsupported_scim_patch

  @doc """
  Internal — reduce a PATCH operation list to one desired state.
  `{:ok, %SCIMUserUpdate{}}` when the batch asks for a rename, a lifecycle
  change, or both; `{:error, :too_many_scim_operations | :invalid_scim_active |
  :unsupported_scim_patch}` otherwise.
  """
  @spec reduce([map()]) :: {:ok, SCIMUserUpdate.t()} | {:error, error()}
  def reduce(operations) when is_list(operations) and length(operations) > @max_operations,
    do: {:error, :too_many_scim_operations}

  def reduce(operations) when is_list(operations) do
    with :ok <- validate_operations(operations) do
      case {name_from_operations(operations), active_from_operations(operations)} do
        {_name, :error} -> {:error, :invalid_scim_active}
        {:keep, :keep} -> {:error, :unsupported_scim_patch}
        {name, active} -> {:ok, %SCIMUserUpdate{name: name, active: active}}
      end
    end
  end

  defp validate_operations(operations) do
    if Enum.all?(operations, &supported_operation?/1),
      do: :ok,
      else: {:error, :unsupported_scim_patch}
  end

  defp supported_operation?(%{} = operation) do
    replace_or_add?(Map.get(operation, "op")) and
      supported_value?(Map.get(operation, "path"), Map.get(operation, "value"))
  end

  defp supported_operation?(_operation), do: false

  defp supported_value?(nil, %{} = value) when map_size(value) > 0 do
    Enum.all?(value, fn
      {"active", _active} -> true
      {"displayName", name} -> is_binary(name) and name != ""
      {_key, _value} -> false
    end)
  end

  defp supported_value?(path, value) when is_binary(path) do
    case String.downcase(path) do
      "active" ->
        true

      name_path
      when name_path in ["displayname", "name.formatted", "name.givenname", "name.familyname"] ->
        is_binary(value) and value != ""

      _unsupported ->
        false
    end
  end

  defp supported_value?(_path, _value), do: false

  # Find the operation that sets `active`. `op` is case-insensitive
  # ("replace"/"Replace"/"add"); `path` is either "active" or omitted with the
  # value carrying `{"active": ...}` (Entra omits path, Okta sends it).
  # Returns the `SCIMUserUpdate` active shape — `:keep` (no active op present) or
  # the desired boolean — or `:error` (an active op whose value can't be parsed).
  defp active_from_operations(operations) do
    Enum.reduce_while(operations, :keep, fn op, acc ->
      case operation_active(op) do
        :skip -> {:cont, acc}
        :error -> {:halt, :error}
        active when is_boolean(active) -> {:cont, active}
      end
    end)
  end

  defp operation_active(%{} = op) do
    if replace_or_add?(Map.get(op, "op")) do
      active_from_op(Map.get(op, "path"), Map.get(op, "value"))
    else
      :skip
    end
  end

  defp operation_active(_op), do: :skip

  defp replace_or_add?(op) when is_binary(op), do: String.downcase(op) in ["replace", "add"]
  defp replace_or_add?(_op), do: false

  # path "active" → the value is the boolean; pathless → the value is a map
  # that may carry "active". Anything else is not an active op.
  defp active_from_op(path, value) when is_binary(path) do
    if String.downcase(path) == "active", do: parse_active(value), else: :skip
  end

  defp active_from_op(nil, %{"active" => value}), do: parse_active(value)
  defp active_from_op(_path, _value), do: :skip

  defp parse_active(value) when is_boolean(value), do: value

  # SCIM specifies a JSON boolean, but Entra sends the strings "True"/"False".
  defp parse_active(value) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> :error
    end
  end

  defp parse_active(_value), do: :error

  # Find the operation that replaces the name — same op/path/pathless handling as
  # `active_from_operations/1`. A non-string or empty value is not a rename (the
  # IdP sent nothing usable), never an error. Returns the `SCIMUserUpdate` name
  # shape: `:keep`, `{:replace, full_name}`, or `{:merge, components}`.
  # Last write wins, for the same ordering reason as `active` above.
  # A whole name wins outright: once one is seen, no later component overrides it,
  # because a component names half of something the batch has already stated in
  # full. Among components themselves the last mention of each half wins, which is
  # the wire-order rule the rest of PATCH follows.
  defp name_from_operations(operations) do
    Enum.reduce(operations, :keep, fn op, acc ->
      case operation_name(op) do
        :skip -> acc
        {:replace, full_name} -> {:replace, full_name}
        {:component, part, value} -> put_component(acc, part, value)
      end
    end)
  end

  # A whole name already won; components cannot override it.
  defp put_component({:replace, full_name}, _part, _value), do: {:replace, full_name}

  defp put_component({:merge, components}, part, value),
    do: {:merge, Map.put(components, part, value)}

  defp put_component(_acc, part, value), do: {:merge, %{part => value}}

  defp operation_name(%{} = op) do
    if replace_or_add?(Map.get(op, "op")) do
      name_from_op(Map.get(op, "path"), Map.get(op, "value"))
    else
      :skip
    end
  end

  defp operation_name(_op), do: :skip

  # Entra renames by sending the name COMPONENTS and no `displayName`:
  #   {"op": "Add", "path": "name.givenName",  "value": "Renamed"},
  #   {"op": "Add", "path": "name.familyName", "value": "Entra R3"}
  # Recognizing only `displayName` answered 400 to both, so an Entra rename
  # retried and failed forever.
  defp name_from_op(path, value) when is_binary(path) and is_binary(value) and value != "" do
    case String.downcase(path) do
      "displayname" -> {:replace, value}
      "name.formatted" -> {:replace, value}
      "name.givenname" -> {:component, :given, value}
      "name.familyname" -> {:component, :family, value}
      _ -> :skip
    end
  end

  defp name_from_op(nil, %{"displayName" => value}) when is_binary(value) and value != "",
    do: {:replace, value}

  defp name_from_op(_path, _value), do: :skip
end
