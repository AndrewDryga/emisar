defmodule Emisar.Analytics.MixpanelClient.Stub do
  @moduledoc """
  Test/dev Mixpanel client — never touches the network. Forwards each
  payload to the pid in `:analytics_test_pid` (set to `self()` in a
  test's setup) so tests can `assert_receive {:mixpanel_track, …}`; a
  no-op when no reporter is configured.
  """

  @behaviour Emisar.Analytics.MixpanelClient

  @impl true
  def track(events), do: report({:mixpanel_track, events})

  @impl true
  def engage(updates), do: report({:mixpanel_engage, updates})

  @impl true
  def set_groups(updates), do: report({:mixpanel_groups, updates})

  defp report(message) do
    case Application.get_env(:emisar, :analytics_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end

    :ok
  end
end
