defmodule Emisar.Accounts.RunnerAccess do
  @moduledoc """
  Explicit reach for one account membership or directory grant: WHICH runners,
  and WHICH packs on them.

  The runner dimension is `none` / `all` / `restricted` — `none` and `all` carry
  no scope values, `restricted` is the union of runner groups and runner ids.
  The pack dimension narrows that reach further: `all` packs (the default, so a
  grant that never mentions packs behaves exactly as before) or `restricted` to
  an explicit pack list. The two dimensions intersect — a member reaches a
  runner only when the runner is in the runner scope, and may run an action only
  when its pack is in the pack scope.

  No runner reach means no pack reach either, so `none` normalizes to `all`
  packs rather than carrying a second, redundant representation of nothing.
  Invalid or inconsistent persisted data is never coerced into broader access.
  """

  # The pack dimension defaults to the widest value at every layer — struct, DB
  # column, and picker — so a grant written before packs existed, or by a caller
  # that has no opinion about them, keeps exactly its previous reach.
  @enforce_keys [:mode, :groups, :runner_ids]
  defstruct [:mode, :groups, :runner_ids, pack_mode: :all, pack_ids: []]

  @type mode :: :none | :all | :restricted
  @type pack_mode :: :all | :restricted
  @type t :: %__MODULE__{
          mode: mode(),
          groups: [String.t()],
          runner_ids: [Ecto.UUID.t()],
          pack_mode: pack_mode(),
          pack_ids: [String.t()]
        }

  @modes [:none, :all, :restricted]
  @pack_modes [:all, :restricted]
  @max_scopes 256
  @max_group_length 255
  @max_pack_id_length 128
  @none_runner_id "00000000-0000-0000-0000-000000000000"

  def modes, do: @modes
  def pack_modes, do: @pack_modes

  def none,
    do: %__MODULE__{mode: :none, groups: [], runner_ids: [], pack_mode: :all, pack_ids: []}

  def all,
    do: %__MODULE__{mode: :all, groups: [], runner_ids: [], pack_mode: :all, pack_ids: []}

  def new(mode, groups \\ [], runner_ids \\ [], pack_mode \\ :all, pack_ids \\ []) do
    with {:ok, mode} <- cast_mode(mode),
         {:ok, groups} <- normalize_groups(groups),
         {:ok, runner_ids} <- normalize_runner_ids(runner_ids),
         :ok <- validate_shape(mode, groups, runner_ids),
         {:ok, pack_mode} <- cast_pack_mode(pack_mode),
         {:ok, pack_ids} <- normalize_pack_ids(pack_ids),
         :ok <- validate_pack_shape(mode, pack_mode, pack_ids) do
      {:ok,
       %__MODULE__{
         mode: mode,
         groups: groups,
         runner_ids: runner_ids,
         pack_mode: pack_mode,
         pack_ids: pack_ids
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_runner_access}
    end
  end

  def restricted(groups, runner_ids), do: new(:restricted, groups, runner_ids)

  @doc """
  The reach a membership at `role` may actually carry.

  A role that reaches no runner (`Auth.Role.carries_runner_access?/1` — the
  finance seat) reaches no pack either, so its grant is always `none/0`;
  assigning the role RESETS both dimensions rather than refusing, which is what
  keeps a directory that maps one group to the seat and another to runners from
  failing its whole sync. Every other role keeps what it was given.

  Applied to the `%RunnerAccess{}` VALUE before a write, so the membership's own
  columns and its `user_runner_scopes` rows are written from one source and
  cannot disagree.
  """
  def for_role(role, %__MODULE__{} = access) do
    if Emisar.Auth.Role.carries_runner_access?(role), do: access, else: none()
  end

  @doc """
  Canonical access for an explicit mode plus the raw `"group:<name>"` /
  `"runner:<id>"` selector values a picker submitted, allowlisted against the
  account facts the selection may name: either `%{groups: [name], runners:
  [%{id: _, group: _}]}` — exactly the refs an authoritative lookup resolved —
  or a plain runner list, whose own groups are the ones that exist.

  `pack_mode` plus the raw `"pack:<id>"` values narrow the same grant; the
  allowlist's `:packs` are the account's known pack ids (absent means none are
  selectable). `none` and `all` carry no runner selection, and `none` drops the
  pack selection with it — nothing is reachable to narrow.

  `restricted` drops a runner a selected group already covers, and rejects an
  empty, malformed, unknown, or cross-account selection with `{:error,
  :invalid_runner_access}` / `{:error, :invalid_pack_access}`, so a crafted
  submission can never widen reach.
  """
  def from_selection(mode, values, allowlist, pack_mode \\ :all, pack_values \\ [])

  def from_selection(
        mode,
        values,
        %{groups: groups, runners: runners} = allowlist,
        pack_mode,
        pack_values
      )
      when is_list(values) and is_list(groups) and is_list(runners) and is_list(pack_values) do
    with {:ok, mode} <- cast_mode(mode),
         {:ok, {selected_groups, selected_runner_ids}} <-
           selected_runner_scope(mode, values, allowlist),
         {:ok, {pack_mode, pack_ids}} <-
           selected_pack_scope(mode, pack_mode, pack_values, allowlist) do
      new(mode, selected_groups, selected_runner_ids, pack_mode, pack_ids)
    else
      {:error, _reason} = error -> error
      :error -> {:error, :invalid_runner_access}
    end
  end

  def from_selection(mode, values, runners, pack_mode, pack_values) when is_list(runners),
    do: from_selection(mode, values, allowlist(runners), pack_mode, pack_values)

  def from_selection(_mode, _values, _allowlist, _pack_mode, _pack_values),
    do: {:error, :invalid_runner_access}

  @doc """
  The account facts a selection is allowlisted against: the runner rows an
  authoritative lookup resolved, the groups those runners name, and the pack ids
  the account knows. Deriving the groups here keeps ONE definition of which
  group names exist.
  """
  def allowlist(runners, packs \\ []) when is_list(runners) and is_list(packs) do
    groups = runners |> Enum.map(& &1.group) |> Enum.filter(&present_group?/1) |> Enum.uniq()

    %{groups: groups, runners: runners, packs: packs}
  end

  @doc """
  Splits raw selector values into `{:ok, {groups, runner_ids}}` — the CANONICAL
  refs an authoritative lookup has to resolve, before anything is known about
  them: groups trimmed, runner ids normalized, both deduplicated and sorted. A
  value carrying no known prefix, a blank group, or a malformed runner id is
  `{:error, :invalid_runner_access}`, so a crafted ref never reaches a lookup
  parameter and a ref that survives is the one the allowlist is asked about.
  """
  def selection_refs(values) when is_list(values) and length(values) <= @max_scopes do
    Enum.reduce_while(values, {[], []}, fn
      "group:" <> group, {groups, runner_ids} ->
        case normalize_group(group) do
          {:ok, group} -> {:cont, {[group | groups], runner_ids}}
          :error -> {:halt, :error}
        end

      "runner:" <> runner_id, {groups, runner_ids} ->
        case normalize_runner_id(runner_id) do
          {:ok, runner_id} -> {:cont, {groups, [runner_id | runner_ids]}}
          :error -> {:halt, :error}
        end

      _value, _acc ->
        {:halt, :error}
    end)
    |> case do
      {groups, runner_ids} -> {:ok, {canonical_refs(groups), canonical_refs(runner_ids)}}
      :error -> {:error, :invalid_runner_access}
    end
  end

  def selection_refs(_values), do: {:error, :invalid_runner_access}

  @doc """
  The canonical pack ids behind raw `"pack:<id>"` selector values — the pack
  analogue of `selection_refs/1`. A value carrying any other prefix, or a blank
  or over-long pack id, rejects the whole selection with `{:error,
  :invalid_pack_access}`.
  """
  def pack_selection_refs(values) when is_list(values) and length(values) <= @max_scopes do
    Enum.reduce_while(values, [], fn
      "pack:" <> pack_id, pack_ids ->
        case normalize_pack_id(pack_id) do
          {:ok, pack_id} -> {:cont, [pack_id | pack_ids]}
          :error -> {:halt, :error}
        end

      _value, _acc ->
        {:halt, :error}
    end)
    |> case do
      pack_ids when is_list(pack_ids) -> {:ok, canonical_refs(pack_ids)}
      :error -> {:error, :invalid_pack_access}
    end
  end

  def pack_selection_refs(_values), do: {:error, :invalid_pack_access}

  @doc ~s(The `"group:<name>"` / `"runner:<id>"` selector values for a `{groups, runner_ids}` scope.)
  def selection_values(groups, runner_ids),
    do: Enum.map(groups, &("group:" <> &1)) ++ Enum.map(runner_ids, &("runner:" <> &1))

  @doc ~s(The `"pack:<id>"` selector values for a persisted pack scope.)
  def pack_selection_values(pack_ids), do: Enum.map(pack_ids, &("pack:" <> &1))

  def from_fields(%{runner_access_mode: mode} = fields, scopes) when is_list(scopes) do
    groups = for %{scope_type: :group, scope_value: value} <- scopes, do: value

    runner_ids =
      for %{scope_type: :runner, scope_value: value} <- scopes,
          value != none_runner_id(),
          do: value

    with {:ok, access} <-
           new(
             mode,
             groups,
             runner_ids,
             Map.get(fields, :pack_access_mode, :all),
             Map.get(fields, :pack_scope_pack_ids, [])
           ),
         :ok <- validate_persisted_rows(access, scopes) do
      {:ok, access}
    else
      _ -> {:error, :invalid_runner_access}
    end
  end

  def from_fields(_membership, _scopes), do: {:error, :invalid_runner_access}

  @doc """
  The access persisted under one column-name prefix pair — `:runner` reads
  `runner_*` + `pack_*` (a membership or group mapping), `:default_runner` reads
  `default_runner_*` + `default_pack_*` (a provider's default grant).
  """
  def from_prefixed_fields(data, prefix) when is_atom(prefix) do
    {runner_prefix, pack_prefix} = prefixes(prefix)

    new(
      Map.get(data, field(runner_prefix, :access_mode)),
      Map.get(data, field(runner_prefix, :scope_groups), []),
      Map.get(data, field(runner_prefix, :scope_runner_ids), []),
      Map.get(data, field(pack_prefix, :access_mode), :all),
      Map.get(data, field(pack_prefix, :scope_pack_ids), [])
    )
  end

  def put_changes(changeset, %__MODULE__{} = access, prefix) do
    {runner_prefix, pack_prefix} = prefixes(prefix)

    changeset
    |> Ecto.Changeset.put_change(field(runner_prefix, :access_mode), access.mode)
    |> Ecto.Changeset.put_change(field(runner_prefix, :scope_groups), access.groups)
    |> Ecto.Changeset.put_change(field(runner_prefix, :scope_runner_ids), access.runner_ids)
    |> Ecto.Changeset.put_change(field(pack_prefix, :access_mode), access.pack_mode)
    |> Ecto.Changeset.put_change(field(pack_prefix, :scope_pack_ids), access.pack_ids)
  end

  @doc """
  Rebuilds a changeset's persisted `<prefix>_scope_*` arrays from the raw
  selector values cast into `scope_field` / `pack_scope_field`, allowlisted
  against `allowlist` (the account facts `from_selection/5` resolves against).

  The raw selection is the only accepted contract: the arrays are written here
  and nowhere else, `none`/`all` clear the runner arrays, `all` packs clears the
  pack array, and an empty, malformed, unknown, or foreign selection is an error
  on the rendered mode field — so a rejected submission comes back as the
  ordinary changeset with the operator's values still in it.
  """
  def validate_selection(changeset, prefix, scope_field, pack_scope_field, allowlist) do
    {runner_prefix, pack_prefix} = prefixes(prefix)
    mode = Ecto.Changeset.get_field(changeset, field(runner_prefix, :access_mode))
    values = changeset |> Ecto.Changeset.get_field(scope_field) |> List.wrap()
    pack_mode = Ecto.Changeset.get_field(changeset, field(pack_prefix, :access_mode))
    pack_values = changeset |> Ecto.Changeset.get_field(pack_scope_field) |> List.wrap()

    case from_selection(mode, values, allowlist, pack_mode, pack_values) do
      {:ok, access} ->
        changeset
        |> put_changes(access, prefix)
        |> Ecto.Changeset.put_change(
          scope_field,
          selection_values(access.groups, access.runner_ids)
        )
        |> Ecto.Changeset.put_change(pack_scope_field, pack_selection_values(access.pack_ids))

      {:error, :invalid_pack_access} ->
        Ecto.Changeset.add_error(changeset, field(pack_prefix, :access_mode), "is invalid")

      {:error, :invalid_runner_access} ->
        Ecto.Changeset.add_error(changeset, field(runner_prefix, :access_mode), "is invalid")
    end
  end

  @doc """
  The combined reach of several additive grants (a provider default plus every
  matched directory group).

  A grant with no runner reach contributes nothing at all — including its pack
  dimension, whose `all` default would otherwise widen a sibling grant that
  deliberately restricted packs. Packs union across the grants that DO reach
  runners, so a member in two groups may run either group's packs on either
  group's runners.
  """
  def union(accesses) when is_list(accesses) do
    case Enum.reject(accesses, &(&1.mode == :none)) do
      [] ->
        none()

      granting ->
        {mode, groups, runner_ids} = union_runner_scope(granting)
        {pack_mode, pack_ids} = union_pack_scope(granting)

        %__MODULE__{
          mode: mode,
          groups: groups,
          runner_ids: runner_ids,
          pack_mode: pack_mode,
          pack_ids: pack_ids
        }
    end
  end

  @doc """
  True when `grantor` may hand out `grant` — the nondelegation gate. BOTH
  dimensions must be covered: an operator restricted to one pack can never grant
  a member every pack, however wide their runner reach is.
  """
  def covers?(%__MODULE__{}, %__MODULE__{mode: :none}), do: true

  def covers?(%__MODULE__{} = grantor, %__MODULE__{} = grant),
    do: covers_runners?(grantor, grant) and covers_packs?(grantor, grant)

  def covers?(_grantor, _grant), do: false

  def runner_in_scope?(_runner, %__MODULE__{mode: :none}), do: false
  def runner_in_scope?(_runner, %__MODULE__{mode: :all}), do: true

  def runner_in_scope?(%{id: id, group: group}, %__MODULE__{mode: :restricted} = access),
    do: id in access.runner_ids or group in access.groups

  def runner_in_scope?(_runner, _access), do: false

  @doc """
  True when `pack_id` is inside the grant's pack dimension. An action with no
  pack identity cannot be matched against a restricted list, so it is refused
  rather than treated as universally allowed.
  """
  def pack_in_scope?(_pack_id, %__MODULE__{mode: :none}), do: false
  def pack_in_scope?(_pack_id, %__MODULE__{pack_mode: :all}), do: true

  def pack_in_scope?(pack_id, %__MODULE__{pack_mode: :restricted} = access)
      when is_binary(pack_id) and pack_id != "",
      do: pack_id in access.pack_ids

  def pack_in_scope?(_pack_id, _access), do: false

  def scope_tuples(%__MODULE__{mode: :none}), do: [{:runner, none_runner_id()}]
  def scope_tuples(%__MODULE__{mode: :all}), do: []

  def scope_tuples(%__MODULE__{mode: :restricted} = access) do
    Enum.map(access.groups, &{:group, &1}) ++ Enum.map(access.runner_ids, &{:runner, &1})
  end

  def none_runner_id, do: @none_runner_id

  defp prefixes(:runner), do: {:runner, :pack}
  defp prefixes(:default_runner), do: {:default_runner, :default_pack}

  defp selected_runner_scope(mode, _values, _allowlist) when mode in [:none, :all],
    do: {:ok, {[], []}}

  defp selected_runner_scope(:restricted, values, allowlist) do
    with {:ok, {groups, runner_ids}} <- selection_refs(values),
         :ok <- ensure_allowlisted(groups, runner_ids, allowlist) do
      covered = MapSet.new(groups)
      runners_by_id = Map.new(allowlist.runners, &{&1.id, &1})
      {:ok, {groups, Enum.reject(runner_ids, &MapSet.member?(covered, runners_by_id[&1].group))}}
    end
  end

  # Nothing is reachable, so there is nothing to narrow: drop the submitted pack
  # selection rather than persisting a restriction that can never apply.
  defp selected_pack_scope(:none, _pack_mode, _values, _allowlist), do: {:ok, {:all, []}}

  defp selected_pack_scope(_mode, pack_mode, values, allowlist) do
    with {:ok, pack_mode} <- cast_pack_mode(pack_mode) do
      selected_packs(pack_mode, values, allowlist)
    end
  end

  defp selected_packs(:all, _values, _allowlist), do: {:ok, {:all, []}}

  defp selected_packs(:restricted, values, allowlist) do
    with {:ok, pack_ids} <- pack_selection_refs(values),
         :ok <- ensure_packs_allowlisted(pack_ids, allowlist) do
      {:ok, {:restricted, pack_ids}}
    end
  end

  # Every canonical ref must be one the lookup actually resolved — an unknown,
  # deleted, or foreign group or runner rejects the WHOLE selection rather than
  # quietly resolving to the subset that happened to exist.
  defp ensure_allowlisted(groups, runner_ids, %{groups: known_groups, runners: runners}) do
    known = MapSet.new(known_groups)
    known_ids = MapSet.new(runners, & &1.id)

    if Enum.all?(groups, &MapSet.member?(known, &1)) and
         Enum.all?(runner_ids, &MapSet.member?(known_ids, &1)),
       do: :ok,
       else: {:error, :invalid_runner_access}
  end

  defp ensure_packs_allowlisted([], _allowlist), do: {:error, :invalid_pack_access}

  defp ensure_packs_allowlisted(pack_ids, allowlist) do
    known = allowlist |> Map.get(:packs, []) |> MapSet.new()

    if Enum.all?(pack_ids, &MapSet.member?(known, &1)),
      do: :ok,
      else: {:error, :invalid_pack_access}
  end

  defp union_runner_scope(granting) do
    if Enum.any?(granting, &(&1.mode == :all)) do
      {:all, [], []}
    else
      groups = granting |> Enum.flat_map(& &1.groups) |> canonical_refs()
      runner_ids = granting |> Enum.flat_map(& &1.runner_ids) |> canonical_refs()
      {:restricted, groups, runner_ids}
    end
  end

  defp union_pack_scope(granting) do
    if Enum.any?(granting, &(&1.pack_mode == :all)) do
      {:all, []}
    else
      {:restricted, granting |> Enum.flat_map(& &1.pack_ids) |> canonical_refs()}
    end
  end

  defp covers_runners?(%__MODULE__{mode: :all}, %__MODULE__{}), do: true

  defp covers_runners?(
         %__MODULE__{mode: :restricted} = grantor,
         %__MODULE__{mode: :restricted} = grant
       ) do
    MapSet.subset?(MapSet.new(grant.groups), MapSet.new(grantor.groups)) and
      MapSet.subset?(MapSet.new(grant.runner_ids), MapSet.new(grantor.runner_ids))
  end

  defp covers_runners?(_grantor, _grant), do: false

  defp covers_packs?(%__MODULE__{pack_mode: :all}, %__MODULE__{}), do: true

  defp covers_packs?(
         %__MODULE__{pack_mode: :restricted} = grantor,
         %__MODULE__{
           pack_mode: :restricted
         } = grant
       ),
       do: MapSet.subset?(MapSet.new(grant.pack_ids), MapSet.new(grantor.pack_ids))

  defp covers_packs?(_grantor, _grant), do: false

  defp present_group?(group), do: is_binary(group) and group != ""

  defp canonical_refs(refs), do: refs |> Enum.uniq() |> Enum.sort()

  defp cast_mode(mode) when mode in @modes, do: {:ok, mode}
  defp cast_mode("none"), do: {:ok, :none}
  defp cast_mode("all"), do: {:ok, :all}
  defp cast_mode("restricted"), do: {:ok, :restricted}
  defp cast_mode(_mode), do: :error

  defp cast_pack_mode(pack_mode) when pack_mode in @pack_modes, do: {:ok, pack_mode}
  defp cast_pack_mode("all"), do: {:ok, :all}
  defp cast_pack_mode("restricted"), do: {:ok, :restricted}
  # "Unspecified" reads as the documented default, never as a narrower grant
  # silently widened: every persisted carrier is NOT NULL with an `all` default,
  # so a nil can only come from a caller that has no opinion about packs.
  defp cast_pack_mode(nil), do: {:ok, :all}
  defp cast_pack_mode(_pack_mode), do: {:error, :invalid_pack_access}

  defp normalize_groups(groups) when is_list(groups) and length(groups) <= @max_scopes do
    normalize_refs(groups, &normalize_group/1)
  end

  defp normalize_groups(_groups), do: :error

  defp normalize_group(group) when is_binary(group) do
    trimmed = String.trim(group)

    if trimmed != "" and String.length(trimmed) <= @max_group_length,
      do: {:ok, trimmed},
      else: :error
  end

  defp normalize_group(_group), do: :error

  defp normalize_runner_ids(runner_ids)
       when is_list(runner_ids) and length(runner_ids) <= @max_scopes do
    normalize_refs(runner_ids, &normalize_runner_id/1)
  end

  defp normalize_runner_ids(_runner_ids), do: :error

  # The all-zero id is the persisted marker for `none`, never a selectable runner.
  defp normalize_runner_id(runner_id) do
    case Ecto.UUID.cast(runner_id) do
      {:ok, @none_runner_id} -> :error
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp normalize_pack_ids(pack_ids) when is_list(pack_ids) and length(pack_ids) <= @max_scopes do
    case normalize_refs(pack_ids, &normalize_pack_id/1) do
      {:ok, pack_ids} -> {:ok, pack_ids}
      :error -> {:error, :invalid_pack_access}
    end
  end

  defp normalize_pack_ids(_pack_ids), do: {:error, :invalid_pack_access}

  defp normalize_pack_id(pack_id) when is_binary(pack_id) do
    trimmed = String.trim(pack_id)

    if trimmed != "" and String.length(trimmed) <= @max_pack_id_length,
      do: {:ok, trimmed},
      else: :error
  end

  defp normalize_pack_id(_pack_id), do: :error

  defp normalize_refs(refs, normalize) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, normalized} ->
      case normalize.(ref) do
        {:ok, ref} -> {:cont, {:ok, [ref | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, canonical_refs(refs)}
      :error -> :error
    end
  end

  defp validate_shape(mode, [], []) when mode in [:none, :all], do: :ok

  defp validate_shape(:restricted, groups, runner_ids) do
    if groups != [] or runner_ids != [], do: :ok, else: :error
  end

  defp validate_shape(_mode, _groups, _runner_ids), do: :error

  defp validate_pack_shape(:none, :all, []), do: :ok
  defp validate_pack_shape(:none, _pack_mode, _pack_ids), do: {:error, :invalid_pack_access}
  defp validate_pack_shape(_mode, :all, []), do: :ok
  defp validate_pack_shape(_mode, :restricted, [_ | _]), do: :ok
  defp validate_pack_shape(_mode, _pack_mode, _pack_ids), do: {:error, :invalid_pack_access}

  defp validate_persisted_rows(%__MODULE__{mode: :none}, [
         %{scope_type: :runner, scope_value: value}
       ])
       when value == @none_runner_id,
       do: :ok

  defp validate_persisted_rows(%__MODULE__{mode: :all}, []), do: :ok

  defp validate_persisted_rows(%__MODULE__{mode: :restricted}, scopes) do
    if Enum.all?(scopes, fn
         %{scope_type: :group, scope_value: value} when is_binary(value) ->
           true

         %{scope_type: :runner, scope_value: value} when is_binary(value) ->
           value != none_runner_id()

         _ ->
           false
       end),
       do: :ok,
       else: :error
  end

  defp validate_persisted_rows(_access, _scopes), do: :error

  defp field(prefix, suffix), do: String.to_existing_atom("#{prefix}_#{suffix}")
end
