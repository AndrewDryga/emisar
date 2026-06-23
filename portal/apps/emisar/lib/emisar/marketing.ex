defmodule Emisar.Marketing do
  @moduledoc """
  Public, unauthenticated capture from the marketing site — early-access /
  product-update email signups. Like sign-up it's a pre-auth path: no
  `%Subject{}`, no tenant scope, no Authorizer.
  """
  alias Emisar.Marketing.Signup
  alias Emisar.{Repo, RequestContext}

  @doc """
  Captures an early-access email. Idempotent: a repeat address updates the
  recorded source and still returns `{:ok, signup}`, so the response can't be
  used to probe whether an address is already on the list. Returns
  `{:error, changeset}` for an invalid email. Unauthenticated (a pre-auth path),
  so it threads a `%RequestContext{}` rather than a `%Subject{}`.
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
end
