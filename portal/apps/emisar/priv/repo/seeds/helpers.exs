defmodule Emisar.Seeds.Helpers do
  @moduledoc """
  The building blocks every seed section shares: relative timestamps, the
  workspace and owner-Member convergence each account goes through, trusted
  pack descriptors, whole-table lookups, and the console line a section prints
  when it is done.
  """

  alias Ecto.Multi
  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.ApiKeys
  alias Emisar.Audit
  alias Emisar.Auth
  alias Emisar.Auth.{Subject, UserToken}
  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.Catalog.PackBaseline
  alias Emisar.Crypto
  alias Emisar.Policies
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.Runbooks.Runbook
  alias Emisar.Runners.Runner

  @session_ids_key {__MODULE__, :temporary_session_ids}

  @doc "Owns the synchronous seed's temporary credentials, including cleanup after a failed section."
  def with_temporary_sessions(fun) do
    Process.put(@session_ids_key, [])

    try do
      fun.()
    after
      UserToken.Query.by_ids(Process.delete(@session_ids_key))
      |> UserToken.Query.by_context("session")
      |> Repo.delete_all()
    end
  end

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
  Finds the workspace by slug and returns `{account, owner}`. A missing one is
  created the way a proved sign-up creates it: the account, its owner Member
  with the address verified, the default policy, and the `account.created`
  receipt. A returning owner converges on its display name, a verified
  address, and no second factor.
  """
  def ensure_account(name, slug, owner_email, owner_name) do
    case Repo.fetch(Account.Query.not_deleted() |> Account.Query.by_slug(slug), Account.Query) do
      {:error, :not_found} ->
        create_account(name, slug, owner_email, owner_name)

      {:ok, account} ->
        {account, ensure_owner(account, owner_email, owner_name)}
    end
  end

  defp create_account(name, slug, owner_email, owner_name) do
    {:ok, %{account: account, owner: owner}} =
      Multi.new()
      |> Multi.insert(:account, Account.Changeset.create(%{name: name, slug: slug}))
      |> Multi.insert(:owner, &owner_changeset(&1.account, owner_email, owner_name))
      |> Multi.run(:policy, fn _repo, %{account: account, owner: owner} ->
        Policies.seed_policy(account.id, owner.id)
      end)
      |> Multi.insert(:audit, &Audit.Events.account_created(&1.account, &1.owner))
      |> Repo.commit_multi()

    {account, owner}
  end

  defp owner_changeset(%Account{} = account, email, name) do
    Membership.Changeset.sign_up_owner(%{
      account_id: account.id,
      email: email,
      display_name: name
    })
  end

  # The owner a previous seed (or a developer, by hand) left behind, back on its
  # seeded name and an address that signs in by email; one that is gone is
  # seated again.
  defp ensure_owner(%Account{} = account, email, name) do
    case Accounts.peek_sync_membership_by_email(account.id, email) do
      nil ->
        account |> owner_changeset(email, name) |> Repo.insert!()

      %Membership{} = owner ->
        owner
        |> Membership.Changeset.profile(%{display_name: name})
        |> verify_seeded_address()
        |> Repo.update!()
        |> clear_seeded_mfa()
    end
  end

  @doc """
  Marks a seeded Member's address verified. Nobody can prove a seeded `.dev`
  or `.test` inbox, and email sign-in only reaches a verified address.
  """
  def verify_seeded_address(%Ecto.Changeset{} = changeset) do
    if Ecto.Changeset.get_field(changeset, :email_verified_at),
      do: changeset,
      else: Ecto.Changeset.put_change(changeset, :email_verified_at, DateTime.utc_now())
  end

  @doc """
  Clears a second factor a developer enrolled by hand, so the sign-in
  walkthrough uses an email code. A seed never enrolls or proves a factor; it
  only takes one away.
  """
  def clear_seeded_mfa(%Membership{mfa_enabled_at: nil} = member), do: member

  def clear_seeded_mfa(%Membership{} = member) do
    member
    |> Membership.Changeset.mfa(nil, nil, [])
    |> Repo.update!()
  end

  @doc "Restores screenshot personas' email-sign-in baseline; never called for staff or ordinary accounts."
  def reset_screenshot_sign_in_policy(%Account{} = account) do
    account
    |> Account.Changeset.update(%{settings: %{require_mfa: false, require_sso: false}})
    |> Repo.update!()
  end

  @doc "A reseed converges a renamed account back onto its persona."
  def ensure_account_name(%Account{name: name} = account, name, _subject), do: account

  def ensure_account_name(%Account{} = account, name, %Subject{} = subject) do
    {:ok, updated} = Accounts.update_account(account, %{name: name}, subject)
    updated
  end

  @doc """
  The subject `member` acts as inside the account: the Member signed in
  through a temporary email-code session, re-read through the per-request
  predicate like any request.

  Only the local seeder fabricates a session; production sign-in owns its
  factors. Persisting the normal shape keeps domain gates and Member audit
  attribution in force. `with_temporary_sessions/1` deletes every row minted
  here, and only those.
  """
  def subject_for(%Account{} = account, %Membership{} = member) do
    ids = Process.get(@session_ids_key) || raise "seed sessions require with_temporary_sessions/1"
    {raw, digest} = Crypto.session_token()
    browser_digest = Crypto.hash(Crypto.random_secret())

    session =
      member
      |> UserToken.Changeset.session(digest, browser_digest, %{}, nil)
      |> Repo.insert!()

    Process.put(@session_ids_key, [session.id | ids])

    {:ok, session} = Auth.fetch_session_by_token(raw, account.id)
    Subject.for_session(session, %RequestContext{})
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

  @doc """
  Every shipped action descriptor for `pack_id` at `version` (nil: the current
  published version), shaped as a runner advertises them.

  A windowed previous version only carries descriptors when the catalog still
  retains its actions, so a fixture standing a pack behind fails loudly instead
  of advertising nothing.
  """
  def baseline_action_descriptors(pack_id, version \\ nil) do
    version =
      version || PackBaseline.current_version(pack_id) ||
        raise "missing current shipped pack version for #{pack_id}"

    hash =
      PackBaseline.lookup(pack_id, version) ||
        raise "missing shipped-pack baseline for #{pack_id} #{version}"

    manifest =
      PackBaseline.manifest(pack_id, version, hash) ||
        raise "shipped pack #{pack_id} #{version} retains no action descriptors"

    manifest
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

  @doc "One shipped action descriptor, by id, from the pack's baseline at `version` (nil: current)."
  def baseline_action_descriptor(pack_id, action_id, version \\ nil) do
    pack_id
    |> baseline_action_descriptors(version)
    |> Enum.find(&(&1["id"] == action_id)) ||
      raise "missing shipped action #{action_id} in pack #{pack_id} #{version || "(current)"}"
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
