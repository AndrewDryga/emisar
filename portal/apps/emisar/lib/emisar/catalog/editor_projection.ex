defmodule Emisar.Catalog.EditorProjection do
  @moduledoc """
  Trusted exact action candidates for the runbook editor, keyed by the stable
  pack/action pair.

  It is built only from the trusted `MCPProjection` snapshot, so a runner
  advertisement is never authority: a candidate exists only where a connected
  deployment matches its complete trusted manifest, and it carries the exact
  pack ref, version, and hash the compiler would freeze.
  """

  defstruct candidates: %{}

  @type candidate :: %{
          runner_id: String.t(),
          runner_ref: String.t(),
          pack_id: String.t(),
          version: String.t(),
          hash: String.t(),
          pack_ref: String.t(),
          descriptor: map()
        }

  @type t :: %__MODULE__{
          candidates: %{{String.t(), String.t()} => %{String.t() => [candidate()]}}
        }

  @doc "Projects one trusted catalog snapshot into exact candidates by pack/action and runner."
  @spec build(map()) :: t()
  def build(%{packs: packs, runners: runners}) do
    refs_by_runner_id = Map.new(runners, &{&1.id, &1.runner_ref})

    candidates =
      for pack <- packs,
          descriptor <- pack.actions,
          runner_id <- descriptor.compatible_runner_ids,
          reduce: %{} do
        candidates ->
          candidate = candidate(pack, descriptor, runner_id, refs_by_runner_id)
          key = {pack.pack_id, descriptor["action_id"]}

          Map.update(
            candidates,
            key,
            %{runner_id => [candidate]},
            &Map.update(&1, runner_id, [candidate], fn existing -> [candidate | existing] end)
          )
      end

    %__MODULE__{candidates: candidates}
  end

  defp candidate(pack, descriptor, runner_id, refs_by_runner_id) do
    %{
      runner_id: runner_id,
      runner_ref: Map.fetch!(refs_by_runner_id, runner_id),
      pack_id: pack.pack_id,
      version: pack.version,
      hash: pack.hash,
      pack_ref: pack.pack_ref,
      descriptor: Map.drop(descriptor, [:compatible_runner_ids])
    }
  end
end
