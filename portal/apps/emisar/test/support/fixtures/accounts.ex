defmodule Emisar.Fixtures.Accounts do
  @moduledoc """
  Account test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Accounts.create_account/1`.
  """

  alias Emisar.Accounts.Account
  alias Emisar.{Billing, Repo}

  @doc ~S|Valid default account attrs. Pass `overrides` to change keys — a bare call for success cases, one override (`account_attrs(slug: "x")`) for a validation test.|
  def account_attrs(overrides \\ %{}) do
    %{
      name: Emisar.Fixtures.Random.unique_account_name(),
      slug: Emisar.Fixtures.Random.unique_slug()
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc ~S|Persists an account. A non-"free" `:plan` mints a matching subscription (plan lives on the subscription, not the account).|
  def create_account(attrs \\ %{}) do
    {plan, attrs} = pop_plan(attrs)

    {:ok, account} =
      attrs
      |> account_attrs()
      |> Account.Changeset.create()
      |> Repo.insert()

    maybe_seed_plan(account, plan)
    account
  end

  @doc "Test helper: update an existing account's embedded settings (require_mfa / require_sso / max_grant_lifetime_seconds)."
  def set_account_settings(%Account{} = account, settings_attrs) do
    account
    |> Account.Changeset.update(%{settings: settings_attrs})
    |> Repo.update!()
  end

  @doc "Soft-deletes an account (sets `deleted_at`), returning the tombstoned struct."
  def mark_account_as_deleted(%Account{} = account) do
    account
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update!()
  end

  @doc """
  Mints (or refreshes) the account's subscription at `plan` — the way a real
  account lands on a paid tier (Paddle webhook → `Billing.upsert_subscription`).
  `opts` overrides defaults (`status: "active"`).
  """
  def create_subscription(%Account{} = account, plan, opts \\ []) when is_binary(plan) do
    attrs = Map.merge(%{plan: plan, status: "active"}, Map.new(opts))
    {:ok, subscription} = Billing.upsert_subscription(account.id, attrs)
    subscription
  end

  @doc """
  Internal — `Subjects`/`create_account`. Plan lives on the subscription now;
  fixture callers still pass `plan:` for convenience. Pop it and mint a
  subscription only for a real paid tier.
  """
  def pop_plan(attrs), do: attrs |> Map.new() |> Map.pop(:plan, "free")

  @doc "Internal — `Subjects`/`create_account`. Mints a subscription for a non-free plan."
  def maybe_seed_plan(%Account{} = account, plan) when is_binary(plan) and plan != "free",
    do: create_subscription(account, plan)

  def maybe_seed_plan(_account, _plan), do: :ok
end
