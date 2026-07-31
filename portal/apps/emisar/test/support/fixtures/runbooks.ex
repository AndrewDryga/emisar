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

  @doc "Returns a fresh canonical minimal v1 definition for context tests."
  def default_definition, do: @default_definition
end
