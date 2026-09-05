defmodule Emisar.Jobs.Job do
  @moduledoc """
  Shared declaration macro for supervised recurrent jobs.

  Every job runs under `Emisar.Jobs.Executors.GloballyUnique` — a tick must
  happen once across the cluster, which is what a recurrent sweep means here.
  """

  @executor Emisar.Jobs.Executors.GloballyUnique

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, executor: @executor] do
      @otp_app Keyword.fetch!(opts, :otp_app)
      @interval Keyword.fetch!(opts, :every)
      @initial_delay Keyword.get(opts, :initial_delay, 0)

      @behaviour executor

      def child_spec(_opts) do
        config = Keyword.put_new(__config__(), :initial_delay, @initial_delay)

        Supervisor.child_spec({unquote(executor), {__MODULE__, @interval, config}},
          id: __MODULE__
        )
      end

      @doc "Returns this job's application configuration."
      def __config__ do
        Application.get_env(@otp_app, __MODULE__, [])
      end
    end
  end
end
