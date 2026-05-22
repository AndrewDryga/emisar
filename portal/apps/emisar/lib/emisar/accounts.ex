defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Accounts.{Account, Membership, User}

  # -- Accounts ---------------------------------------------------------

  def get_account!(id), do: Repo.get!(Account, id)
  def get_account(id), do: Repo.get(Account, id)
  def get_account_by_slug(slug), do: Repo.get_by(Account, slug: slug)

  def list_accounts, do: Repo.all(Account)

  def list_accounts_for_user(%User{id: user_id}) do
    from(a in Account,
      join: m in Membership,
      on: m.account_id == a.id,
      where: m.user_id == ^user_id and is_nil(a.disabled_at),
      order_by: a.name
    )
    |> Repo.all()
  end

  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an account with the given user as `:owner`. Wrapped in a
  transaction so a half-created account is impossible.
  """
  def create_account_with_owner(account_attrs, %User{} = user) do
    Repo.transaction(fn ->
      with {:ok, account} <- create_account(account_attrs),
           {:ok, _membership} <- create_membership(%{account_id: account.id, user_id: user.id, role: "owner"}),
           {:ok, _policy} <- seed_default_policy(account.id, user.id) do
        account
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Workspace gets a conservative default policy on creation. Without
  # this, `Policies.evaluate(nil, ...)` would default-deny every
  # dispatch — which is correct but unhelpful as a first run.
  defp seed_default_policy(account_id, user_id) do
    Emisar.Policies.create_policy(
      account_id,
      %{
        name: "Default",
        description:
          "Auto-generated on account creation. Allows low/medium-risk read-only actions; high-risk requires approval; critical-risk is denied. Edit any time.",
        is_default: true,
        rules: %{
          "deny" => [
            %{"name" => "no-critical", "risk" => "critical"}
          ],
          "require_approval" => [
            %{"name" => "approve-high-risk", "risk" => "high"}
          ],
          "allow" => [
            %{"name" => "allow-low-medium", "max_risk" => "medium"}
          ]
        }
      },
      user_id
    )
  end

  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.changeset(account, attrs)
  end

  @doc """
  Suggests a unique slug for `name`. If the slugified name is taken,
  appends `-1`, `-2`, … until free.
  """
  def suggest_unique_slug(name) do
    base = slugify(name)
    do_suggest(base, 0)
  end

  defp do_suggest(base, n) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"

    case get_account_by_slug(candidate) do
      nil -> candidate
      _ -> do_suggest(base, n + 1)
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "team"
      s -> String.slice(s, 0, 60)
    end
  end

  # -- Memberships ------------------------------------------------------

  def list_memberships_for_account(account_id) do
    from(m in Membership,
      where: m.account_id == ^account_id,
      preload: [:user]
    )
    |> Repo.all()
  end

  def get_membership(account_id, user_id) do
    Repo.get_by(Membership, account_id: account_id, user_id: user_id)
  end

  @doc """
  The user's "current" account context for the UI. v0.1 just picks the
  most recently-joined non-disabled membership; later we can persist a
  preferred account in the user's profile.
  """
  def primary_membership(%User{id: user_id}) do
    from(m in Membership,
      join: a in Account, on: a.id == m.account_id,
      where: m.user_id == ^user_id and is_nil(a.disabled_at),
      order_by: [desc: m.inserted_at],
      preload: [:account, :user],
      limit: 1
    )
    |> Repo.one()
  end

  def create_membership(attrs) do
    %Membership{}
    |> Membership.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a membership's role with hierarchy invariants.

  Returns `{:error, :unauthorized}` for forbidden transitions:
    * Only owners can grant or revoke owner.
    * Admins cannot modify owners.
    * Nobody can promote themselves.
    * Nobody can demote/remove the last owner.

  The acting user is passed in `actor_user_id` so the guard can be
  enforced at the domain boundary, not just in LiveView templates.
  """
  def update_membership_role(%Membership{} = target, new_role, actor_user_id)
      when is_binary(actor_user_id) do
    actor = get_membership(target.account_id, actor_user_id)

    cond do
      is_nil(actor) ->
        {:error, :unauthorized}

      actor.role not in ~w(owner admin) ->
        {:error, :unauthorized}

      # Self-promotion is never allowed (an admin cannot promote themselves
      # to owner; an operator cannot promote themselves to admin).
      target.user_id == actor_user_id and target.role != new_role and
          role_rank(new_role) < role_rank(target.role) ->
        {:error, :cannot_self_promote}

      # Only owners can grant the owner role.
      new_role == "owner" and actor.role != "owner" ->
        {:error, :owner_required}

      # Only owners can take the owner role away from someone.
      target.role == "owner" and actor.role != "owner" ->
        {:error, :owner_required}

      # Don't demote the last owner.
      target.role == "owner" and new_role != "owner" and
          count_owners(target.account_id) <= 1 ->
        {:error, :last_owner}

      true ->
        target |> Membership.changeset(%{role: new_role}) |> Repo.update()
    end
  end

  # Legacy 2-arity wrapper still used by seeds + tests. Prefer the
  # 3-arity form in product code.
  def update_membership_role(%Membership{} = m, role) do
    m |> Membership.changeset(%{role: role}) |> Repo.update()
  end

  @doc """
  Remove a membership, enforcing the same invariants as role updates:

    * Only owners can remove owners.
    * Admins/owners can remove non-owners; nobody can remove themselves
      while they are the last owner.
    * The last owner cannot be removed at all.
  """
  def delete_membership(%Membership{} = target, actor_user_id)
      when is_binary(actor_user_id) do
    actor = get_membership(target.account_id, actor_user_id)

    cond do
      is_nil(actor) ->
        {:error, :unauthorized}

      actor.role not in ~w(owner admin) ->
        {:error, :unauthorized}

      target.role == "owner" and actor.role != "owner" ->
        {:error, :owner_required}

      target.role == "owner" and count_owners(target.account_id) <= 1 ->
        {:error, :last_owner}

      true ->
        Repo.delete(target)
    end
  end

  # Legacy 1-arity wrapper for seeds / tests / internal cleanup.
  def delete_membership(%Membership{} = m), do: Repo.delete(m)

  defp count_owners(account_id) do
    Repo.aggregate(
      from(m in Membership, where: m.account_id == ^account_id and m.role == "owner"),
      :count,
      :id
    )
  end

  defp role_rank("owner"), do: 0
  defp role_rank("admin"), do: 1
  defp role_rank("operator"), do: 2
  defp role_rank("viewer"), do: 3
  defp role_rank(_), do: 99

  @doc """
  Invites a user (by email) into the account with the given role.

  If no user with that email exists, a placeholder user is created
  (unconfirmed, no password) so we have something to hang the
  membership and invitation token off of. Returns
  `{:ok, %{membership: m, user: u, invitation_token: token, created?: bool}}`
  on success.

  The caller is responsible for sending the invitation email; this
  context only persists the records and mints the token.
  """
  def invite_user_to_account(account_id, email, role, invited_by_id)
      when is_binary(email) and is_binary(role) and is_binary(account_id) do
    email = String.downcase(String.trim(email))
    token = invitation_token()

    Repo.transaction(fn ->
      {user, created?} =
        case get_user_by_email(email) do
          %User{} = u ->
            {u, false}

          nil ->
            {:ok, u} =
              %User{}
              |> User.registration_changeset(%{email: email}, hash_password: false)
              |> Repo.insert()

            {u, true}
        end

      case get_membership(account_id, user.id) do
        nil ->
          {:ok, membership} =
            create_membership(%{
              account_id: account_id,
              user_id: user.id,
              role: role,
              invited_by_id: invited_by_id,
              invitation_token: token
            })

          Emisar.Audit.log(account_id, "user.invited",
            actor_kind: "user",
            actor_id: invited_by_id,
            subject_kind: "user",
            subject_id: user.id,
            subject_label: email,
            payload: %{role: role}
          )

          %{membership: membership, user: user, invitation_token: token, created?: created?}

        %Membership{} ->
          Repo.rollback(:already_member)
      end
    end)
  end

  defp invitation_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  Looks up a pending membership by invitation token. Returns the
  membership with `:account` and `:user` preloaded, or nil.
  """
  def find_invitation_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    from(m in Membership,
      where: m.invitation_token == ^token and is_nil(m.invitation_accepted_at),
      preload: [:account, :user]
    )
    |> Repo.one()
  end

  def find_invitation_by_token(_), do: nil

  @doc """
  Accepts a membership invitation: sets the user's full_name + password,
  clears the invitation token, marks invitation_accepted_at. Confirms
  the user since the invitation acceptance proves they own the email.

  Wrapped in a transaction so a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, %{} = user_attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <-
             Repo.get!(User, membership.user_id)
             |> User.registration_changeset(user_attrs)
             |> Repo.update(),
           {:ok, user} <- confirm_user(user),
           {:ok, membership} <-
             membership
             |> Ecto.Changeset.change(
               invitation_token: nil,
               invitation_accepted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             )
             |> Repo.update() do
        %{user: user, membership: membership}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # -- Users ------------------------------------------------------------

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)
  def get_user_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: String.downcase(email))

  def list_users, do: Repo.all(User)

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def update_user_profile(%User{} = user, attrs) do
    user |> User.profile_changeset(attrs) |> Repo.update()
  end

  def confirm_user(%User{} = user) do
    user |> User.confirm_changeset() |> Repo.update()
  end

  def record_sign_in(%User{} = user) do
    user |> User.sign_in_changeset() |> Repo.update()
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end
end
