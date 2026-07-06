defmodule EmisarWeb.MailTo do
  @moduledoc """
  Builds `mailto:` links with prefilled subject/body templates and optional
  authenticated account/user context.
  """
  @support "support@emisar.dev"
  @sales "sales@emisar.dev"
  @security "security@emisar.dev"

  @doc "Returns a support `mailto:` href with a prefilled subject/body and optional context footer."
  def support(opts \\ []), do: build(@support, "emisar support request", support_body(), opts)

  @doc "Returns a sales `mailto:` href with a prefilled subject/body and optional context footer."
  def sales(opts \\ []), do: build(@sales, "emisar - talk to sales", sales_body(), opts)

  @doc "Returns a security-disclosure `mailto:` href with a prefilled subject/body template."
  def security(opts \\ []),
    do: build(@security, "emisar - security disclosure", security_body(), opts)

  @doc "Builds a context footer map from assigns containing `current_account` and/or `current_user`."
  def context(assigns) do
    account = assigns[:current_account]
    user = assigns[:current_user]

    %{}
    |> put_if(:account, account && account.name)
    |> put_if(:account_id, account && account.id)
    |> put_if(:user, user && user.email)
  end

  # -- internals ----------------------------------------------------------

  defp build(to, subject, body, opts) do
    subject = opts[:subject] || subject
    body = (opts[:body] || body) <> context_footer(opts[:context])
    "mailto:#{to}?subject=#{enc(subject)}&body=#{enc(body)}"
  end

  defp support_body, do: "Hi emisar team,\n\n"

  defp sales_body do
    "Hi emisar team,\n\nWe're evaluating emisar and would like to talk. A bit about us:\n\n" <>
      "- Team / company:\n- What you'd use it for:\n- Rough fleet size:\n\n"
  end

  defp security_body do
    "Hi emisar security team,\n\nReporting a potential security issue.\n\n" <>
      "- Affected area:\n- What you observed:\n- Steps to reproduce:\n\n"
  end

  # Appended only when we know who is asking; saves support a round-trip.
  defp context_footer(ctx) when ctx in [nil, %{}], do: ""

  defp context_footer(ctx) do
    lines =
      [
        ctx[:account] && "Account: #{ctx[:account]}",
        ctx[:account_id] && "Account ID: #{ctx[:account_id]}",
        ctx[:user] && "User: #{ctx[:user]}"
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: "", else: "\n\n--\n" <> Enum.join(lines, "\n")
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # mailto-safe percent-encoding (spaces -> %20, newlines -> %0A), unlike
  # www_form's "+" that some mail clients paste literally into the body.
  defp enc(string), do: URI.encode(string, &URI.char_unreserved?/1)
end
