defmodule EmisarWeb.MarketingAttribution do
  @moduledoc """
  Browser-session boundary for first-touch campaign attribution.

  Only an allowlisted, byte-bounded set of flat query values enters the
  encrypted session. Mixpanel consumes the UTM campaign map; X conversion
  delivery may consume `twclid` unless the browser sends Global Privacy Control.
  """

  import Plug.Conn
  # Preserve the live session key so an in-flight campaign journey survives the
  # deployment that moves ownership out of EmisarWeb.Analytics.
  @session_key :analytics_campaign_attribution
  @campaign_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)
  @stored_params @campaign_params ++ ["twclid"]
  @value_max_bytes 255

  @doc "Persist bounded first-touch attribution in the existing encrypted session."
  def capture(conn) do
    stored = session_params(conn)
    current = current_params(conn)

    if map_size(stored) == 0 and map_size(current) > 0 do
      put_session(conn, @session_key, current)
    else
      conn
    end
  end

  @doc "Remove advertising attribution immediately when the browser sends GPC."
  def enforce_privacy_signal(conn) do
    if global_privacy_control?(conn) do
      delete_x_click_id(conn)
    else
      conn
    end
  end

  @doc "Return the current first-touch campaign and eligible X click identifier."
  def current(conn) do
    params = first_touch_params(conn)

    %{
      campaign: Map.take(params, @campaign_params),
      x_click_id: eligible_x_click_id(conn, params)
    }
  end

  @doc "Return only the UTM campaign properties suitable for product analytics."
  def campaign(conn), do: current(conn).campaign

  defp global_privacy_control?(conn) do
    conn
    |> get_req_header("sec-gpc")
    |> Enum.any?(&(&1 == "1"))
  end

  defp first_touch_params(conn) do
    case session_params(conn) do
      stored when map_size(stored) > 0 -> stored
      _ -> current_params(conn)
    end
  end

  defp current_params(conn) do
    params =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> normalize()

    if global_privacy_control?(conn), do: Map.delete(params, "twclid"), else: params
  end

  defp session_params(conn) do
    conn
    |> get_session(@session_key)
    |> normalize()
  end

  defp eligible_x_click_id(conn, params) do
    if not global_privacy_control?(conn), do: params["twclid"]
  end

  defp delete_x_click_id(conn) do
    params = session_params(conn)

    case Map.delete(params, "twclid") do
      remaining when map_size(remaining) == 0 -> delete_session(conn, @session_key)
      remaining -> put_session(conn, @session_key, remaining)
    end
  end

  defp normalize(params) when is_map(params) do
    Enum.reduce(@stored_params, %{}, fn key, attribution ->
      case Map.get(params, key) do
        value when is_binary(value) -> put_value(attribution, key, value)
        _ -> attribution
      end
    end)
  end

  defp normalize(_params), do: %{}

  defp put_value(attribution, key, value) do
    value =
      value |> String.trim() |> normalize_case(key) |> String.byte_slice(0, @value_max_bytes)

    if value == "", do: attribution, else: Map.put(attribution, key, value)
  end

  defp normalize_case(value, key) when key in ["utm_source", "utm_medium"],
    do: String.downcase(value)

  defp normalize_case(value, _key), do: value
end
