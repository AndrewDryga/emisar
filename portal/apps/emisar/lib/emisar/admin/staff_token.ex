defmodule Emisar.Admin.StaffToken do
  @moduledoc """
  A staff login's pending sign-in code (`:sign_in`) or signed-in session
  (`:session`). Only digests are stored: a sign-in code's is
  `sha256(nonce <> code)`, a session's is `sha256(raw)` of the cookie value.
  Both expire at `expires_at`; nothing extends them.
  """
  use Emisar, :schema

  schema "admin_staff_tokens" do
    field :context, Ecto.Enum, values: [:sign_in, :session]
    field :token, :binary, redact: true
    field :remaining_attempts, :integer
    field :expires_at, :utc_datetime_usec

    belongs_to :staff, Emisar.Admin.Staff

    timestamps(updated_at: false)
  end
end
