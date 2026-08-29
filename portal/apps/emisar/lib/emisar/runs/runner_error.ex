defmodule Emisar.Runs.RunnerError do
  @moduledoc """
  One `error` envelope a runner reported over its socket, as the domain
  takes it.

  The account, the runner, and the request context are the authenticated
  socket's own facts, so they are enforced. `code` and `message` are
  runner-controlled diagnostics: they are bounded here, before the domain
  branches on them or the audit trail stores them, so a compromised runner
  cannot grow an audit row with unbounded text. `request_id` is the run
  correlation the transport already validated as canonical, or `nil`.
  """
  alias Emisar.RequestContext

  @enforce_keys [:account_id, :runner_id, :context]
  defstruct [:account_id, :runner_id, :code, :message, :request_id, :context]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          runner_id: Ecto.UUID.t(),
          code: String.t() | nil,
          message: String.t() | nil,
          request_id: String.t() | nil,
          context: RequestContext.t()
        }

  # Diagnostics are display text on an audit row, never something we act on: a
  # code names one condition and a message explains it in a sentence or two.
  @max_code_length 100
  @max_message_length 500

  @doc """
  Builds the command from the socket's trusted identities plus the envelope's
  untrusted `:code`, `:message`, and `:request_id` diagnostics.

  A diagnostic that is absent or not a string (a crafted map, a number) becomes
  `nil`; a long one is cut to its code-point cap, and control/format/surrogate
  characters are stripped so a runner can't slip a bidi override onto the audit
  row it produces.
  """
  @spec new(Ecto.UUID.t(), Ecto.UUID.t(), map(), RequestContext.t()) :: t()
  def new(account_id, runner_id, %{} = attrs, %RequestContext{} = context)
      when is_binary(account_id) and is_binary(runner_id) do
    %__MODULE__{
      account_id: account_id,
      runner_id: runner_id,
      code: bounded(attrs[:code], @max_code_length),
      message: bounded(attrs[:message], @max_message_length),
      request_id: request_id(attrs[:request_id]),
      context: context
    }
  end

  defp bounded(value, limit) when is_binary(value) do
    if String.valid?(value),
      do: value |> Emisar.SafeText.strip() |> String.slice(0, limit),
      else: nil
  end

  defp bounded(_value, _limit), do: nil

  # The transport validated a canonical run request id, so the correlation is
  # carried whole or not at all — never a truncated id that matches nothing.
  defp request_id(value) when is_binary(value), do: value
  defp request_id(_value), do: nil
end
