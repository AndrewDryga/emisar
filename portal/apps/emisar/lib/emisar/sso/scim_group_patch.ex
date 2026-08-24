defmodule Emisar.SSO.SCIMGroupPatch do
  @moduledoc """
  The typed SCIM `PATCH /Groups/{id}` command: reduce an IdP's ordered RFC 7644
  §3.5.2 operation list into the one transition `Emisar.SSO.scim_patch_group/3`
  applies — nothing at all, a rename, a whole-set membership replacement, or a
  membership delta, each carrying the display the batch settles on.

  The operation list is attacker-supplied and every entry is scanned, so it is
  bounded before anything reads it — both as sent and after a pathless operation
  is split into one operation per attribute.

  Operations apply IN ORDER, so the fold carries one running state and the last
  op to mention a member decides whether it ends up in the group. A whole-set
  `replace` supersedes everything BEFORE it and hands us the absolute set, so an
  `add`/`remove` after one applies to that set directly — no read needed.
  Short-circuiting on the first replace instead dropped every later op: `replace
  members=[victim]` followed by `remove victim` — an IdP rewriting a group and
  then offboarding in one request — left the victim in a group that may map to an
  admin role or runner access.

  Every rename is judged here, BEFORE anything is written: a batch carrying both
  a membership change and an unacceptable rename used to commit the membership
  and only then refuse the rename, so the IdP read a 400 as total failure while a
  privilege change had already landed.
  """
  alias Emisar.SSO

  @max_operations 100
  @max_member_ids 5_000

  @type display :: String.t() | nil

  @type t ::
          :unchanged
          | {:rename, String.t()}
          | {:replace, display(), [String.t()]}
          | {:delta, display(), [String.t()], [String.t()]}

  @doc """
  Internal — reduce a PATCH operation list against the group it addresses.
  `{:ok, command}`; `{:error, :invalid_scim_group}` for a batch over a cap or
  carrying a malformed member array, `{:error, :unsupported_scim_patch}` for one
  asking for something this connection does not model.
  """
  @spec reduce([map()], map()) ::
          {:ok, t()} | {:error, :invalid_scim_group | :unsupported_scim_patch}
  def reduce(operations, group) when is_list(operations) and is_map(group) do
    with {:ok, attributes} <- expand_operations(operations),
         addressed = Enum.reject(attributes, &settles_identity?(&1, group)),
         {renames, member_operations} = Enum.split_with(addressed, &rename_op?/1),
         :ok <- validate_every_rename(renames) do
      plan(member_operations, pending_display(renames))
    end
  end

  defp expand_operations(operations) do
    operations
    |> Enum.reduce_while({:ok, [], 0}, fn operation, {:ok, reversed, count} ->
      case split_pathless_attributes(operation, @max_operations - count) do
        {:ok, attributes} ->
          {:cont, {:ok, Enum.reverse(attributes, reversed), count + length(attributes)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed, _count} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Nothing left to apply — the batch was only the externalId no-op Entra sends.
  defp plan([], nil), do: {:ok, :unchanged}

  # A batch of nothing but renames has no membership to reconcile.
  defp plan([], display), do: {:ok, {:rename, display}}

  # The display travels WITH the membership change, so one transaction applies
  # both or neither.
  defp plan(member_operations, display) do
    case member_ops(member_operations) do
      {:replace, ids} -> {:ok, {:replace, display, ids}}
      {:delta, add_ids, remove_ids} -> {:ok, {:delta, display, add_ids, remove_ids}}
      {:error, reason} -> {:error, reason}
      :unsupported -> {:error, :unsupported_scim_patch}
    end
  end

  # EVERY rename, not only the one that wins. Judging just the last silently
  # discarded an unacceptable earlier one — the IdP sent an operation we neither
  # applied nor refused.
  defp validate_every_rename(renames) do
    Enum.reduce_while(renames, :ok, fn operation, :ok ->
      case SSO.validate_scim_group_display(rename_display(operation)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The name this batch would settle on: wire order decides, so the last rename
  # wins, and a batch with no rename has no name to judge.
  defp pending_display([]), do: nil
  defp pending_display(renames), do: renames |> List.last() |> rename_display()

  # A pathless `replace` carries a MAP of attributes, and it may name more than
  # one. Treating any such map containing `displayName` as a rename dropped
  # `members` on the floor — the endpoint answered 200 while the people the
  # directory had just removed kept the group's mapped role and runner access.
  # Split it into one operation per attribute so each reaches its own handler.
  defp split_pathless_attributes(_operation, remaining) when remaining < 1,
    do: {:error, :invalid_scim_group}

  defp split_pathless_attributes(%{"value" => %{} = value} = op, remaining) do
    path = Map.get(op, "path")

    if replace?(op) and (is_nil(path) or path == "") and map_size(value) > 1 do
      if map_size(value) <= remaining do
        attributes =
          Enum.map(value, fn {attribute, attribute_value} ->
            op |> Map.put("path", attribute) |> Map.put("value", attribute_value)
          end)

        {:ok, attributes}
      else
        {:error, :invalid_scim_group}
      end
    else
      {:ok, [op]}
    end
  end

  defp split_pathless_attributes(op, _remaining), do: {:ok, [op]}

  # Okta's Group Push sends a pathless replace carrying `{id, displayName}`, and
  # Entra PATCHes `externalId` after reading a group back. Both name the group's
  # OWN identifier, so both ask for what is already true — but splitting them out
  # left an `id` operation nothing could handle, and the 400 stopped Okta's push
  # before any membership applied. An operation setting this group's identity to
  # the value it already has is the no-op it claims to be; one naming a DIFFERENT
  # value stays in the list to be refused, because we do not move a resource.
  defp settles_identity?(op, group) do
    replace?(op) and identity_value(group, Map.get(op, "path")) == Map.get(op, "value")
  end

  defp identity_value(group, path) when is_binary(path) do
    case downcase(path) do
      "id" -> group[:id] || group["id"]
      "externalid" -> group[:external_group_id] || group["external_group_id"]
      _ -> :not_identity
    end
  end

  defp identity_value(_group, _path), do: :not_identity

  defp rename_op?(op), do: rename_display(op) != nil

  # Two shapes carry a rename: a pathless `replace` whose value map holds
  # displayName, and a `replace` with `path: "displayName"` and a bare string.
  defp rename_display(%{"value" => %{"displayName" => display}} = op) when is_binary(display) do
    path = Map.get(op, "path")

    if replace?(op) and (is_nil(path) or path == ""), do: display, else: nil
  end

  defp rename_display(%{"path" => path, "value" => display} = op)
       when is_binary(path) and is_binary(display) do
    if replace?(op) and String.downcase(path) == "displayname", do: display, else: nil
  end

  defp rename_display(_op), do: nil

  defp replace?(op), do: downcase(Map.get(op, "op")) == "replace"

  # Reduce the member operations to one of:
  #   {:replace, ids}         — a whole-set `members` replace (route to upsert),
  #   {:delta, adds, removes} — add/remove member deltas (route to patch),
  #   :unsupported            — any op we don't model (→ honest SCIM error).
  defp member_ops(operations) do
    Enum.reduce_while(operations, {:delta, [], [], 0}, fn op, acc ->
      case classify_op(op) do
        {:replace, ids} -> replaced(ids)
        {:add, ids} -> add_members(acc, ids)
        {:remove, ids} -> remove_members(acc, ids)
        {:error, reason} -> {:halt, {:error, reason}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:delta, [], [], _count} -> :unsupported
      {:delta, adds, removes, _count} -> {:delta, adds, removes}
      result -> result
    end
  end

  defp add_members({:replace, ids}, added), do: replaced(append(ids, added))

  defp add_members({:delta, adds, removes, count}, added),
    do: delta(append(adds, added), removes -- added, count + length(added))

  defp remove_members({:replace, ids}, removed), do: replaced(ids -- removed)

  defp remove_members({:delta, adds, removes, count}, removed),
    do: delta(adds -- removed, append(removes, removed), count + length(removed))

  # The id moves to the end of the list it belongs in, and leaves the other one.
  defp append(ids, changed), do: (ids -- changed) ++ changed

  defp replaced(ids) when length(ids) > @max_member_ids,
    do: {:halt, {:error, :invalid_scim_group}}

  defp replaced(ids), do: {:cont, {:replace, ids}}

  defp delta(_adds, _removes, count) when count > @max_member_ids,
    do: {:halt, {:error, :invalid_scim_group}}

  defp delta(adds, removes, count), do: {:cont, {:delta, adds, removes, count}}

  # `op` is case-insensitive ("add"/"Add"/"replace"/"remove"). We only model the
  # `members` attribute; an op on any other path (a sub-attribute, an attribute
  # the directory connection does not own) is unsupported. A remove can carry the
  # ids in `value` OR in a filtered path (`members[value eq "x"]`, Okta's
  # single-member removal).
  defp classify_op(%{} = op),
    do: classify_member_op(downcase(Map.get(op, "op")), Map.get(op, "path"), Map.get(op, "value"))

  defp classify_op(_op), do: :unsupported

  defp classify_member_op("add", path, value) do
    if members_path?(path), do: member_op(:add, value), else: :unsupported
  end

  defp classify_member_op("replace", path, value) do
    if members_path?(path), do: member_op(:replace, value), else: :unsupported
  end

  defp classify_member_op("remove", path, value) do
    filtered_remove = filtered_member_remove(path)

    cond do
      whole_members_remove?(path, value) -> {:replace, []}
      members_path?(path) -> member_op(:remove, value)
      filtered_remove != :skip -> filtered_remove
      true -> :unsupported
    end
  end

  defp classify_member_op(_verb, _path, _value), do: :unsupported

  defp member_op(kind, value) do
    case member_ids(value) do
      {:ok, ids} -> {kind, ids}
      :error -> {:error, :invalid_scim_group}
    end
  end

  # A SCIM `members` array carries User resource ids. Every entry must carry a
  # usable value: a malformed array is refused rather than silently becoming a
  # shorter set, because a dropped entry is someone the directory still believes
  # is in the group.
  defp member_ids(nil), do: {:ok, []}

  defp member_ids(members) when is_list(members) and length(members) <= @max_member_ids do
    members
    |> Enum.reduce_while({:ok, []}, fn
      %{"value" => value}, {:ok, ids} when is_binary(value) and value != "" ->
        {:cont, {:ok, [value | ids]}}

      _entry, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp member_ids(_members), do: :error

  # path "members" (or absent — a pathless members op carries the array in value).
  defp members_path?(nil), do: true
  defp members_path?(path) when is_binary(path), do: downcase(path) == "members"
  defp members_path?(_path), do: false

  # RFC 7644 §3.5.2.2: removing a multi-valued attribute without a filter or
  # value removes every value. Keep this exact to `path: members`; a pathless
  # remove does not identify which resource attribute the directory meant.
  defp whole_members_remove?(path, nil) when is_binary(path),
    do: downcase(path) == "members"

  defp whole_members_remove?(_path, _value), do: false

  # Okta removes one member with `path: members[value eq "<User resource id>"]`
  # and no value. Anything richer is unsupported.
  defp filtered_member_remove(path) when is_binary(path) do
    case Regex.run(~r/^members\[\s*value\s+eq\s+"([^"]+)"\s*\]$/i, path) do
      [_, resource_id] -> {:remove, [resource_id]}
      _ -> :skip
    end
  end

  defp filtered_member_remove(_path), do: :skip

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: ""
end
