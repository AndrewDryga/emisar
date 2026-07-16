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
      # Owns the ETS table for request rate limiting; must start before the
      # Endpoint so the table exists when the first request arrives.
      EmisarWeb.RateLimiter,
      # Retains bounded, short-lived MCP cancellation tombstones on every
      # cluster node so a cancellation cannot race ahead of its request's
      # PubSub subscription.
      EmisarWeb.MCP.CancellationRegistry,
      # Bounds authenticated MCP long polls per credential lineage. Leases are
      # process-monitored so abnormal request exits cannot consume capacity.
      EmisarWeb.MCP.WaitLimiter,
      # Named Task.Supervisor for any web-layer detached work that needs
      # supervised shutdown (currently: the MCP long-poll test's
      # mid-poll DB flip, future async dispatch jobs).
      {Task.Supervisor, name: EmisarWeb.TaskSupervisor},
      # Loads the pack catalog (bundled at boot, then refreshed from the
      # published URL) BEFORE the Endpoint, so the first /packs request
      # already sees a populated registry.
      EmisarWeb.PacksRegistry.Cache,
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

  @doc false
  @spec scrub_sentry_event(Sentry.Event.t()) :: Sentry.Event.t()
  def scrub_sentry_event(%Sentry.Event{} = event) do
    redaction_keys = Application.fetch_env!(:emisar, :log_redaction_keys)

    %Sentry.Event{
      event
      | breadcrumbs: Enum.map(event.breadcrumbs, &scrub_sentry_breadcrumb(&1, redaction_keys)),
        contexts: scrub_sentry_value(event.contexts, redaction_keys),
        exception: Enum.map(event.exception, &scrub_sentry_exception(&1, redaction_keys)),
        extra: scrub_sentry_value(event.extra, redaction_keys),
        message: scrub_sentry_message(event.message, redaction_keys),
        request: scrub_sentry_request(event.request),
        tags: scrub_sentry_value(event.tags, redaction_keys),
        threads: scrub_sentry_threads(event.threads),
        user: scrub_sentry_user(event.user)
    }
  end

  defp scrub_sentry_request(nil), do: nil

  defp scrub_sentry_request(%Sentry.Interfaces.Request{} = request) do
    %Sentry.Interfaces.Request{
      request
      | url: strip_sentry_url_query(request.url),
        query_string: nil,
        data: nil,
        cookies: nil,
        headers: nil,
        env: nil
    }
  end

  defp scrub_sentry_request(request), do: request

  defp scrub_sentry_user(nil), do: nil
  defp scrub_sentry_user(_user), do: %{}

  defp scrub_sentry_message(nil, _redaction_keys), do: nil

  defp scrub_sentry_message(%Sentry.Interfaces.Message{} = message, redaction_keys) do
    %Sentry.Interfaces.Message{
      message
      | params: scrub_sentry_value(message.params, redaction_keys)
    }
  end

  defp scrub_sentry_message(message, _redaction_keys), do: message

  defp scrub_sentry_breadcrumb(
         %Sentry.Interfaces.Breadcrumb{} = breadcrumb,
         redaction_keys
       ) do
    %Sentry.Interfaces.Breadcrumb{
      breadcrumb
      | message: nil,
        data: scrub_sentry_value(breadcrumb.data, redaction_keys)
    }
  end

  defp scrub_sentry_breadcrumb(breadcrumb, _redaction_keys), do: breadcrumb

  defp scrub_sentry_exception(
         %Sentry.Interfaces.Exception{} = exception,
         redaction_keys
       ) do
    %Sentry.Interfaces.Exception{
      exception
      | mechanism: scrub_sentry_mechanism(exception.mechanism, redaction_keys),
        stacktrace: scrub_sentry_stacktrace(exception.stacktrace)
    }
  end

  defp scrub_sentry_exception(exception, _redaction_keys), do: exception

  defp scrub_sentry_mechanism(nil, _redaction_keys), do: nil

  defp scrub_sentry_mechanism(
         %Sentry.Interfaces.Exception.Mechanism{} = mechanism,
         redaction_keys
       ) do
    %Sentry.Interfaces.Exception.Mechanism{
      mechanism
      | data: scrub_sentry_value(mechanism.data, redaction_keys),
        meta: scrub_sentry_value(mechanism.meta, redaction_keys)
    }
  end

  defp scrub_sentry_mechanism(mechanism, _redaction_keys), do: mechanism

  defp scrub_sentry_stacktrace(nil), do: nil

  defp scrub_sentry_stacktrace(%Sentry.Interfaces.Stacktrace{} = stacktrace) do
    frames = Enum.map(stacktrace.frames, &%{&1 | vars: nil})
    %Sentry.Interfaces.Stacktrace{stacktrace | frames: frames}
  end

  defp scrub_sentry_stacktrace(stacktrace), do: stacktrace

  defp scrub_sentry_threads(nil), do: nil

  defp scrub_sentry_threads(threads) when is_list(threads) do
    Enum.map(threads, fn
      %Sentry.Interfaces.Thread{} = thread ->
        %Sentry.Interfaces.Thread{
          thread
          | state: nil,
            held_locks: [],
            stacktrace: scrub_sentry_stacktrace(thread.stacktrace)
        }

      thread ->
        thread
    end)
  end

  defp scrub_sentry_threads(threads), do: threads

  # Match the LoggerJSON redaction list by key fragment so variants such as
  # `client_secret` and `password_confirmation` receive the same treatment.
  defp scrub_sentry_value(%{__struct__: _} = value, _redaction_keys), do: value
  defp scrub_sentry_value(nil, _redaction_keys), do: nil

  defp scrub_sentry_value(value, redaction_keys) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      value =
        if sentry_secret_key?(key, redaction_keys) do
          "[REDACTED]"
        else
          scrub_sentry_value(nested_value, redaction_keys)
        end

      {key, value}
    end)
  end

  defp scrub_sentry_value(value, redaction_keys) when is_list(value) do
    Enum.map(value, &scrub_sentry_value(&1, redaction_keys))
  end

  defp scrub_sentry_value(value, redaction_keys) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&scrub_sentry_value(&1, redaction_keys))
    |> List.to_tuple()
  end

  defp scrub_sentry_value(value, _redaction_keys), do: value

  defp sentry_secret_key?(key, redaction_keys) when is_atom(key) do
    sentry_secret_key?(Atom.to_string(key), redaction_keys)
  end

  defp sentry_secret_key?(key, redaction_keys) when is_binary(key) do
    key = String.downcase(key)
    Enum.any?(redaction_keys, &String.contains?(key, String.downcase(&1)))
  end

  defp sentry_secret_key?(_key, _redaction_keys), do: false

  defp strip_sentry_url_query(nil), do: nil

  defp strip_sentry_url_query(url) when is_binary(url) do
    url
    |> String.split("?", parts: 2)
    |> List.first()
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp strip_sentry_url_query(url), do: url

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmisarWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
