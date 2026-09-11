defmodule Emisar.Seeds.Helpers do
  @moduledoc """
  The building blocks every seed section shares: relative timestamps, the
  persona and account convergence each workspace goes through, trusted pack
  descriptors, whole-table lookups, and the console line a section prints when
  it is done.
  """

  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.ApiKeys
  alias Emisar.Auth
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.Catalog.PackBaseline
  alias Emisar.Repo
  alias Emisar.Runbooks.Runbook
  alias Emisar.Runners.Runner
  alias Emisar.Users
  alias Emisar.Users.User

  @password "Sleep-tight-1234"

  @doc "The password every screenshot persona signs in with."
  def password, do: @password

  @doc "Prints one progress line; every section ends with one."
  def say(message, color \\ IO.ANSI.cyan()) do
    IO.puts(color <> message <> IO.ANSI.reset())
  end

  def now, do: DateTime.utc_now()
  def mins_ago(minutes), do: DateTime.add(now(), -minutes * 60, :second)
  def hours_ago(hours), do: DateTime.add(now(), -hours * 3600, :second)
  def days_ago(days), do: DateTime.add(now(), -days * 86_400, :second)
  def days_out(days), do: DateTime.add(now(), days * 86_400, :second)

  @doc """
  Registers a persona, or converges a returning one: the display name, the
  confirmation, and any second factor a developer enrolled by hand (cleared so
  the login walkthrough stays a password).
  """
  def ensure_persona(email, full_name) do
    case Users.fetch_user_by_email(email) do
      {:error, :not_found} ->
        {:ok, user} =
          Users.register_user(%{full_name: full_name, email: email, password: @password})

        user |> confirm_user() |> clear_seeded_mfa()

      {:ok, %User{} = user} ->
        user |> ensure_profile(full_name) |> confirm_user() |> clear_seeded_mfa()
    end
  end

  def confirm_user(%User{confirmed_at: nil} = user) do
    {:ok, confirmed} = user |> User.Changeset.confirm() |> Repo.update()
    confirmed
  end

  def confirm_user(%User{} = user), do: user

  def ensure_profile(%User{full_name: full_name} = user, full_name), do: user

  def ensure_profile(%User{} = user, full_name) do
    {:ok, updated} = Users.update_user_profile(%{full_name: full_name}, %Subject{actor: user})
    updated
  end

  def clear_seeded_mfa(%User{mfa_enabled_at: nil} = user), do: user

  def clear_seeded_mfa(%User{} = user) do
    otp = NimbleTOTP.verification_code(user.mfa_secret)
    {:ok, updated} = Auth.disable_mfa(otp, %Subject{actor: user})
    updated
  end

  @doc "Finds the account by slug, or creates it with `owner` as its owner."
  def ensure_account(name, slug, %User{} = owner) do
    case Repo.fetch(Account.Query.not_deleted() |> Account.Query.by_slug(slug), Account.Query) do
      {:error, :not_found} ->
        {:ok, account} = Accounts.create_account_with_owner(%{name: name, slug: slug}, owner)
        account

      {:ok, account} ->
        account
    end
  end

  @doc "A reseed converges a renamed account back onto its persona."
  def ensure_account_name(%Account{name: name} = account, name, _subject), do: account

  def ensure_account_name(%Account{} = account, name, %Subject{} = subject) do
    {:ok, updated} = Accounts.update_account(account, %{name: name}, subject)
    updated
  end

  @doc "The subject a standing member acts as inside the account."
  def subject_for(%Account{} = account, %User{} = member) do
    Subject.for_user(member, account, Accounts.peek_sync_membership(account.id, member.id))
  end

  # Plan now lives on the account's subscription (no `accounts.plan` column) —
  # mint one for a paid tier; free accounts simply have no subscription.
  # Idempotent AND reconciling: upsert refreshes a paid tier, and a free persona
  # has its subscription DELETED — so a reseed onto an account that was paid in a
  # prior run doesn't leave a stale row that misreports the plan.
  def seed_subscription(%Account{} = account, plan) do
    if plan == "free" do
      Repo.delete_all(Subscription.Query.by_account_id(Subscription.Query.all(), account.id))
    else
      {:ok, _} =
        Billing.upsert_subscription(account.id, %{plan: plan, status: "active"}, manual: true)
    end

    account
  end

  # Every "is this row already here?" lookup reads the account's WHOLE table. A
  # paginated context read would only ever see its first page, and the seed
  # deliberately fills each list past one page — so a page-scanning lookup stops
  # finding the rows it wrote last time and tries to insert them again, which is
  # a unique-violation crash, not a no-op reseed.
  def account_api_keys(%Account{} = account) do
    ApiKeys.ApiKey.Query.not_deleted()
    |> ApiKeys.ApiKey.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def peek_account_runbook(%Account{} = account, slug) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.by_account_id(account.id)
    |> Runbook.Query.by_slug(slug)
    |> Repo.peek()
  end

  # Seed runners through the registration changeset; the public product path is
  # enrollment-key self-registration, not an operator-created runner row. Seeded
  # names are deterministic, so they are also the stable identity unless a fixture
  # explicitly models a different external id.
  def insert_seed_runner(account_id, attrs) do
    attrs
    |> Map.put(:account_id, account_id)
    |> Map.put_new(:external_id, Map.fetch!(attrs, :name))
    |> Runner.Changeset.register()
    |> Repo.insert()
  end

  def pack_descriptor(pack_id, version) do
    version =
      version || PackBaseline.current_version(pack_id) ||
        raise "missing shipped pack baseline for #{pack_id}"

    hash = PackBaseline.lookup(pack_id, version)

    if is_nil(hash) do
      raise "missing shipped-pack baseline for #{pack_id} #{version}"
    end

    %{"version" => version, "hash" => hash}
  end

  def action_descriptor(pack_id, attrs) do
    Map.merge(
      %{
        "kind" => "exec",
        "risk" => "low",
        "side_effects" => [],
        "args" => [],
        "pack_id" => pack_id
      },
      attrs
    )
  end

  def baseline_action_descriptors(pack_id) do
    version =
      PackBaseline.current_version(pack_id) ||
        raise "missing current shipped pack version for #{pack_id}"

    hash =
      PackBaseline.lookup(pack_id, version) ||
        raise "missing shipped-pack baseline for #{pack_id} #{version}"

    pack_id
    |> PackBaseline.manifest(version, hash)
    |> get_in(["actions"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {action_id, descriptor} ->
      descriptor
      |> Map.drop(["args_schema"])
      |> Map.merge(%{
        "id" => action_id,
        "pack_id" => pack_id,
        "args" => get_in(descriptor, ["args_schema", "args"]) || []
      })
    end)
  end

  @doc "Aggregates stream chunks so terminal byte counts read believably."
  def chunks_bytes(chunks, stream) do
    chunks
    |> Enum.filter(fn {s, _} -> s == stream end)
    |> Enum.reduce(0, fn {_, t}, acc -> acc + byte_size(t) end)
  end

  # The release seeder runs beside the live portal, whose timeout worker correctly
  # settles visible in-flight runs while the demo runners are still offline. Keep
  # each synthetic running -> terminal history write inside one transaction so a
  # background sweep can only observe the finished fixture.
  def seed_terminal_history(seed_fun) do
    {:ok, run} = Repo.transaction(seed_fun)
    run
  end
end
