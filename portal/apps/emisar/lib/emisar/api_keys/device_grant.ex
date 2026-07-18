defmodule Emisar.ApiKeys.DeviceGrant do
  @moduledoc """
  A device-authorization grant (RFC 8628 shape) that connects a local MCP
  client without the operator ever copying the API key: the installer opens
  the grant and polls with the device code, the operator approves it in the
  portal by user code, and the claim mints one `ApiKey` per requested client
  — secrets delivered over the poll exactly once. The approver's identity,
  bound at approval, is what authorizes the claim-time mint.
  """
  use Emisar, :schema

  # The clients the installer can auto-configure — EMISAR_CLIENT ids, and the
  # only values a grant may request. Labels double as the minted key names
  # (matching the connect page's quick-mint naming).
  @client_labels %{
    "claude-code" => "Claude Code",
    "claude-desktop" => "Claude Desktop",
    "cursor" => "Cursor",
    "gemini" => "Gemini CLI",
    "codex" => "Codex CLI",
    "openclaw" => "OpenClaw",
    "opencode" => "OpenCode",
    "windsurf" => "Windsurf",
    "pi" => "Pi",
    "copilot-cli" => "Copilot CLI",
    "zed" => "Zed",
    "hermes" => "Hermes",
    "goose" => "Goose"
  }

  schema "api_key_device_grants" do
    field :status, Ecto.Enum,
      values: [:pending, :approved, :denied, :claimed, :expired],
      default: :pending

    # Digests only — the raw device code (poll credential) and user code
    # (short human approval code) never persist.
    field :device_code_digest, :string
    field :user_code_digest, :string

    field :requested_clients, {:array, :string}, default: []
    field :requester_ip, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :approved_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :approved_by_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]

    timestamps()
  end

  def known_clients, do: Map.keys(@client_labels)

  @doc "Operator-facing label for a requested client id — also the minted key's name."
  def client_label(client), do: Map.fetch!(@client_labels, client)

  def expired?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt
end
