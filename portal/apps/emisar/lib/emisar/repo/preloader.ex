defmodule Emisar.Repo.Preloader do
  @moduledoc """
  Routes `:preload` opts on `Repo.fetch/3` and `Repo.list/3` through
  the query module's `preloads/0` callback before falling back to
  `Ecto.Repo.preload/2`. The calling shape is the same as
  `Ecto.Repo.preload/2`, so context functions never need a separate
  `Repo.preload/2` call.

  Each entry in `Query.preloads/0` is one of:

    * `fn rows -> rows end` — a 1-arity mapper that augments the rows
      directly (used for virtual-field preloads like `:last_seen_at`
      computed from external state)
    * `%Ecto.Query{}` — a queryable handed to `Repo.preload/2` so it
      controls ordering/joining of the association
    * `{fun_or_query, nested_preloads}` — nested cascade, where
      `nested_preloads` is itself a `preloads/0`-shaped keyword list
      applied to the loaded association

  Anything not declared in `preloads/0` passes through unchanged to
  Ecto's regular preload machinery.
  """
  alias Emisar.Repo.Query

  def preload(schema, preload, query_module) do
    preloads_funs = Query.get_preloads_funs(query_module)
    handle_preloads(schema, preload, preloads_funs)
  end

  defp handle_preloads(results, preloads, preloads_funs) when is_list(results) do
    {results, ecto_preloads, []} =
      {results, [], preloads}
      |> pop_and_handle_preload(preloads_funs)

    {results, ecto_preloads}
  end

  defp handle_preloads(result, preloads, preloads_funs) do
    {[result], ecto_preloads, []} =
      {[result], [], preloads}
      |> pop_and_handle_preload(preloads_funs)

    {result, ecto_preloads}
  end

  defp pop_and_handle_preload({[], ecto_preloads, _preloads}, _preloads_funs) do
    {[], ecto_preloads, []}
  end

  defp pop_and_handle_preload({results, ecto_preloads, []}, _preloads_funs) do
    {results, ecto_preloads, []}
  end

  defp pop_and_handle_preload({results, ecto_preloads, [preload | preloads]}, preloads_funs) do
    {results, ecto_preloads, preloads}
    |> handle_preload(preload, preloads_funs)
    |> pop_and_handle_preload(preloads_funs)
  end

  defp pop_and_handle_preload({results, ecto_preloads, preload}, preloads_funs) do
    {results, ecto_preloads, []}
    |> handle_preload(preload, preloads_funs)
    |> pop_and_handle_preload(preloads_funs)
  end

  defp handle_preload(
         {results, ecto_preloads, preloads},
         {preload, nested_preloads},
         preloads_funs
       ) do
    case get_preload_cb(preloads_funs, preload) do
      nil ->
        {results, [{preload, nested_preloads}] ++ ecto_preloads, preloads}

      {preload_fun, []} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {results, [{preload, nested_preloads}] ++ ecto_preloads_to_prepend ++ ecto_preloads,
         preloads}

      {nil, nested_preload_funs} ->
        results = Emisar.Repo.preload(results, preload)

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {results, [{preload, nested_ecto_preloads}] ++ ecto_preloads, preloads}

      {%Ecto.Query{} = query, nested_preload_funs} ->
        results = Emisar.Repo.preload(results, [{preload, query}])

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {results, [{preload, nested_ecto_preloads}] ++ ecto_preloads, preloads}

      {preload_fun, nested_preload_funs} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {results, ecto_preloads_to_prepend ++ [{preload, nested_ecto_preloads}] ++ ecto_preloads,
         preloads}
    end
  end

  defp handle_preload({results, ecto_preloads, preloads}, preload, preloads_funs) do
    case get_preload_cb(preloads_funs, preload) do
      nil ->
        {results, [preload] ++ ecto_preloads, preloads}

      # `preloads/0` declared the assoc but with no override (e.g.
      # `account: []`) — fall through to plain Ecto preload.
      {nil, _nested} ->
        {results, [preload] ++ ecto_preloads, preloads}

      {preload_fun, _nested_preload_funs} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {results, ecto_preloads_to_prepend ++ ecto_preloads, preloads}
    end
  end

  defp handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs) do
    {results, nested_ecto_preloads} =
      Enum.reduce(results, {[], []}, fn result, {results_acc, ecto_preloads_acc} ->
        {nested_result, ecto_preloads_to_prepend} =
          result
          |> Map.fetch!(preload)
          |> handle_preloads(nested_preloads, nested_preload_funs)

        result = Map.put(result, preload, nested_result)

        {[result] ++ results_acc, ecto_preloads_to_prepend ++ ecto_preloads_acc}
      end)

    {Enum.reverse(results), nested_ecto_preloads}
  end

  defp apply_or_postpone_preload(results, _preload, preload_fun)
       when is_function(preload_fun, 1) do
    {preload_fun.(results), []}
  end

  defp apply_or_postpone_preload(results, preload, %Ecto.Query{} = query) do
    {results, [{preload, query}]}
  end

  defp get_preload_cb(preload_funs, preload) do
    case Keyword.get(preload_funs, preload) do
      {preload_fun, nested_preload_funs} -> {preload_fun, nested_preload_funs}
      nil -> nil
      nested_preload_funs when is_list(nested_preload_funs) -> {nil, nested_preload_funs}
      preload_fun -> {preload_fun, []}
    end
  end
end
