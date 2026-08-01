defmodule Emisar.Mailers.HTML do
  @moduledoc """
  Escaping for the HTML alternative of an email body.

  The `emisar` app carries no Phoenix or HTML dependency — mail bodies are
  plain strings — so every value interpolated into email markup (account
  names, operator names, URLs) goes through `escape/1` here.
  """

  @doc "Escapes `&`, `<`, `>`, `\"`, and `'` so a value is safe as HTML text or inside a double-quoted attribute."
  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
