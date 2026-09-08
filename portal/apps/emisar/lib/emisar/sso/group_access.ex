defmodule Emisar.SSO.GroupAccess do
  @moduledoc "Resolves independent group additions against live connection defaults."
  alias Emisar.Accounts

  def defaults(provider) do
    {:ok, access} = Accounts.RunnerAccess.from_prefixed_fields(provider, :default_runner)
    access
  end

  def selection(default, additions) do
    %{
      "runner_access_mode" =>
        combined_mode(to_string(default.mode), additions["runner_access_mode"]),
      "scope" => Enum.uniq(runner_values(default) ++ additions["scope"]),
      "pack_access_mode" => combined_mode(pack_mode(default), additions["pack_access_mode"]),
      "pack_scope" => Enum.uniq(pack_values(default) ++ additions["pack_scope"])
    }
  end

  # Disabled inherited inputs are intentionally not serialized. Even a forged
  # submission below the baseline only changes the explicit extras, never it.
  def additions(default, params, presentation, runners) do
    runner_mode = Map.get(params, "runner_access_mode", presentation["runner_access_mode"])
    pack_mode = Map.get(params, "pack_access_mode", presentation["pack_access_mode"])
    no_runners? = default.mode == :none and runner_mode == "none"
    scopes = List.wrap(Map.get(params, "scope", []))
    # A stored pack-only grant can combine with another group's runner grant.
    # Disabled controls must not erase it when this group's runners are empty.
    packs =
      List.wrap(
        Map.get(params, "pack_scope", if(no_runners?, do: presentation["pack_scope"], else: []))
      )

    locked_scopes = runner_values(default)
    inherited_runners = Enum.filter(runners, &Accounts.RunnerAccess.runner_in_scope?(&1, default))
    locked_scopes = locked_scopes ++ Enum.map(inherited_runners, &("runner:" <> &1.id))
    extra_scopes = Enum.reject(scopes, &(&1 in locked_scopes))
    extra_packs = Enum.reject(packs, &(&1 in pack_values(default)))

    runner_mode =
      cond do
        default.mode == :all ->
          "none"

        runner_mode == "restricted" and extra_scopes == [] and default.mode == :restricted ->
          "none"

        true ->
          runner_mode
      end

    pack_mode =
      cond do
        pack_mode(default) == "all" ->
          "none"

        pack_mode == "restricted" and extra_packs == [] and pack_mode(default) == "restricted" ->
          "none"

        true ->
          pack_mode
      end

    %{
      "runner_access_mode" => runner_mode,
      "scope" => extra_scopes,
      "pack_access_mode" => pack_mode,
      "pack_scope" => extra_packs
    }
  end

  def empty?(%{"runner_access_mode" => "none", "pack_access_mode" => "none"}), do: true
  def empty?(_), do: false

  # A mapping can add packs without adding runners, or the reverse. Do not
  # canonicalize each mapping as a complete grant: runner:none would erase its
  # pack contribution before a sibling group's runners could use it.
  def effective(default, mappings) do
    parts =
      Enum.flat_map(mappings, fn mapping ->
        case dimensions(mapping) do
          {:ok, runners, packs} -> [{runners, packs}]
          {:error, _} -> []
        end
      end)

    runners = Accounts.RunnerAccess.union([default | Enum.map(parts, &elem(&1, 0))])

    if runners.mode == :none do
      Accounts.RunnerAccess.none()
    else
      defaults = if default.mode == :none, do: [], else: [default]
      packs = Accounts.RunnerAccess.union(defaults ++ Enum.map(parts, &elem(&1, 1)))
      %{runners | pack_mode: packs.pack_mode, pack_ids: packs.pack_ids}
    end
  end

  def dimensions(mapping) do
    with {:ok, runners} <-
           Accounts.RunnerAccess.new(
             mapping.runner_access_mode,
             mapping.runner_scope_groups,
             mapping.runner_scope_runner_ids
           ),
         {:ok, packs} <-
           Accounts.RunnerAccess.new(
             :all,
             [],
             [],
             mapping.pack_access_mode,
             mapping.pack_scope_pack_ids
           ) do
      {:ok, runners, packs}
    end
  end

  # A half-grant can meet a sibling's other dimension later. Conservatively
  # require all-runner authority for pack-only additions and all-pack authority
  # for runner-only additions; neither can bypass nondelegation via an empty half.
  def authorization_access(default, mapping) do
    with {:ok, runners, packs} <- dimensions(mapping) do
      cond do
        runners.mode == :none and packs.pack_mode == :restricted and packs.pack_ids == [] ->
          {:ok, Accounts.RunnerAccess.none()}

        runners.mode == :none ->
          {:ok, packs}

        packs.pack_mode == :restricted and packs.pack_ids == [] ->
          {:ok, runners}

        true ->
          {:ok, effective(default, [mapping])}
      end
    end
  end

  defp runner_values(access),
    do: Accounts.RunnerAccess.selection_values(access.groups, access.runner_ids)

  defp pack_values(access), do: Accounts.RunnerAccess.pack_selection_values(access.pack_ids)
  defp pack_mode(%{mode: :none}), do: "none"
  defp pack_mode(%{pack_mode: :restricted, pack_ids: []}), do: "none"
  defp pack_mode(access), do: to_string(access.pack_mode)

  defp combined_mode("all", _), do: "all"
  defp combined_mode(_, "all"), do: "all"
  defp combined_mode("restricted", _), do: "restricted"
  defp combined_mode(_, "restricted"), do: "restricted"
  defp combined_mode(_, _), do: "none"
end
