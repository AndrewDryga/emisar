defmodule Emisar.SafeText do
  @moduledoc """
  One predicate for the characters that must never survive ingest from a runner,
  an LLM, or an operator: control (`\\p{Cc}`), format (`\\p{Cf}` — including the
  bidi overrides like U+202E), and surrogate (`\\p{Cs}`) code points.

  They enable deception and anti-forensics — a hostile runner or MCP client that
  slips one into a hostname, error message, or client label lands it in the audit
  trail, the console, and NDJSON/CSV exports, the very surfaces a
  compromised-runner investigation depends on (HEEx escapes `&<>"'` but not these
  format chars, and Jason emits a literal U+202E). Reject at ingest so no sink
  downstream has to remember to strip.
  """

  @unsafe ~r/[\p{Cc}\p{Cf}\p{Cs}]/u

  @doc "Whether `value` contains a control, format, or surrogate character."
  @spec unsafe?(term()) :: boolean()
  def unsafe?(value) when is_binary(value), do: Regex.match?(@unsafe, value)
  def unsafe?(_value), do: false

  @doc "Strips every control, format, and surrogate character from `value`."
  @spec strip(String.t()) :: String.t()
  def strip(value) when is_binary(value), do: String.replace(value, @unsafe, "")
end
