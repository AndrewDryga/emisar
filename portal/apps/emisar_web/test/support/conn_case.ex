defmodule EmisarWeb.ConnCase do
  @moduledoc """
  Test case for Phoenix controllers / LiveViews. Wraps Phoenix.ConnTest
  with a sandboxed Repo and convenience helpers (`log_in_user/2`,
  `register_and_log_in/1`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint EmisarWeb.Endpoint

      use EmisarWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import EmisarWeb.ConnCase

      if Code.ensure_loaded?(Emisar.Fixtures) do
        import Emisar.Fixtures
      end
    end
  end

  setup tags do
    Emisar.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Logs the given `user` into the `conn` by writing a real session token
  into the session and returning the conn.
  """
  def log_in_user(conn, user) do
    token = Emisar.Auth.create_session_token!(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Registers a user, creates an account they own, and logs them in.
  Returns `{conn, user, account}`.
  """
  def register_and_log_in(conn, attrs \\ %{}) do
    user_attrs =
      Map.merge(
        %{
          email: "user-#{System.unique_integer([:positive])}@example.com",
          full_name: "Test User",
          password: "very-long-password-here"
        },
        Map.get(attrs, :user, %{})
      )

    account_attrs =
      Map.merge(
        %{name: "Test Co", plan: "free"},
        Map.get(attrs, :account, %{})
      )

    {:ok, user} = Emisar.Accounts.register_user(user_attrs)
    {:ok, user} = Emisar.Accounts.confirm_user(user)

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        Map.put(account_attrs, :slug, Emisar.Accounts.suggest_unique_slug(account_attrs.name)),
        user
      )

    {log_in_user(conn, user), user, account}
  end

  @doc "Builds an owner `%Subject{}` for a user + account pair (test convenience)."
  def owner_subject(user, account) do
    Emisar.Fixtures.subject_for(user, account, role: :owner)
  end
end
