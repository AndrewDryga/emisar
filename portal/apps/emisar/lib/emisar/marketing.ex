defmodule Emisar.Marketing do
  @moduledoc """
  Public boundary for the unauthenticated marketing surface: early-access /
  product-update email capture, plus best-effort reporting of a completed
  signup for advertising attribution. Email capture is a pre-auth path; signup
  conversion reporting is a non-tenant side effect. Neither requires a
  `%Subject{}` or an Authorizer.
  """
  alias Emisar.Marketing.{Conversions, Signup}
  alias Emisar.{Repo, RequestContext, Users}

  @doc """
  Captures an early-access email. Idempotent: a repeat address updates the
  recorded source and still returns `{:ok, signup}`, so the response can't be
  used to probe whether an address is already on the list. Returns
  `{:error, changeset}` for an invalid email. Unauthenticated pre-auth path;
  threads the boundary's `%RequestContext{}` rather than a `%Subject{}`.
  """
  def capture_signup(attrs, _context \\ %RequestContext{}) do
    attrs
    |> Signup.Changeset.create()
    |> Repo.insert(
      on_conflict: {:replace, [:source, :updated_at]},
      conflict_target: :email,
      returning: true
    )
  end

  @doc """
  Reports a completed account signup for advertising attribution — best effort
  and asynchronous. The provider receives only the click identifier, the
  conversion time, and an opaque deduplication id; the user's email and id
  never leave the system. Always returns `:ok`: attribution without an eligible
  click identifier or an unconfigured provider sends nothing, and a delivery
  failure is logged.
  """
  def account_signed_up(%Users.User{} = user, attribution),
    do: Conversions.account_signed_up(user, attribution)

  @doc """
  Internal — erases the captured signup for `email`, for the user/account
  erasure flow. Takes the caller's transaction repo through `:repo` so it
  commits with the identity it belongs to. The capture list has no account and
  no retention sweep, so an erased person's address would otherwise sit here
  forever.
  """
  def erase_signup(email, opts \\ []) when is_binary(email) do
    repo = Keyword.get(opts, :repo, Repo)
    trimmed = String.trim(email)
    _ = Signup.Query.by_email(trimmed) |> repo.delete_all()
    :ok
  end
end
