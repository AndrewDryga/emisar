defmodule EmisarWeb.MailTo do
  @moduledoc """
  Builds `mailto:` links with prefilled subject/body templates and optional
  authenticated account/user context.
  """
  @support "support@emisar.dev"
  @sales "sales@emisar.dev"
  @security "security@emisar.dev"

  @doc "Returns a support `mailto:` href with a prefilled subject/body and optional context footer."
  def support(opts \\ []), do: build(@support, "Support request · emisar", support_body(), opts)

  @doc "Returns a sales `mailto:` href with a prefilled subject/body and optional context footer."
  def sales(opts \\ []), do: build(@sales, "Talk to sales · emisar", sales_body(), opts)

  @doc "Returns a security-disclosure `mailto:` href with a prefilled subject/body template."
  def security(opts \\ []),
    do: build(@security, "Security disclosure · emisar", security_body(), opts)

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

  defp support_body do
    "Hi emisar team,\n\nPlease help with the following issue.\n\n" <>
      "What happened:\n\nWhat I expected:\n\nWhen it happened (include timezone):\n\nPage or URL:\n\nRequest or error ID:\n\nBusiness impact:\n\n" <>
      "Please let me know if you need anything else. I have not included passwords, API keys, tokens, or customer data.\n"
  end

  defp sales_body do
    "Hi emisar team,\n\nWe're evaluating emisar and would like to talk.\n\n" <>
      "Team or company:\n\nWhat we want agents or operators to run:\n\nCurrent workflow or tooling:\n\nApproximate runner and team size:\n\nSecurity, identity, or procurement requirements:\n\nTarget timeline:\n"
  end

  defp security_body do
    "Hi emisar security team,\n\nI'm reporting a potential security issue.\n\n" <>
      "Affected product area and version:\n\nSecurity impact:\n\nSteps to reproduce:\n\nEvidence or proof of concept:\n\nSuggested remediation (optional):\n\nDisclosure timeline or coordination needs:\n\nPreferred contact details:\n\n" <>
      "I have not included active credentials, secrets, or customer data. Please tell me how to transfer sensitive evidence securely.\n"
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
