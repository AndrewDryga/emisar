defmodule Emisar.Accounts.RunnerAccess do
  @moduledoc """
  Explicit runner reach for one account membership or directory grant.

  `none` and `all` carry no scope values. `restricted` is the union of runner
  groups and runner ids. Invalid or inconsistent persisted data is never
  coerced into broader access.
  """

  @enforce_keys [:mode, :groups, :runner_ids]
  defstruct [:mode, :groups, :runner_ids]

  @type mode :: :none | :all | :restricted
  @type t :: %__MODULE__{mode: mode(), groups: [String.t()], runner_ids: [Ecto.UUID.t()]}

  @modes [:none, :all, :restricted]
  @max_scopes 256
  @max_group_length 255
  @none_runner_id "00000000-0000-0000-0000-000000000000"

  def modes, do: @modes
  def none, do: %__MODULE__{mode: :none, groups: [], runner_ids: []}
  def all, do: %__MODULE__{mode: :all, groups: [], runner_ids: []}

  def new(mode, groups \\ [], runner_ids \\ []) do
    with {:ok, mode} <- cast_mode(mode),
         {:ok, groups} <- normalize_groups(groups),
         {:ok, runner_ids} <- normalize_runner_ids(runner_ids),
         :ok <- validate_shape(mode, groups, runner_ids) do
      {:ok, %__MODULE__{mode: mode, groups: groups, runner_ids: runner_ids}}
    else
      _ -> {:error, :invalid_runner_access}
    end
  end

  def restricted(groups, runner_ids), do: new(:restricted, groups, runner_ids)

  def from_fields(%{runner_access_mode: mode}, scopes) when is_list(scopes) do
    groups = for %{scope_type: :group, scope_value: value} <- scopes, do: value

    runner_ids =
      for %{scope_type: :runner, scope_value: value} <- scopes,
          value != none_runner_id(),
          do: value

    with {:ok, access} <- new(mode, groups, runner_ids),
         :ok <- validate_persisted_rows(access, scopes) do
      {:ok, access}
    else
      _ -> {:error, :invalid_runner_access}
    end
  end

  def from_fields(_membership, _scopes), do: {:error, :invalid_runner_access}

  def from_prefixed_fields(data, prefix) when is_atom(prefix) do
    new(
      Map.get(data, field(prefix, :access_mode)),
      Map.get(data, field(prefix, :scope_groups), []),
      Map.get(data, field(prefix, :scope_runner_ids), [])
    )
  end

  def put_changes(changeset, %__MODULE__{} = access, prefix) do
    changeset
    |> Ecto.Changeset.put_change(field(prefix, :access_mode), access.mode)
    |> Ecto.Changeset.put_change(field(prefix, :scope_groups), access.groups)
    |> Ecto.Changeset.put_change(field(prefix, :scope_runner_ids), access.runner_ids)
  end

  def validate_changeset(changeset, prefix) do
    data = Ecto.Changeset.apply_changes(changeset)

    case from_prefixed_fields(data, prefix) do
      {:ok, access} ->
        put_changes(changeset, access, prefix)

      {:error, _} ->
        Ecto.Changeset.add_error(changeset, field(prefix, :access_mode), "is invalid")
    end
  end

  def union(accesses) when is_list(accesses) do
    if Enum.any?(accesses, &match?(%__MODULE__{mode: :all}, &1)) do
      all()
    else
      groups = accesses |> Enum.flat_map(& &1.groups) |> Enum.uniq() |> Enum.sort()
      runner_ids = accesses |> Enum.flat_map(& &1.runner_ids) |> Enum.uniq() |> Enum.sort()

      case {groups, runner_ids} do
        {[], []} -> none()
        _ -> %__MODULE__{mode: :restricted, groups: groups, runner_ids: runner_ids}
      end
    end
  end

  def covers?(%__MODULE__{mode: :all}, %__MODULE__{}), do: true
  def covers?(%__MODULE__{}, %__MODULE__{mode: :none}), do: true

  def covers?(%__MODULE__{mode: :restricted} = grantor, %__MODULE__{mode: :restricted} = grant) do
    MapSet.subset?(MapSet.new(grant.groups), MapSet.new(grantor.groups)) and
      MapSet.subset?(MapSet.new(grant.runner_ids), MapSet.new(grantor.runner_ids))
  end

  def covers?(_grantor, _grant), do: false

  def runner_in_scope?(_runner, %__MODULE__{mode: :none}), do: false
  def runner_in_scope?(_runner, %__MODULE__{mode: :all}), do: true

  def runner_in_scope?(%{id: id, group: group}, %__MODULE__{mode: :restricted} = access),
    do: id in access.runner_ids or group in access.groups

  def runner_in_scope?(_runner, _access), do: false

  def scope_tuples(%__MODULE__{mode: :none}), do: [{:runner, none_runner_id()}]
  def scope_tuples(%__MODULE__{mode: :all}), do: []

  def scope_tuples(%__MODULE__{mode: :restricted} = access) do
    Enum.map(access.groups, &{:group, &1}) ++ Enum.map(access.runner_ids, &{:runner, &1})
  end

  def none_runner_id, do: @none_runner_id

  defp cast_mode(mode) when mode in @modes, do: {:ok, mode}
  defp cast_mode("none"), do: {:ok, :none}
  defp cast_mode("all"), do: {:ok, :all}
  defp cast_mode("restricted"), do: {:ok, :restricted}
  defp cast_mode(_mode), do: :error

  defp normalize_groups(groups) when is_list(groups) and length(groups) <= @max_scopes do
    if Enum.all?(groups, &valid_group?/1) do
      {:ok, groups |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()}
    else
      :error
    end
  end

  defp normalize_groups(_groups), do: :error

  defp valid_group?(group) when is_binary(group) do
    trimmed = String.trim(group)
    trimmed != "" and String.length(trimmed) <= @max_group_length
  end

  defp valid_group?(_group), do: false

  defp normalize_runner_ids(runner_ids)
       when is_list(runner_ids) and length(runner_ids) <= @max_scopes do
    Enum.reduce_while(runner_ids, {:ok, []}, fn runner_id, {:ok, ids} ->
      case Ecto.UUID.cast(runner_id) do
        {:ok, normalized} when normalized != @none_runner_id ->
          {:cont, {:ok, [normalized | ids]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp normalize_runner_ids(_runner_ids), do: :error

  defp validate_shape(mode, [], []) when mode in [:none, :all], do: :ok

  defp validate_shape(:restricted, groups, runner_ids) do
    if groups != [] or runner_ids != [], do: :ok, else: :error
  end

  defp validate_shape(_mode, _groups, _runner_ids), do: :error

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
