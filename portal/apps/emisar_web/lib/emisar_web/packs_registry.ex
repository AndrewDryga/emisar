defmodule EmisarWeb.PacksRegistry do
  @moduledoc """
  Compile-time catalog of published action packs — drives the marketing
  `/packs` registry pages (index + per-pack detail) and any portal
  surfaces that need to enumerate available actions.

  ## Source of truth

  The pack YAML files at `runner/examples/packs/<id>/pack.yaml` plus
  `runner/examples/packs/<id>/actions/*.yaml`. This module walks that
  directory at compile time, parses every file with `YamlElixir`, and
  bakes the result into the BEAM module. **There is no hardcoded list.**

  Adding a new pack means dropping its YAML files into the packs dir;
  the next compile picks it up. The `@external_resource` tags ensure
  recompilation on any pack change.

  ## Lookup path

  By default the packs dir is resolved relative to this module's
  source file (`apps/emisar_web/lib/emisar_web/packs_registry.ex` →
  up 5 → repo root → `runner/examples/packs`). Override at compile
  time with `EMISAR_PACKS_DIR=/absolute/path` when building in a
  different layout (e.g. CI artifacts, Docker build).
  """

  alias EmisarWeb.PacksRegistry.{Action, Pack}

  @repo_url "https://github.com/andrewdryga/emisar"
  @packs_root "#{@repo_url}/tree/main/runner/examples/packs"

  # -- Compile-time scan -----------------------------------------------

  @packs_path System.get_env("EMISAR_PACKS_DIR") ||
                Path.expand("../../../../../runner/examples/packs", __DIR__)

  unless File.dir?(@packs_path) do
    raise """
    EmisarWeb.PacksRegistry: packs dir not found.

    Expected at: #{@packs_path}

    Override with the EMISAR_PACKS_DIR env var if your build layout
    differs from the repo default (e.g. Docker, CI artifacts).
    """
  end

  # Tag every YAML file as an external resource so Elixir recompiles
  # this module whenever any pack content changes.
  @manifest_paths Path.wildcard("#{@packs_path}/*/pack.yaml")
  @action_paths Path.wildcard("#{@packs_path}/*/actions/*.yaml")

  for path <- @manifest_paths ++ @action_paths do
    @external_resource path
  end

  # Compile-time YAML → struct conversion. Inlined into the @packs
  # attribute via a single anonymous function so the helpers don't
  # need to be defined before they're called.
  @packs (
           parse_yaml! = fn path ->
             case YamlElixir.read_from_file(path) do
               {:ok, data} ->
                 data

               {:error, reason} ->
                 raise "PacksRegistry: failed to parse #{path}: #{inspect(reason)}"
             end
           end

           build_action = fn data ->
             %Action{
               id: Map.fetch!(data, "id"),
               title: Map.get(data, "title", ""),
               kind: Map.get(data, "kind", "exec"),
               risk: Map.get(data, "risk", "low")
             }
           end

           build_pack = fn manifest_path ->
             pack_dir = Path.dirname(manifest_path)
             manifest = parse_yaml!.(manifest_path)
             requires = Map.get(manifest, "requires", %{}) || %{}

             actions =
               "#{pack_dir}/actions/*.yaml"
               |> Path.wildcard()
               |> Enum.map(parse_yaml!)
               |> Enum.map(build_action)
               |> Enum.sort_by(& &1.id)

             %Pack{
               id: Map.fetch!(manifest, "id"),
               name: Map.fetch!(manifest, "name"),
               version: to_string(Map.fetch!(manifest, "version")),
               description:
                 manifest
                 |> Map.get("description", "")
                 |> to_string()
                 |> String.trim()
                 |> String.replace(~r/\s+/, " "),
               vendor: Map.get(manifest, "vendor", "emisar"),
               homepage: Map.get(manifest, "homepage") || @repo_url,
               requires_os: Map.get(requires, "os", []) || [],
               requires_binaries: Map.get(requires, "binaries", []) || [],
               actions: actions
             }
           end

           @manifest_paths
           |> Enum.map(build_pack)
           |> Enum.sort_by(& &1.id)
         )

  # -- Public API ------------------------------------------------------

  @doc "All packs, ordered alphabetically by id."
  @spec list() :: [Pack.t()]
  def list, do: @packs

  @doc "Fetch a single pack by id, or nil if not in the registry."
  @spec get(String.t()) :: Pack.t() | nil
  def get(id) when is_binary(id), do: Enum.find(@packs, &(&1.id == id))

  @doc "Repo source URL for a pack, suitable for an external link."
  @spec source_url(Pack.t()) :: String.t()
  def source_url(%Pack{id: id}), do: "#{@packs_root}/#{id}"

  @doc "Repo source URL for a single action YAML inside a pack."
  @spec action_source_url(Pack.t(), Action.t()) :: String.t()
  def action_source_url(%Pack{id: pack_id}, %Action{id: action_id}) do
    # Action YAML filenames mirror the unqualified action id:
    #   linux.disk_usage → actions/disk_usage.yaml
    file = action_id |> String.split(".", parts: 2) |> List.last()
    "#{@packs_root}/#{pack_id}/actions/#{file}.yaml"
  end

  @doc "Install snippet operators paste on a runner host."
  @spec install_snippet(Pack.t()) :: String.t()
  def install_snippet(%Pack{id: id}) do
    """
    # Drop the pack into the runner's pack directory and reload:
    sudo curl -L #{@repo_url}/archive/refs/heads/main.tar.gz | \\
        sudo tar -xz -C /etc/emisar/packs --strip-components=3 \\
        emisar-main/runner/examples/packs/#{id}
    sudo systemctl reload emisar\
    """
  end
end
