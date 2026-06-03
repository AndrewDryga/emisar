defmodule EmisarWeb.OAuthHTML do
  @moduledoc """
  Templates for the OAuth consent + error screens shown to a logged-in
  operator when a remote MCP client (Claude.ai, ChatGPT) starts the
  authorization-code flow.
  """
  use EmisarWeb, :html

  embed_templates "oauth_html/*"

  @doc """
  Human-readable description of each scope shown on the consent screen.
  Operators should understand what they're granting, not read raw scope
  tokens.
  """
  def scope_label("mcp"), do: "Run approved actions on your runners and read their catalog"
  def scope_label("offline_access"), do: "Stay connected without re-authorizing every session"
  def scope_label(other), do: other
end
