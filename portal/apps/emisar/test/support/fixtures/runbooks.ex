defmodule Emisar.Fixtures.Runbooks do
  @moduledoc """
  Runbook test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runbooks.create_runbook/1`.
  """

  alias Emisar.{Fixtures, Repo}
  alias Emisar.Runbooks.Runbook

  @default_definition %{
    "schema_version" => 1,
    "context_markdown" => "",
    "inputs" => [],
    "stages" => [
      %{
        "id" => "main",
        "title" => "Run",
        "mode" => "sequential",
        "steps" => [
          %{
            "id" => "inspect",
            "pack" => %{"id" => "linux-core"},
            "action" => "linux.uptime",
            "targets" => %{"selection" => "all", "refs" => ["group:default"]},
            "args" => %{},
            "outputs" => [],
            "success" => [],
            "wait" => nil
          }
        ]
      }
    ]
  }

  @doc """
  Persists a draft runbook. Caller supplies `:account_id` (or the helper makes
  a fresh account) and may override `:title`/`:created_by_id`.
  """
  def create_runbook(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    created_by_id = attrs[:created_by_id] || Fixtures.Users.create_user().id
    title = attrs[:title] || "Runbook #{Fixtures.Random.unique_int()}"

    {:ok, runbook} =
      account_id
      |> Runbook.Changeset.create(created_by_id, %{
        name: attrs[:name] || "runbook-#{Fixtures.Random.unique_int()}",
        slug: attrs[:slug] || "runbook-#{Fixtures.Random.unique_int()}",
        title: title,
        definition: attrs[:definition] || @default_definition
      })
      |> Repo.insert()

    runbook
  end

  @doc """
  Marks a persisted runbook published directly — arrangement state, bypassing
  the context's current-state publication readiness (which needs a live
  trusted catalog). The definition must still satisfy the strict contract.
  """
  def publish_runbook(%Runbook{} = runbook) do
    {:ok, published} = runbook |> Runbook.Changeset.publish() |> Repo.update()
    published
  end

  @doc "Soft-deletes a persisted runbook so a test can arrange a vanished family."
  def mark_runbook_as_deleted(%Runbook{} = runbook) do
    {:ok, deleted} = runbook |> Runbook.Changeset.delete() |> Repo.update()
    deleted
  end

  @doc "Returns a fresh canonical minimal v1 definition for context tests."
  def default_definition, do: @default_definition

  @doc """
  Builds one typed editor projection without a database — the shape
  `Emisar.Runbooks.editor_projection/1` returns. `targets` are
  `%{name, group}` maps and `actions` are
  `%{pack_id, action_id, descriptor}` maps advertised by every target, so a
  pure view-formatting test can skip the fleet and trust flow that
  `Emisar.Catalog.observe_state/2` exercises.
  """
  def build_editor_projection(targets, actions) do
    targets =
      Enum.map(targets, fn target ->
        name = target[:name] || "runner-#{Fixtures.Random.unique_int()}"

        %{
          id: Repo.generate_id(),
          runner_ref: name <> "~" <> String.duplicate("a", 32),
          name: name,
          group: target[:group]
        }
      end)

    candidates =
      Map.new(actions, fn action ->
        {{action.pack_id, action.action_id},
         Map.new(targets, &{&1.id, [editor_candidate(action, &1)]})}
      end)

    %Emisar.Runbooks.EditorProjection{
      targets: targets,
      catalog: %Emisar.Catalog.EditorProjection{candidates: candidates}
    }
  end

  defp editor_candidate(action, target) do
    version = action[:version] || "1.0.0"
    hash = Fixtures.Catalog.pack_hash("#{action.pack_id}-#{version}")

    %{
      runner_id: target.id,
      runner_ref: target.runner_ref,
      pack_id: action.pack_id,
      version: version,
      hash: hash,
      pack_ref: "#{action.pack_id}@#{version}/#{hash}",
      descriptor: Map.put(action.descriptor, "action_id", action.action_id)
    }
  end
end
