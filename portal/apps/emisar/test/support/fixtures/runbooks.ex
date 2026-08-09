defmodule Emisar.Fixtures.Runbooks do
  @moduledoc """
  Runbook test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runbooks.create_runbook/1`.
  """

  alias Emisar.{Fixtures, Repo}
  alias Emisar.Runbooks.{Definition, Release, Runbook, RunbookExecution}

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
  Valid create attrs for one runbook, with per-key overrides.
  """
  def runbook_attrs(overrides \\ %{}) do
    overrides = Map.new(overrides)

    %{
      "slug" => overrides[:slug] || "runbook-#{Fixtures.Random.unique_int()}",
      "title" => overrides[:title] || "Runbook #{Fixtures.Random.unique_int()}",
      "description" => overrides[:description],
      "draft_definition" => overrides[:definition] || @default_definition
    }
  end

  @doc """
  Persists a runbook carrying only its first draft — nothing live. Caller
  supplies `:account_id` (or the helper makes a fresh account) and may override
  `:slug`/`:title`/`:description`/`:definition`/`:created_by_id`.
  """
  def create_runbook(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    created_by_id = attrs[:created_by_id] || Fixtures.Users.create_user().id

    {:ok, runbook} =
      account_id
      |> Runbook.Changeset.create(created_by_id, runbook_attrs(attrs))
      |> Repo.insert()

    runbook
  end

  @doc """
  Mints the next release of a persisted runbook and promotes its draft —
  arrangement state, bypassing the context's current-state publication
  readiness (which needs a live trusted catalog). The draft must still satisfy
  the strict contract.
  """
  def publish_runbook(%Runbook{} = runbook) do
    definition = runbook.draft_definition || runbook.definition
    version = (runbook.live_version || 0) + 1

    {:ok, _release} =
      Release.Changeset.create(%{
        account_id: runbook.account_id,
        runbook_id: runbook.id,
        version: version,
        title: runbook.title,
        description: runbook.description,
        definition: definition,
        definition_sha256: Definition.digest(definition),
        published_by_id: runbook.created_by_id
      })
      |> Repo.insert()

    {:ok, published} =
      runbook
      |> Runbook.Changeset.publish(definition, version)
      |> Repo.update()

    published
  end

  @doc """
  Grows a persisted runbook's description past a byte budget — arrangement state
  the authoring path deliberately refuses, so the column is written directly.
  Exercises the projection's own size backstop, which exists for values whose
  JSON escaping outgrows the bytes the changeset measured.
  """
  def oversize_runbook_description(%Runbook{} = runbook, bytes) do
    {:ok, oversized} =
      runbook
      |> Ecto.Changeset.change(description: String.duplicate("a", bytes))
      |> Repo.update()

    oversized
  end

  @doc "Soft-deletes a persisted runbook so a test can arrange a vanished family."
  def mark_runbook_as_deleted(%Runbook{} = runbook) do
    {:ok, deleted} = runbook |> Runbook.Changeset.delete() |> Repo.update()
    deleted
  end

  @doc """
  A persisted runbook execution. Pass `:completed_at` to arrange a settled
  execution of a given age — retention keys on that stamp, not on insertion.
  """
  def create_execution(attrs \\ %{}) do
    attrs = Map.new(attrs)
    runbook = attrs[:runbook] || create_runbook(account_id: attrs[:account_id])
    account_id = attrs[:account_id] || runbook.account_id
    definition = runbook.definition || runbook.draft_definition

    membership_id =
      attrs[:initiating_membership_id] ||
        Fixtures.Memberships.create_membership(account_id: account_id).id

    {:ok, execution} =
      RunbookExecution.Changeset.create(%{
        id: Repo.generate_id(),
        account_id: account_id,
        runbook_id: runbook.id,
        runbook_version: runbook.live_version,
        initiating_membership_id: membership_id,
        reason: attrs[:reason] || "execution fixture",
        frozen_plan: attrs[:frozen_plan] || %{},
        inputs_raw: attrs[:inputs_raw] || "{}",
        inputs_sha256: String.duplicate("a", 64),
        definition: attrs[:definition] || definition,
        definition_sha256: String.duplicate("b", 64),
        kind: attrs[:kind] || :published
      })
      |> Repo.insert()

    case attrs[:completed_at] do
      nil -> execution
      completed_at -> settle_execution(execution, completed_at)
    end
  end

  @doc """
  Marks a persisted execution succeeded at an exact instant — arrangement
  state, so a retention test can place it either side of the window without
  driving the scheduler.
  """
  def settle_execution(%RunbookExecution{} = execution, completed_at) do
    {:ok, settled} =
      execution
      |> RunbookExecution.Changeset.succeed(completed_at)
      |> Repo.update()

    settled
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
