defmodule EmisarWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach Sentry's :logger handler exactly once at boot. It's a
    # no-op when SENTRY_DSN isn't configured — Sentry.Client short-
    # circuits the upload. Wrapped so we don't crash a release if the
    # API surface changes between Sentry versions.
    install_sentry_logger_handler()

    children = [
      EmisarWeb.Telemetry,
      EmisarWeb.RunnerPresence,
      # Named Task.Supervisor for any web-layer detached work that needs
      # supervised shutdown (currently: the MCP long-poll test's
      # mid-poll DB flip, future async dispatch jobs).
      {Task.Supervisor, name: EmisarWeb.TaskSupervisor},
      EmisarWeb.Endpoint,
      # Sits AFTER the Endpoint so on SIGTERM it terminates first
      # (`:one_for_one` shuts down in reverse-start order). Its
      # `terminate/2` broadcasts `:runner_socket_drain` on PubSub so
      # every connected runner socket can flush its outbound queue and
      # send a shutdown envelope before the Endpoint closes the
      # transports underneath them.
      %{
        id: EmisarWeb.RunnerSocketDrain,
        start: {EmisarWeb.RunnerSocketDrain, :start_link, [[]]},
        shutdown: 5_000
      }
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EmisarWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp install_sentry_logger_handler do
    if Code.ensure_loaded?(Sentry.LoggerHandler) do
      :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
        config: %{
          metadata: [:request_id, :runner_id, :run_id, :user_id, :account_id]
        }
      })
    end

    :ok
  rescue
    # Handler already installed (mix test/dev reloads) — non-fatal.
    _ -> :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmisarWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
