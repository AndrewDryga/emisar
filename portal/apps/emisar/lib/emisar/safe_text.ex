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

  # Line breaks and tabs are `\p{Cc}` too, so the strict predicate cannot judge a
  # field that legitimately spans lines — a rendered shell program (48 shipped
  # actions carry a multi-line one), a runner's stderr excerpt, or a model's
  # multi-line justification. Those keep their layout and still lose the
  # deception surface: bidi overrides, zero-width joiners, ESC (which a terminal
  # renderer obeys), and NUL (which Postgres rejects outright in a text column).
  @unsafe_beyond_line_breaks ~r/(?![\n\r\t])[\p{Cc}\p{Cf}\p{Cs}]/u

  @doc "Whether `value` contains a control, format, or surrogate character."
  @spec unsafe?(term()) :: boolean()
  def unsafe?(value) when is_binary(value), do: Regex.match?(@unsafe, value)
  def unsafe?(_value), do: false

  @doc """
  Whether `value` contains an unsafe character other than a line break or tab.

  For text that is allowed to span lines; `unsafe?/1` governs single-line fields.
  """
  @spec unsafe_multiline?(term()) :: boolean()
  def unsafe_multiline?(value) when is_binary(value),
    do: Regex.match?(@unsafe_beyond_line_breaks, value)

  def unsafe_multiline?(_value), do: false

  @doc "Strips every control, format, and surrogate character from `value`."
  @spec strip(String.t()) :: String.t()
  def strip(value) when is_binary(value), do: String.replace(value, @unsafe, "")

  @doc "Strips unsafe characters from `value`, keeping its line breaks and tabs."
  @spec strip_multiline(String.t()) :: String.t()
  def strip_multiline(value) when is_binary(value),
    do: String.replace(value, @unsafe_beyond_line_breaks, "")
end
