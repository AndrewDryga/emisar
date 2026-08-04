defmodule Emisar.Mail do
  @moduledoc """
  Email deliverability: the suppression list of addresses that hard-bounced
  or filed a spam complaint, fed by a provider's deliverability webhook. The
  transactional mailer checks it before every send and skips suppressed
  addresses so repeated sends to a dead address don't burn sender reputation.

  What a reported bounce or complaint means is decided here, on the
  provider-neutral `DeliverabilityEvent` command — a webhook boundary only
  maps its provider's payload onto that command.

  System-side — these functions take no `%Subject{}`: the mailer is an
  internal choke point and the webhook is an unauthenticated provider
  callback (verified by shared secret in the controller). Email suppression
  is global (an address, not an account), like identity in `Emisar.Users`.
  """
  alias Emisar.Mail.{DeliverabilityEvent, Suppression}
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
    # Drop nils/blanks before the query — SSO-provisioned members can have no
    # email (`users.email` is nullable), and an empty/nil-only list must not
    # reach `email in ^[...]` (it has nothing to match anyway).
    trimmed =
      emails
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if trimmed == [] do
      MapSet.new()
    else
      # Match case-insensitively — the suppression `email` is citext and the
      # provider may report a bounced address in a different case than we store
      # the member's — but return the input strings. This downcase is an
      # in-memory reconciliation of two stored values, not a citext lookup.
      suppressed =
        Suppression.Query.by_emails(trimmed)
        |> Repo.all()
        |> MapSet.new(&String.downcase(&1.email))

      for email <- trimmed,
          MapSet.member?(suppressed, String.downcase(email)),
          into: MapSet.new(),
          do: email
    end
  end

  @doc """
  Builds one provider-neutral deliverability report of `kind` from the fields a
  webhook boundary mapped out of its provider's payload. Returns
  `{:ok, event} | {:error, :invalid_deliverability_event}`.
  """
  def build_deliverability_event(kind, attrs), do: DeliverabilityEvent.new(kind, attrs)

  @doc """
  Internal — applies one deliverability report (from a provider webhook).

  A bounce the provider deactivated the address for, and every spam complaint,
  suppresses the address; a transient bounce changes nothing. Returns
  `{:ok, :suppressed}`, `{:ok, :ignored}`, or `{:error, changeset}` when the
  write fails.
  """
  def handle_deliverability_event(%DeliverabilityEvent{kind: :bounce, inactive: false}),
    do: {:ok, :ignored}

  def handle_deliverability_event(%DeliverabilityEvent{kind: :bounce} = event),
    do: suppress_reported(event, :hard_bounce)

  def handle_deliverability_event(%DeliverabilityEvent{kind: :spam_complaint} = event),
    do: suppress_reported(event, :spam_complaint)

  @doc """
  Internal — records `email` as suppressed. The storage seam behind
  `handle_deliverability_event/1`, and the way a manual suppression is written.
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

  defp suppress_reported(%DeliverabilityEvent{} = event, reason) do
    case suppress(event.email, reason, detail(event)) do
      {:ok, _suppression} -> {:ok, :suppressed}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp detail(%DeliverabilityEvent{type: nil}), do: nil
  defp detail(%DeliverabilityEvent{type: type, description: nil}), do: type

  # Two diagnostics are each bounded, but together they can outgrow what
  # `Suppression.detail` holds — bound the derived line through the command's
  # own helper so advisory provider prose can never fail a real suppression.
  defp detail(%DeliverabilityEvent{type: type, description: description}),
    do: DeliverabilityEvent.bound_diagnostic("#{type}: #{description}")
end
