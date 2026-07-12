defmodule EmisarWeb.PacksRegistry.CatalogClient do
  @moduledoc """
  The one seam that fetches the published `catalog.json` over HTTP (via
  the shared `Emisar.Finch` pool). Wrapping the vendor call here (IL-19)
  keeps `EmisarWeb.PacksRegistry.Cache` free of HTTP concerns and gives
  tests a single place to reason about the fetch contract.

  `fetch/1` returns the raw response body; parsing + validation is
  `EmisarWeb.PacksRegistry.Catalog`'s job, so a 200 carrying garbage is a
  parse error, not a fetch error.
  """

  @receive_timeout 10_000

  # The published catalog is small (KBs to a few MB). A body past this cap is a
  # defect or a hostile/compromised origin trying to OOM the fetch, so stream and
  # abort at the cap instead of buffering an unbounded response into memory.
  @max_body_bytes 8_000_000

  @doc """
  GET `url` and return its body. `{:error, reason}` on any transport failure,
  non-2xx status, or a body exceeding `@max_body_bytes` — the caller keeps its
  last-good catalog. Streams so an oversized body is aborted, never buffered.
  """
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    request = Finch.build(:get, url)
    acc = %{status: nil, chunks: [], bytes: 0, too_large: false}

    case Finch.stream_while(request, Emisar.Finch, acc, &accumulate/2,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{too_large: true}} ->
        {:error, :body_too_large}

      {:ok, %{status: status, chunks: chunks}} when status in 200..299 ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      # stream_while/5 reports a transport failure as {:error, exception, acc}
      # (the accumulator so far) — a 3-tuple, not {:error, reason}. Matching
      # only the 2-tuple let an :nxdomain/timeout crash the Cache GenServer
      # with a CaseClauseError instead of holding the last-good catalog.
      {:error, reason, _acc} ->
        {:error, reason}
    end
  end

  defp accumulate({:status, status}, acc), do: {:cont, %{acc | status: status}}
  defp accumulate({:headers, _headers}, acc), do: {:cont, acc}

  defp accumulate({:data, chunk}, %{chunks: chunks, bytes: bytes} = acc) do
    bytes = bytes + byte_size(chunk)

    if bytes > @max_body_bytes,
      do: {:halt, %{acc | too_large: true}},
      else: {:cont, %{acc | chunks: [chunk | chunks], bytes: bytes}}
  end
end
