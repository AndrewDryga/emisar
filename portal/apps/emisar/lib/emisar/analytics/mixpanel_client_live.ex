defmodule Emisar.Analytics.MixpanelClient.Live do
  @moduledoc """
  Production Mixpanel wrapper. POSTs JSON arrays to the ingestion API
  over Finch (`Emisar.Finch`). The project token is stamped onto every
  payload here — `token` for events, `$token` for profile/group updates
  — so it lives only in config + this module.

  Best-effort by design: ingestion failures are logged at debug and
  returned as `{:error, …}`, never raised — analytics must never break
  a user request. The async wrapper is the caller's (`Emisar.Analytics`).
  """

  @behaviour Emisar.Analytics.MixpanelClient

  require Logger

  @impl true
  def track(events) do
    events
    |> Enum.map(&put_in(&1, ["properties", "token"], token()))
    |> post("/track")
  end

  @impl true
  def engage(updates) do
    updates
    |> Enum.map(&Map.put(&1, "$token", token()))
    |> post("/engage")
  end

  @impl true
  def set_groups(updates) do
    updates
    |> Enum.map(&Map.put(&1, "$token", token()))
    |> post("/groups")
  end

  defp post(payload, path) do
    case Jason.encode(payload) do
      {:ok, body} ->
        request = Finch.build(:post, host() <> path, headers(), body)

        case Finch.request(request, Emisar.Finch, receive_timeout: 5_000) do
          {:ok, %Finch.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Finch.Response{status: status, body: resp_body}} ->
            Logger.debug("mixpanel #{path} -> HTTP #{status}: #{resp_body}")
            {:error, {:http, status}}

          {:error, reason} ->
            Logger.debug("mixpanel #{path} -> #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.debug("mixpanel #{path} JSON encode failed: #{inspect(reason)}")
        {:error, {:encode, reason}}
    end
  end

  defp headers, do: [{"content-type", "application/json"}, {"accept", "application/json"}]

  defp token, do: Emisar.Config.fetch_env!(:emisar, :mixpanel_token)

  defp host, do: Application.get_env(:emisar, :mixpanel_api_host, "https://api.mixpanel.com")
end
