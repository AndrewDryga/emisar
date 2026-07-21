defmodule EmisarWeb.ConnCase do
  @moduledoc """
  Test case for Phoenix controllers / LiveViews. Wraps Phoenix.ConnTest
  with a sandboxed Repo and convenience helpers (`log_in_user/2`,
  `register_and_log_in/1`).
  """

  use ExUnit.CaseTemplate
  alias Emisar.Fixtures

  using do
    quote do
      @endpoint EmisarWeb.Endpoint

      use EmisarWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import EmisarWeb.ConnCase
      alias Emisar.Fixtures
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
    token = Emisar.Auth.create_session_token!(user, :magic_link, false)

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
          full_name: "Test User"
        },
        Map.get(attrs, :user, %{})
      )

    # Plan lives on the account's subscription now (no `accounts.plan`
    # column). Pop a `:plan` override and mint a matching subscription for a
    # paid tier, mirroring `Fixtures.Accounts.create_account`'s shim.
    {plan, account_overrides} =
      attrs |> Map.get(:account, %{}) |> Map.new() |> Map.pop(:plan, "free")

    account_attrs = Map.merge(%{name: "Test Co"}, account_overrides)

    {:ok, user} = Emisar.Users.register_user(user_attrs)
    user = Fixtures.Users.confirm_user(user)

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        Map.put(account_attrs, :slug, Emisar.Accounts.suggest_unique_slug(account_attrs.name)),
        user
      )

    if plan != "free", do: Fixtures.Accounts.create_subscription(account, plan)

    {log_in_user(conn, user), user, account}
  end

  @doc "Builds an owner `%Subject{}` for a user + account pair (test convenience)."
  def owner_subject(user, account) do
    Fixtures.Subjects.subject_for(user, account, role: :owner)
  end

  @doc """
  Types `token` into the typed-confirm field of the `<.confirm_dialog>` with
  the given `dialog_id` (drives its `phx-change="confirm_typed"` form) and
  returns the rendered HTML. The `confirm_typed` handler holds the value in
  `@typed`, which (de)activates the Confirm button.
  """
  def type_confirm_token(lv, dialog_id, token) do
    lv
    |> Phoenix.LiveViewTest.element("##{dialog_id} form")
    |> Phoenix.LiveViewTest.render_change(%{"confirm_token" => token})
  end

  @doc """
  Confirms the `<.confirm_dialog>` with the given `dialog_id`: typed dialogs
  submit their confirmation form, while plain dialogs click the Confirm button
  (`label`). Returns the rendered HTML.
  """
  def confirm_dialog(lv, dialog_id, label) do
    form_selector = "##{dialog_id} form"

    if Phoenix.LiveViewTest.has_element?(lv, form_selector) do
      button_selector = "##{dialog_id} button"

      if Phoenix.LiveViewTest.has_element?(lv, "#{button_selector}[disabled]", label) do
        raise ArgumentError, "cannot submit disabled confirmation button"
      end

      lv
      |> Phoenix.LiveViewTest.element(form_selector)
      |> Phoenix.LiveViewTest.render_submit()
    else
      lv
      |> Phoenix.LiveViewTest.element("##{dialog_id} button", label)
      |> Phoenix.LiveViewTest.render_click()
    end
  end
end
