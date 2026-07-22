defmodule Emisar.Marketing.XClient do
  @moduledoc false

  @api_version 12

  def send_signup(config, event) do
    with {:ok, request} <- build_request(config, event) do
      case Finch.request(request, Emisar.Finch, receive_timeout: 5_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Finch.Response{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, {:transport, reason}}
      end
    end
  end

  @doc false
  def build_request(config, event) do
    url = "https://ads-api.x.com/#{@api_version}/measurement/conversions/#{config.pixel_id}"

    payload = %{
      "conversions" => [
        %{
          "conversion_id" => event.conversion_id,
          "conversion_time" => event.conversion_time,
          "event_id" => config.event_id,
          "identifiers" => [%{"twclid" => event.x_click_id}]
        }
      ]
    }

    with {:ok, body} <- Jason.encode(payload),
         {:ok, authorization} <- authorization_header(url, config) do
      headers = [
        {"authorization", authorization},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ]

      {:ok, Finch.build(:post, url, headers, body)}
    end
  end

  defp authorization_header(url, config) do
    credentials =
      OAuther.credentials(
        consumer_key: config.consumer_key,
        consumer_secret: config.consumer_secret,
        token: config.access_token,
        token_secret: config.access_token_secret
      )

    try do
      signed_params = OAuther.sign("post", url, [], credentials)
      {{"Authorization", value}, _request_params} = OAuther.header(signed_params)
      {:ok, value}
    rescue
      _exception -> {:error, :authorization}
    end
  end
end
