defmodule EmisarWeb.ConnCase do
  @moduledoc """
  Test case for Phoenix controllers / LiveViews. Wraps Phoenix.ConnTest with a
  sandboxed Repo and helpers for the browser's workspace sessions
  (`register_and_log_in/2`, `log_in_member/3`, `session_token/2`,
  `email_link_sign_in/3`) and for the staff realm (`log_in_staff/2`,
  `put_staff_cookie/2`).
  """

  use ExUnit.CaseTemplate
  alias Emisar.Accounts.Membership
  alias Emisar.Fixtures
  require ExUnit.Assertions

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
  Signs `membership` in on `conn` the way a browser carries it: a real session
  row for that Member, minted for this browser, appended to the cookie's
  `"sessions"` list (one entry per workspace, so an entry for the same
  workspace is replaced). The browser id is the conn's own, or a new one.
  Works on a fresh conn or one built by earlier calls; a conn that already
  made a request carries its session in the response cookie, so sign that
  browser in through a real flow instead.

  Options: `:auth_method` (`:magic_link` by default, or `:sso` with
  `:user_identity_id`) and `:mfa` (the session proved a second factor now).
  """
  def log_in_member(conn, %Membership{} = membership, opts \\ []) do
    conn = Phoenix.ConnTest.init_test_session(conn, %{})
    browser_id = Plug.Conn.get_session(conn, :browser_id) || Emisar.Crypto.random_secret()
    mfa_verified_at = if opts[:mfa], do: DateTime.utc_now()

    token =
      Fixtures.Auth.create_session_token!(
        membership,
        Keyword.get(opts, :auth_method, :magic_link),
        mfa_verified_at,
        %{},
        opts |> Keyword.take([:user_identity_id]) |> Keyword.put(:browser_id, browser_id)
      )

    entries =
      conn
      |> Plug.Conn.get_session(:sessions)
      |> List.wrap()
      |> List.keydelete(membership.account_id, 0)

    conn
    |> Plug.Conn.put_session(:sessions, entries ++ [{membership.account_id, token}])
    |> Plug.Conn.put_session(:browser_id, browser_id)
  end

  @doc "The raw session token `conn`'s cookie holds for `account`'s workspace, or nil."
  def session_token(%Plug.Conn{} = conn, %{id: account_id}) do
    case List.keyfind(Plug.Conn.get_session(conn, :sessions) || [], account_id, 0) do
      {^account_id, token} -> token
      nil -> nil
    end
  end

  @doc """
  Signs `email` in to `account` through the real emailed-code flow, as one
  browser: the workspace's email start, then the emailed link from the same
  cookie jar (the nonce cookie rides `Phoenix.ConnTest.recycle/1`). Returns the
  completing response. The code's email is taken from the test mailbox.
  """
  def email_link_sign_in(conn, %{slug: slug}, email) when is_binary(email) do
    started =
      Phoenix.ConnTest.dispatch(conn, EmisarWeb.Endpoint, :post, "/app/#{slug}/sign_in/email", %{
        "user" => %{"email" => email}
      })

    ExUnit.Assertions.assert_received({:email, %{text_body: body}})
    [_, token_id, code] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", body)

    started
    |> Phoenix.ConnTest.recycle()
    |> Phoenix.ConnTest.dispatch(EmisarWeb.Endpoint, :get, "/sign_in/magic/#{token_id}/#{code}")
  end

  @doc """
  Creates a workspace, its owner Member (a verified address, every runner), the
  default policy and the `account.created` audit row, as a sign-up does, and
  signs the owner in. Returns `{conn, owner, account}`. `attrs[:member]`
  overrides the owner's `:email` and `:display_name`; `attrs[:account]`
  overrides the account attrs, and a non-"free" `:plan` mints a matching
  subscription.
  """
  def register_and_log_in(conn, attrs \\ %{}) do
    # A unique default slug, as `Fixtures.Accounts.account_attrs/1` builds. Deriving
    # one from the name reads the table before inserting, and an async test's
    # sandbox transaction cannot see another test's uncommitted `test-co`, so two
    # tests would queue on the `accounts.slug` unique index instead of colliding.
    account =
      Fixtures.Accounts.create_account(
        Map.merge(%{name: "Test Co"}, attrs |> Map.get(:account, %{}) |> Map.new())
      )

    member_attrs =
      Map.merge(
        %{
          email: "user-#{System.unique_integer([:positive])}@example.com",
          display_name: "Test User"
        },
        attrs |> Map.get(:member, %{}) |> Map.new() |> Map.take([:email, :display_name])
      )

    owner =
      Fixtures.Memberships.create_membership(
        Map.merge(member_attrs, %{
          account_id: account.id,
          role: "owner",
          runner_access_mode: "all"
        })
      )

    {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
    Emisar.Repo.insert!(Emisar.Audit.Events.account_created(account, owner))
    {log_in_member(conn, owner), owner, account}
  end

  @doc """
  Signs a staff login in the way a browser carries it: the staff cookie holding a
  live 12-hour session. Returns `{conn, staff_session}`; pass `staff` to reuse a
  login, otherwise a fresh one is created.
  """
  def log_in_staff(conn, staff \\ Fixtures.Admin.create_staff()) do
    {raw, staff_session} = Fixtures.Admin.create_staff_session(staff)

    conn =
      put_staff_cookie(conn, %{
        "staff_token" => raw,
        "live_socket_id" => Emisar.Admin.staff_session_socket_topic(raw)
      })

    {conn, staff_session}
  end

  @doc """
  Puts `session` in the staff cookie on `conn`, encoded exactly as the staff
  routes' session store writes it. Staff routes refuse a test session from
  `init_test_session/2`, so every staff request carries this cookie instead.
  """
  def put_staff_cookie(conn, session) when is_map(session) do
    config = Plug.Session.init(EmisarWeb.Endpoint.staff_session_options())
    signer = %{conn | secret_key_base: EmisarWeb.Endpoint.config(:secret_key_base)}
    cookie = config.store.put(signer, nil, session, config.store_config)
    Plug.Test.put_req_cookie(conn, config.key, cookie)
  end

  @doc """
  Types `token` into the typed-confirm field of the `<.confirm_dialog>` with
  the given `dialog_id` (drives its `phx-change="confirm_typed"` form) and
  returns the rendered HTML. The `confirm_typed` handler holds the value in
  `@typed`, which (de)activates the Confirm button.
  """
  def type_confirm_token(lv, dialog_id, token) do
    lv
    |> Phoenix.LiveViewTest.element("##{dialog_id}-form")
    |> Phoenix.LiveViewTest.render_change(%{"confirm_token" => token})
  end

  @doc """
  Confirms the `<.confirm_dialog>` with the given `dialog_id`: typed dialogs
  submit their confirmation form, while plain dialogs click the Confirm button
  (`label`). Returns the rendered HTML.
  """
  def confirm_dialog(lv, dialog_id, label) do
    form_selector = "##{dialog_id}-form"

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
