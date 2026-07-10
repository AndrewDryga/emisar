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

  @doc """
  GET `url` and return its body. `{:error, reason}` on any transport
  failure or non-2xx status — the caller keeps its last-good catalog.
  """
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, Emisar.Finch, receive_timeout: @receive_timeout) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
