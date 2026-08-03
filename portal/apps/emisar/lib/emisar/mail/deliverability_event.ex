defmodule Emisar.Mail.DeliverabilityEvent do
  @moduledoc """
  A provider-neutral deliverability report — a bounce or a spam complaint —
  that `Emisar.Mail` acts on.

  A webhook boundary maps one provider's payload onto this command and nothing
  else; what a report means for the suppression list is the context's call. The
  constructor validates the identity it carries and bounds every diagnostic, so
  a built command can never walk an unbounded provider string into the domain.
  """
  @kinds [:bounce, :spam_complaint]
  @max_email_length 320
  @max_diagnostic_length 1_000

  @enforce_keys [:kind, :email]
  defstruct [:kind, :email, :inactive, :type, :description]

  @type t :: %__MODULE__{
          kind: :bounce | :spam_complaint,
          email: String.t(),
          inactive: boolean() | nil,
          type: String.t() | nil,
          description: String.t() | nil
        }

  @doc """
  Builds a deliverability command of `kind` from a provider-mapped `attrs` map.

  Returns `{:ok, event}` or `{:error, :invalid_deliverability_event}` for an
  unknown kind, a missing / blank / over-long / malformed email, or a `:bounce`
  that doesn't say whether the provider deactivated the address. The optional
  `:type` and `:description` diagnostics are advisory — a non-binary is dropped
  and a long one is truncated — so they can never turn a real report into a
  rejected one.
  """
  @spec new(atom(), map()) :: {:ok, t()} | {:error, :invalid_deliverability_event}
  def new(kind, attrs) when kind in @kinds and is_map(attrs) do
    with {:ok, email} <- email(Map.get(attrs, :email)),
         {:ok, inactive} <- inactive(kind, Map.get(attrs, :inactive)) do
      {:ok,
       %__MODULE__{
         kind: kind,
         email: email,
         inactive: inactive,
         type: diagnostic(Map.get(attrs, :type)),
         description: diagnostic(Map.get(attrs, :description))
       }}
    end
  end

  def new(_kind, _attrs), do: {:error, :invalid_deliverability_event}

  @doc """
  Internal — truncates one provider diagnostic to #{@max_diagnostic_length}
  Unicode code points. Called by `new/2` for `:type` and `:description`, and by
  `Emisar.Mail` for the detail it derives from the two together.
  """
  @spec bound_diagnostic(binary()) :: binary()
  def bound_diagnostic(text) when is_binary(text) do
    text |> String.to_charlist() |> Enum.take(@max_diagnostic_length) |> List.to_string()
  end

  # The address is the command's identity, so it is never truncated to fit — an
  # over-long or malformed one is a payload we don't understand and is rejected
  # outright.
  defp email(email) when is_binary(email) do
    trimmed = String.trim(email)

    if valid_email?(trimmed),
      do: {:ok, trimmed},
      else: {:error, :invalid_deliverability_event}
  end

  defp email(_email), do: {:error, :invalid_deliverability_event}

  # Length is counted in CODE POINTS, the unit PostgreSQL counts a character
  # column in — `String.length/1` folds combining marks into their base
  # grapheme, so a 320-grapheme address can carry thousands of code points past
  # the column. ASCII control code points are rejected for the same reason a
  # malformed identity is: a NUL cannot be sent as a text parameter at all, so
  # it would fail the write at the protocol level and put the provider into a
  # permanent retry loop over a payload nobody can fix.
  defp valid_email?(email) do
    code_points = String.to_charlist(email)

    length(code_points) in 1..@max_email_length and
      Enum.all?(code_points, &(&1 >= 32 and &1 != 127)) and
      Regex.match?(~r/^[^\s]+@[^\s]+$/, email)
  end

  # Deactivation is what separates a permanent bounce from a transient one, so a
  # bounce that doesn't state it is unusable. A complaint never carries it.
  defp inactive(:bounce, inactive) when is_boolean(inactive), do: {:ok, inactive}
  defp inactive(:bounce, _inactive), do: {:error, :invalid_deliverability_event}
  defp inactive(:spam_complaint, _inactive), do: {:ok, nil}

  defp diagnostic(value) when is_binary(value), do: bound_diagnostic(value)
  defp diagnostic(_value), do: nil
end
