defmodule Emisar.Marketing.Conversions do
  @moduledoc """
  Best-effort advertising conversions, separate from product analytics.

  Provider calls receive only their click identifier, the conversion time,
  and an opaque deduplication identifier.
  """

  alias Emisar.{Config, Crypto, Users}
  alias Emisar.Marketing.XClient
  require Logger

  @doc "Reports a completed account signup attributed to an X ad click."
  def account_signed_up(%Users.User{id: user_id}, %{x_click_id: x_click_id})
      when is_binary(x_click_id) and byte_size(x_click_id) in 1..255 do
    case Config.get_env(:emisar, :x_ads_conversions) do
      %{} = config ->
        event = %{
          conversion_id: Crypto.hash_hex("marketing-conversion:account-signed-up:" <> user_id),
          conversion_time: DateTime.utc_now(:millisecond) |> DateTime.to_iso8601(),
          x_click_id: x_click_id
        }

        sender =
          Config.get_env(:emisar, :x_ads_conversion_sender, &XClient.send_signup/2)

        dispatch(fn -> deliver(sender, config, event) end)

      _disabled ->
        :ok
    end

    :ok
  end

  def account_signed_up(%Users.User{}, _attribution), do: :ok

  defp dispatch(fun) do
    supervisor = Application.fetch_env!(:emisar, :task_supervisor)

    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> log_failure("dispatch")
    end
  rescue
    _exception -> log_failure("dispatch")
  catch
    _kind, _reason -> log_failure("dispatch")
  end

  defp deliver(sender, config, event) do
    case sender.(config, event) do
      :ok -> :ok
      {:error, {:http, status}} when is_integer(status) -> log_failure("http_#{status}")
      {:error, _reason} -> log_failure("request")
    end
  rescue
    _exception -> log_failure("exception")
  catch
    _kind, _reason -> log_failure("exception")
  end

  defp log_failure(error) do
    Logger.warning("x_ads_conversion.failed", error: error)
    :ok
  end
end
