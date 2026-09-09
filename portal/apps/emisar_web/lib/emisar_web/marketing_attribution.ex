defmodule EmisarWeb.MarketingAttribution do
  @moduledoc """
  Browser-session boundary for first-touch traffic attribution.

  Only allowlisted, byte-bounded values enter the encrypted session. Mixpanel
  consumes the UTM campaign and external-referrer properties; X conversion
  delivery may consume `twclid` unless the browser sends Global Privacy Control.
  """

  import Plug.Conn
  # Preserve the live session key so an in-flight campaign journey survives the
  # deployment that moves ownership out of EmisarWeb.Analytics.
  @session_key :analytics_campaign_attribution
  @campaign_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)
  @campaign_touch_params @campaign_params ++ ["twclid"]
  @referrer_params ["$initial_referrer", "$initial_referring_domain"]
  @analytics_params @campaign_params ++ @referrer_params
  @stored_params @campaign_touch_params ++ @referrer_params
  @value_max_bytes 255

  @doc "Persist bounded first-touch campaign and external-referrer attribution."
  def capture(conn) do
    stored = session_params(conn)
    current = current_params(conn)
    attribution = merge_first_touch(stored, current)

    if attribution != stored do
      put_session(conn, @session_key, attribution)
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

  @doc "Return the first-touch analytics attribution and eligible X click identifier."
  def current(conn) do
    params = first_touch_params(conn)

    %{
      campaign: Map.take(params, @analytics_params),
      x_click_id: eligible_x_click_id(conn, params)
    }
  end

  @doc "Return the first-touch properties suitable for product analytics."
  def campaign(conn), do: current(conn).campaign

  defp global_privacy_control?(conn) do
    conn
    |> get_req_header("sec-gpc")
    |> Enum.any?(&(&1 == "1"))
  end

  defp first_touch_params(conn) do
    merge_first_touch(session_params(conn), current_params(conn))
  end

  defp current_params(conn) do
    query_params =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> normalize()

    referrer_params = conn |> external_referrer_params() |> normalize()
    params = Map.merge(query_params, referrer_params)

    if global_privacy_control?(conn), do: Map.delete(params, "twclid"), else: params
  end

  defp merge_first_touch(stored, current) do
    stored
    |> put_first_group(current, @campaign_touch_params)
    |> put_first_group(current, @referrer_params)
  end

  defp put_first_group(stored, current, keys) do
    if Enum.any?(keys, &Map.has_key?(stored, &1)) do
      stored
    else
      Map.merge(stored, Map.take(current, keys))
    end
  end

  defp external_referrer_params(conn) do
    referrer = conn |> get_req_header("referer") |> List.first() |> parse_http_referrer()

    case referrer do
      %URI{} = uri ->
        host = normalize_host(uri.host)

        if same_site?(normalize_host(conn.host), host) do
          %{}
        else
          %{
            "$initial_referrer" => referrer_origin(uri, host),
            "$initial_referring_domain" => host
          }
        end

      nil ->
        %{}
    end
  end

  defp parse_http_referrer(referrer) when is_binary(referrer) do
    case URI.parse(referrer) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if String.downcase(scheme) in ["http", "https"], do: uri

      _ ->
        nil
    end
  end

  defp parse_http_referrer(_referrer), do: nil

  defp referrer_origin(uri, host) do
    URI.to_string(%URI{
      scheme: String.downcase(uri.scheme),
      host: host,
      port: uri.port,
      path: "/"
    })
  end

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp same_site?(request_host, referrer_host) do
    request_host == referrer_host or
      String.ends_with?(request_host, "." <> referrer_host) or
      String.ends_with?(referrer_host, "." <> request_host)
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
