defmodule Emisar.Catalog.PackBaseline do
  @moduledoc """
  Compile-time baseline of canonical pack hashes for every pack shipped
  in `packs/`.

  Used by `Catalog.observe_state/2` to decide what to do on first sight
  of a `(pack_id, version)`:

    * **Hash matches our shipped baseline** → auto-pin as trusted.
      That's "these are the bytes we publish, no human review needed".
    * **Hash differs from our shipped baseline** → record but mark as
      `pending`. Operator must Trust or Reject in the UI.
    * **Unknown pack id** (third-party / custom pack) → record its
      first hash as pending for operator review.

  ## Hash algorithm

  The runner's `computePackHash` (Go) over the pack's files:
  `pack.yaml` + every action YAML + any referenced scripts, sorted by
  relpath, each entry framed `relpath \\0 data \\0`. We mirror it
  byte-for-byte here so a runner with unmodified shipped bytes
  produces a hash this module also produces.

  Override the source dir at compile time via `EMISAR_PACKS_DIR`
  (same env var used by `EmisarWeb.PacksRegistry`).
  """

  @packs_path System.get_env("EMISAR_PACKS_DIR") ||
                Path.expand("../../../../../../packs", __DIR__)

  # The module is best-effort: if the packs dir is missing at compile
  # time (unusual CI layout), we ship with an empty baseline rather
  # than failing the build. Means every pack becomes TOFU-pinned, which
  # is the safe fallback.
  if File.dir?(@packs_path) do
    @manifest_paths Path.wildcard("#{@packs_path}/*/pack.yaml")
    @action_paths Path.wildcard("#{@packs_path}/*/actions/*.yaml")

    for path <- @manifest_paths ++ @action_paths do
      @external_resource path
    end

    # Compute every (pack_id, version) → hash mapping inline so the
    # baseline is a frozen literal in the module attribute. No yaml
    # parsing at runtime.
    @baseline (
                parse_yaml! = fn path ->
                  case YamlElixir.read_from_file(path) do
                    {:ok, data} ->
                      data

                    {:error, reason} ->
                      raise "PackBaseline: parse #{path}: #{inspect(reason)}"
                  end
                end

                compute_pack_hash = fn pack_dir, manifest_data ->
                  # 1. Always include pack.yaml at relpath "pack.yaml".
                  base = [{"pack.yaml", manifest_data}]

                  # 2. Each action YAML at the relpath declared in
                  #    pack.yaml's `actions:` list (typically "actions/<id>.yaml").
                  action_entries =
                    case Map.get(parse_yaml!.(Path.join(pack_dir, "pack.yaml")), "actions", []) do
                      list when is_list(list) ->
                        Enum.map(list, fn rel ->
                          full_path = Path.join(pack_dir, rel)
                          {rel, File.read!(full_path)}
                        end)

                      _ ->
                        []
                    end

                  # 3. Script bytes for kind=script actions (rare; most
                  #    shipped packs are exec). The relpath is the
                  #    action's `execution.script.path`.
                  script_entries =
                    Enum.flat_map(action_entries, fn {_rel, data} ->
                      case YamlElixir.read_from_string(data) do
                        {:ok, %{"kind" => "script"} = action} ->
                          script_rel = get_in(action, ["execution", "script", "path"])

                          if is_binary(script_rel) and script_rel != "" do
                            [{script_rel, File.read!(Path.join(pack_dir, script_rel))}]
                          else
                            []
                          end

                        _ ->
                          []
                      end
                    end)

                  entries =
                    (base ++ action_entries ++ script_entries)
                    |> Enum.sort_by(fn {rel, _} -> rel end)

                  ctx =
                    Enum.reduce(entries, :crypto.hash_init(:sha256), fn {rel, data}, acc ->
                      acc
                      |> :crypto.hash_update(rel)
                      |> :crypto.hash_update(<<0>>)
                      |> :crypto.hash_update(data)
                      |> :crypto.hash_update(<<0>>)
                    end)

                  "sha256:" <> Base.encode16(:crypto.hash_final(ctx), case: :lower)
                end

                @manifest_paths
                |> Enum.flat_map(fn manifest_path ->
                  pack_dir = Path.dirname(manifest_path)
                  data = File.read!(manifest_path)
                  manifest = parse_yaml!.(manifest_path)

                  with id when is_binary(id) <- Map.get(manifest, "id"),
                       version when not is_nil(version) <- Map.get(manifest, "version") do
                    [{{id, to_string(version)}, compute_pack_hash.(pack_dir, data)}]
                  else
                    _ -> []
                  end
                end)
                |> Enum.into(%{})
              )
  else
    @baseline %{}
  end

  @doc """
  Canonical hash for a `(pack_id, version)` from the shipped library,
  or `nil` if the pack isn't part of what we publish (third-party /
  custom).
  """
  @spec lookup(String.t(), String.t()) :: String.t() | nil
  def lookup(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: Map.get(@baseline, {pack_id, version})

  def lookup(_, _), do: nil

  @doc "Whole baseline, mostly for tests + debugging."
  @spec all() :: %{{String.t(), String.t()} => String.t()}
  def all, do: @baseline
end
