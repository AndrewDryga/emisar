defmodule Emisar.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Emisar.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Emisar.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Emisar.DataCase
    end
  end

  setup tags do
    Emisar.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Emisar.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      changeset = Users.change_user(%User{}, %{email: "bad"})
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Walk every page of a keyset-paginated read, following `next_page_cursor`
  with a small `limit` to force multiple pages, and return the concatenated
  rows. `list_fun` takes a `page:` keyword and returns `{:ok, rows, metadata}`.

  Used to prove the cursor agrees with the query's ORDER BY: walking all pages
  must equal a single unpaginated read of the same query, with no skipped or
  duplicated rows.
  """
  def walk_pages(list_fun, limit) when is_function(list_fun, 1) do
    walk_pages(list_fun, limit, nil, [])
  end

  defp walk_pages(list_fun, limit, cursor, acc) do
    page = if cursor, do: [limit: limit, cursor: cursor], else: [limit: limit]
    {:ok, rows, metadata} = list_fun.(page: page)
    acc = acc ++ rows

    case metadata.next_page_cursor do
      nil -> acc
      next -> walk_pages(list_fun, limit, next, acc)
    end
  end
end
