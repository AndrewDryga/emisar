defmodule Emisar.Analytics.MixpanelClient do
  @moduledoc """
  Behaviour wrapping the Mixpanel HTTP ingestion endpoints we use —
  `/track` (events), `/engage` (user profiles), `/groups` (group
  profiles). The concrete implementation is `MixpanelClient.Live`;
  tests use `MixpanelClient.Stub`. Swapped by the `:mixpanel_client`
  config key, mirroring `Billing.PaddleClient`.

  Callers (`Emisar.Analytics`) hand fully-built payload lists; the
  project token is the Live client's concern (read from config), so it
  never travels through the rest of the app.
  """

  @callback track([map()]) :: :ok | {:error, term()}
  @callback engage([map()]) :: :ok | {:error, term()}
  @callback set_groups([map()]) :: :ok | {:error, term()}

  defp client, do: Application.fetch_env!(:emisar, :mixpanel_client)

  def track(events), do: client().track(events)
  def engage(updates), do: client().engage(updates)
  def set_groups(updates), do: client().set_groups(updates)
end
