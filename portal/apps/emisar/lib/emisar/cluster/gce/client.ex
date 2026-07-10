defmodule Emisar.Cluster.GCE.Client do
  @moduledoc """
  The GCP Compute + metadata HTTP that `Emisar.Cluster.GCE` uses to discover
  cluster peers — the IL-19 vendor seam (one place to swap/stub the calls). Auth
  is the instance metadata-server access token (no service-account key); HTTP goes
  through `Emisar.Finch`.
  """

  @metadata_token_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

  @doc """
  Lists the project's RUNNING instances carrying the cluster label via the Compute
  aggregatedList API (all zones, so it covers a regional MIG). Returns
  `{:ok, [instance_map]}` or `{:error, term}`.
  """
  def discover(config) do
    project_id = Keyword.fetch!(config, :project_id)
    label = Keyword.get(config, :cluster_label, "cluster_name")
    value = Keyword.get(config, :cluster_value, "emisar")

    with {:ok, token} <- fetch_access_token(),
         {:ok, body} <- aggregated_list(project_id, label, value, token),
         {:ok, %{"items" => items}} <- Jason.decode(body) do
      instances =
        Enum.flat_map(items, fn
          {_zone, %{"instances" => instances}} -> instances
          {_zone, _no_results_on_page} -> []
        end)

      {:ok, instances}
    end
  end

  defp fetch_access_token do
    with {:ok, body} <- http_get(@metadata_token_url, [{"Metadata-Flavor", "Google"}]),
         {:ok, %{"access_token" => token}} <- Jason.decode(body) do
      {:ok, token}
    else
      {:ok, other} -> {:error, {:unexpected_token_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp aggregated_list(project_id, label, value, token) do
    filter = "labels.#{label}=#{value} AND status=RUNNING"

    url =
      "https://compute.googleapis.com/compute/v1/projects/#{project_id}/aggregated/instances?" <>
        URI.encode_query(%{"filter" => filter})

    http_get(url, [{"Authorization", "Bearer #{token}"}])
  end

  defp http_get(url, headers) do
    case Finch.request(Finch.build(:get, url, headers), Emisar.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Finch.Response{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
