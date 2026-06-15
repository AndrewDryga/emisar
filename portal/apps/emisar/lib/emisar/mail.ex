defmodule Emisar.Mail do
  @moduledoc """
  Email deliverability: the suppression list of addresses that hard-bounced
  or filed a spam complaint, fed by the Postmark webhook. The transactional
  mailer checks it before every send and skips suppressed addresses so
  repeated sends to a dead address don't burn sender reputation.

  System-side — these functions take no `%Subject{}`: the mailer is an
  internal choke point and the webhook is an unauthenticated provider
  callback (verified by shared secret in the controller). Email suppression
  is global (an address, not an account), like identity in `Emisar.Users`.
  """
  alias Emisar.Mail.Suppression
  alias Emisar.Repo

  @doc "Internal — true if `email` is suppressed. Called by the mailer before each send."
  def suppressed?(email) when is_binary(email) do
    trimmed = String.trim(email)
    Suppression.Query.by_email(trimmed) |> Repo.exists?()
  end

  def suppressed?(_), do: false

  @doc """
  Internal — of the given `emails`, the subset that is suppressed, returned as
  the CALLER's own strings. Called by `Accounts.suppressed_member_emails/2` to
  flag bouncing member/invite addresses on the Team page. The caller supplies
  an already account-scoped list (we never expose the global list); the result
  is a `MapSet` keyed to the input strings, so a render-time
  `MapSet.member?(set, member.email)` is an exact hit.
  """
  def suppressed_emails(emails) when is_list(emails) do
    trimmed = Enum.map(emails, &String.trim/1)

    # Match case-insensitively — the suppression `email` is citext and the
    # provider may report a bounced address in a different case than we store
    # the member's — but return the input strings. This downcase is an in-memory
    # reconciliation of two stored values, not a citext-column lookup.
    suppressed =
      Suppression.Query.by_emails(trimmed)
      |> Repo.all()
      |> MapSet.new(&String.downcase(&1.email))

    for email <- trimmed,
        MapSet.member?(suppressed, String.downcase(email)),
        into: MapSet.new(),
        do: email
  end

  @doc """
  Internal — records `email` as suppressed (from the Postmark webhook).
  Upserts by email: a later bounce/complaint refreshes the reason + detail
  rather than racing on the unique index. Returns `{:ok, suppression}` or
  `{:error, changeset}`.
  """
  def suppress(email, reason, detail \\ nil) when is_binary(email) and is_atom(reason) do
    %{email: email, reason: reason, detail: detail}
    |> Suppression.Changeset.suppress()
    |> Repo.insert(
      on_conflict: {:replace, [:reason, :detail, :updated_at]},
      conflict_target: :email,
      returning: true
    )
  end
end
