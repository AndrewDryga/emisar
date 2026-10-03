defmodule Emisar.Users do
  @moduledoc """
  What remains of the shared personal login: erasing its row. Every
  credential, session and factor now belongs to a workspace Member
  (`Emisar.Accounts.Membership`); the `users` table is kept only until its
  history is folded into the Members that replaced it.
  """
  alias Emisar.{Mail, Marketing, Repo}
  alias Emisar.Users.User

  @doc """
  Internal — hard-delete the user row for the Accounts erasure flow. This is
  invoked from a console session; the user row's foreign keys cascade its
  user-owned records in the caller's transaction.
  """
  def delete_by_id(user_id, opts \\ []) do
    if Repo.valid_uuid?(user_id) do
      repo = Keyword.get(opts, :repo, Repo)

      User.Query.all()
      |> User.Query.by_id(user_id)
      |> repo.fetch(User.Query)
      |> case do
        {:ok, user} ->
          # The person's address also lives OUTSIDE every tenant: the
          # deliverability suppression list and the marketing capture list have
          # no account foreign key, so the row cascade cannot reach them and no
          # retention sweep ages them out. Each owning context erases its own
          # row in this transaction, so an erasure really removes the address.
          :ok = Mail.erase_suppression(user.email, repo: repo)
          :ok = Marketing.erase_signup(user.email, repo: repo)
          repo.delete(user)

        {:error, :not_found} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end
end
