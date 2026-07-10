defmodule Emisar.Runbooks.StepSelector do
  @moduledoc """
  Parsing for a runbook step's `runner_selector` — the single place that
  understands exactly one target type: the current list shape
  (`%{"group" => ["a", "b"]}`) or the older single-value shape
  (`%{"group" => "a"}`). A selector mixing runner ids and groups is invalid.
  Pure: no Repo, no Subject.
  """

  @typedoc "A step's `runner_selector` value (or anything, for the unrecognized case)."
  @type selector :: %{optional(String.t()) => term()} | nil | term()

  @doc """
  Parse a `runner_selector` into `{kind, values}` — `kind` is `"runner_id"`,
  `"group"`, or `nil` (unrecognized/absent), and `values` is the list of
  non-blank ids/group-names (the single-string shape becomes a one-element list;
  blank and whitespace-only entries are dropped).
  """
  @spec parse(selector) :: {String.t() | nil, [String.t()]}
  def parse(%{"runner_id" => _runner_ids, "group" => _groups}), do: {nil, []}
  def parse(%{"runner_id" => v}), do: {"runner_id", normalize(v)}
  def parse(%{"group" => v}), do: {"group", normalize(v)}
  def parse(_), do: {nil, []}

  @doc "True when the selector targets nothing — no recognized kind, or no non-blank values."
  @spec empty?(selector) :: boolean
  def empty?(selector) do
    case parse(selector) do
      {nil, _} -> true
      {_kind, []} -> true
      _ -> false
    end
  end

  defp normalize(v) when is_list(v), do: Enum.filter(v, &nonblank?/1)
  defp normalize(v) when is_binary(v), do: if(nonblank?(v), do: [v], else: [])
  defp normalize(_), do: []

  defp nonblank?(v), do: is_binary(v) and String.trim(v) != ""
end
