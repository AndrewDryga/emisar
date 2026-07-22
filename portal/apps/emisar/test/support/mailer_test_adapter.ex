defmodule Emisar.MailerTestAdapter do
  @moduledoc """
  Test mailer adapter. Delegates to `Swoosh.Adapters.Test` (delivering each
  email to the test process as `{:email, email}`) unless the calling process
  set the `Emisar.Config` override `:mailer_deliver_error` — then it returns
  that error instead. Lets a delivery-failure path be exercised per-process,
  so the test stays `async: true` rather than swapping the global adapter.
  """

  @behaviour Swoosh.Adapter

  @impl true
  def deliver(email, config) do
    case Emisar.Config.get_env(:emisar, :mailer_deliver_error) do
      nil -> Swoosh.Adapters.Test.deliver(email, config)
      error -> error
    end
  end

  @impl true
  def deliver_many(emails, config) do
    case Emisar.Config.get_env(:emisar, :mailer_deliver_error) do
      nil -> Swoosh.Adapters.Test.deliver_many(emails, config)
      error -> error
    end
  end

  @impl true
  def validate_config(_config), do: :ok
end
