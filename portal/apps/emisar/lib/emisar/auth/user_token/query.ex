defmodule Emisar.Auth.UserToken.Query do
  use Emisar, :query
  alias Emisar.{Accounts, SSO}
  alias Emisar.Auth.UserToken

  # Validity windows. These can move to runtime config later; defaults
  # err on the side of "short enough not to be the weakest link if a
  # phone is lost."
  @session_validity_in_days 60
  @magic_link_validity_in_minutes 15
  @magic_link_verified_validity_in_minutes 10
  @mfa_enrollment_validity_in_minutes 15
  @oidc_identity_step_up_validity_in_minutes 15
  @email_change_validity_in_minutes 15

  # A browser holds at most this many workspace sessions, so a request never
  # looks up more entries than that.
  @max_session_entries 6

  # Every context `validity_in_days/1` answers for. The retention sweep walks
  # this list, so a new context must be added here as well as below — a context
  # missing from it is treated as unrecognized and swept.
  @contexts ~w(session magic_link magic_link_verified sign_up mfa_enrollment_pending
               mfa_enrollment oidc_identity_step_up email_change email_change_new)

  def all,
    do: from(t in UserToken, as: :tokens)

  def by_context(queryable \\ all(), context) when is_binary(context),
    do: where(queryable, [tokens: t], t.context == ^context)

  def by_contexts(queryable \\ all(), contexts) when is_list(contexts),
    do: where(queryable, [tokens: t], t.context in ^contexts)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [tokens: t], t.account_id == ^account_id)

  @doc "One Member's rows: the account is part of the key, like the composite foreign key."
  def by_membership(queryable \\ all(), account_id, membership_id) do
    where(
      queryable,
      [tokens: t],
      t.account_id == ^account_id and t.membership_id == ^membership_id
    )
  end

  def by_identity_ids(queryable \\ all(), identity_ids) when is_list(identity_ids),
    do: where(queryable, [tokens: t], t.user_identity_id in ^identity_ids)

  def by_auth_method(queryable \\ all(), auth_method),
    do: where(queryable, [tokens: t], t.auth_method == ^auth_method)

  @doc """
  Rows addressed to `address`, case-insensitively like the sign-up address
  index; the sign-up code has no Member to key on.
  """
  def by_sent_to(queryable \\ all(), address) when is_binary(address) do
    where(
      queryable,
      [tokens: t],
      fragment("lower(?)", t.sent_to) == fragment("lower(?)", ^address)
    )
  end

  @doc "Stored session digests, for an atomic DELETE RETURNING exact disconnect topics."
  def select_token_digests(queryable), do: select(queryable, [tokens: t], t.token)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [tokens: t], t.id == ^id)

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [tokens: t], t.id in ^ids)

  def by_token_digest(queryable \\ all(), digest) when is_binary(digest),
    do: where(queryable, [tokens: t], t.token == ^digest)

  def by_token_digests(queryable \\ all(), digests) when is_list(digests),
    do: where(queryable, [tokens: t], t.token in ^digests)

  @doc """
  The rows a browser sign-out reaches: those its cookie names, and every row
  minted by the browser whose id has `browser_digest`. A nil `browser_digest`
  reaches only the named rows.
  """
  def by_browser(queryable \\ all(), token_digests, browser_digest)

  def by_browser(queryable, token_digests, nil), do: by_token_digests(queryable, token_digests)

  def by_browser(queryable, token_digests, browser_digest)
      when is_list(token_digests) and is_binary(browser_digest) do
    where(
      queryable,
      [tokens: t],
      t.token in ^token_digests or t.browser_digest == ^browser_digest
    )
  end

  @doc """
  A browser's cookie entries: each `{account_id, digest}` pair matches only its
  own workspace's row, so a token presented under another workspace matches
  nothing. An empty list matches nothing.
  """
  def by_entries(queryable \\ all(), entries)
      when is_list(entries) and length(entries) <= @max_session_entries do
    pairs =
      Enum.reduce(entries, dynamic(false), fn {account_id, digest}, acc ->
        dynamic([tokens: t], ^acc or (t.account_id == ^account_id and t.token == ^digest))
      end)

    where(queryable, ^pairs)
  end

  @doc ~S(Every row except the one carrying `digest` — "sign out everywhere else".)
  def except_token_digest(queryable, digest) when is_binary(digest),
    do: where(queryable, [tokens: t], t.token != ^digest)

  @doc "Rows still inside `context`'s validity window."
  def not_expired(queryable, context),
    do: where(queryable, [tokens: t], t.inserted_at > ago(^validity_in_days(context), "day"))

  @doc """
  Sessions that authenticate right now — the one per-request predicate. The
  token is a live session of an authorized Member (not removed, suspended or a
  pending invitee) in an active workspace. An email-code session needs nothing
  more. An SSO session also needs its identity still bound to that Member, its
  subject unretired and equal to the one frozen at sign-in, and its provider
  enabled at the frozen issuer; a deleted identity or provider fails closed.
  Workspace policy (`require_sso`, `require_mfa`) is judged by the caller.
  """
  def authorized(queryable \\ all()) do
    queryable
    |> by_context("session")
    |> not_expired("session")
    |> join(:inner, [tokens: t], m in ^Accounts.Membership.Query.authorized(),
      as: :token_membership,
      on: m.account_id == t.account_id and m.id == t.membership_id
    )
    |> join(:inner, [token_membership: m], a in ^Accounts.Account.Query.active(),
      as: :token_account,
      on: a.id == m.account_id
    )
    |> join(:left, [tokens: t], i in ^SSO.UserIdentity.Query.not_deleted(),
      as: :token_identity,
      on: i.id == t.user_identity_id
    )
    |> join(:left, [token_identity: i], p in ^SSO.IdentityProvider.Query.not_deleted(),
      as: :token_provider,
      on: p.id == i.provider_id and p.account_id == i.account_id
    )
    |> where(
      [tokens: t, token_identity: i, token_provider: p],
      t.auth_method == :magic_link or
        (t.auth_method == :sso and i.account_id == t.account_id and
           i.membership_id == t.membership_id and is_nil(i.provider_identifier_retired_at) and
           i.provider_identifier == t.sso_provider_identifier and p.enabled and
           p.issuer == t.sso_issuer)
    )
  end

  @doc """
  Preload the Member, its workspace, and an SSO session's identity with its
  provider from `authorized/1`'s joins — the facts a Subject is built from.
  """
  def with_preloaded_authority(queryable) do
    preload(
      queryable,
      [token_membership: m, token_account: a, token_identity: i, token_provider: p],
      membership: {m, account: a},
      user_identity: {i, provider: p}
    )
  end

  @doc """
  A bounded page of token ids past their own context's validity window — what
  `Auth.Jobs.TokenRetention` deletes next.

  Expiry was only ever enforced at read time, so an abandoned magic link or a
  session nobody signed out of stayed forever. Each context carries a different
  window, so the predicate is an OR per context rather than one cutoff; a row
  whose context is no longer recognized is prunable too, since `not_expired/2`
  cannot even evaluate it.
  """
  def prunable_ids(limit) when is_integer(limit) do
    expired =
      Enum.reduce(@contexts, dynamic([tokens: t], t.context not in ^@contexts), fn context, acc ->
        dynamic(
          [tokens: t],
          ^acc or
            (t.context == ^context and t.inserted_at <= ago(^validity_in_days(context), "day"))
        )
      end)

    all()
    |> where(^expired)
    |> limit(^limit)
    |> select([tokens: t], t.id)
  end

  @doc "Typable code tokens that still have guess attempts left (locked at 0)."
  def with_attempts_remaining(queryable),
    do: where(queryable, [tokens: t], t.remaining_attempts > 0)

  @doc "Validity window of a split-code magic-link code, in minutes — for the sent-page countdown."
  def magic_link_validity_in_minutes, do: @magic_link_validity_in_minutes

  @doc "Validity window after a magic link is verified while an MFA challenge is completed."
  def magic_link_verified_validity_in_minutes,
    do: @magic_link_verified_validity_in_minutes

  @doc "Absolute lifetime of fresh session proof; rotation preserves existing proof deadlines."
  def session_expires_at(%DateTime{} = proved_at),
    do: DateTime.add(proved_at, @session_validity_in_days, :day)

  defp validity_in_days("session"), do: @session_validity_in_days
  defp validity_in_days("magic_link"), do: @magic_link_validity_in_minutes / (24 * 60)

  # A verified factor's own window runs from `verified_at`, which can be a whole
  # pending window after `inserted_at` — the column this sweep compares. A
  # sign-up code keeps its context when verified, so it carries both windows.
  defp validity_in_days(context) when context in ~w(magic_link_verified sign_up),
    do: (@magic_link_validity_in_minutes + @magic_link_verified_validity_in_minutes) / (24 * 60)

  # A pending row is the same enrollment code before its email was accepted for
  # delivery, so it can never outlive the window it is promoted into.
  defp validity_in_days(context) when context in ~w(mfa_enrollment_pending mfa_enrollment),
    do: @mfa_enrollment_validity_in_minutes / (24 * 60)

  defp validity_in_days("oidc_identity_step_up"),
    do: @oidc_identity_step_up_validity_in_minutes / (24 * 60)

  defp validity_in_days(context) when context in ~w(email_change email_change_new),
    do: @email_change_validity_in_minutes / (24 * 60)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  @doc """
  Lock the token rows alone. `authorized/1` outer-joins the identity and
  provider, and PostgreSQL refuses to lock the nullable side of an outer join;
  the Member and workspace are judged, never locked, here.
  """
  def lock_tokens_for_update(queryable),
    do: lock(queryable, [tokens: t], fragment("FOR NO KEY UPDATE OF ?", t))

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [tokens: t], desc: t.inserted_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:tokens, :desc, :inserted_at}, {:tokens, :asc, :id}]
end
