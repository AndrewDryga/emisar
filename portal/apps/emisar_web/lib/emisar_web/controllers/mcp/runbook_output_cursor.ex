defmodule EmisarWeb.MCP.RunbookOutputCursor do
  @moduledoc """
  Opaque, scope-bound cursor for terminal runbook output pages.

  The cursor is bound to one execution and credential lineage. Its position is
  an index in the execution's immutable, ordered extracted-output projection.
  """

  alias EmisarWeb.MCP.CatalogCursor

  @tool "wait_for_run"

  @doc "Signs the next output position for one runbook execution."
  @spec encode(String.t(), String.t(), non_neg_integer()) :: String.t()
  def encode(scope, execution_id, position) when is_integer(position) and position >= 0 do
    CatalogCursor.encode(@tool, scope, filters(execution_id), Integer.to_string(position))
  end

  @doc "Verifies a runbook output cursor and returns its next output position."
  @spec decode(term(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_cursor}
  def decode(cursor, scope, execution_id) do
    with {:ok, position_string} when is_binary(position_string) <-
           CatalogCursor.decode(cursor, @tool, scope, filters(execution_id)),
         {position, ""} when position >= 0 <- Integer.parse(position_string) do
      {:ok, position}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  defp filters(execution_id),
    do: %{"mode" => "runbook_outputs", "runbook_execution_id" => execution_id}
end
