defmodule EmisarWeb.DirectoryGroupsLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Fixtures

  test "Team keeps normal member filters without directory groups or group reads", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    members =
      for n <- 1..7,
          do: Fixtures.SSO.create_directory_member(provider, full_name: "Engineer #{n}")

    member = hd(members)

    Fixtures.SSO.create_directory_group(provider,
      display: "Platform",
      identities: Enum.map(members, & &1.identity)
    )

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
    refute has_element?(lv, "#member-groups-#{member.membership.id}")
    refute has_element?(lv, "#filter-directory_group_id-choices")
    refute Map.has_key?(:sys.get_state(lv.pid).socket.assigns, :member_group_summaries)
    refute Map.has_key?(:sys.get_state(lv.pid).socket.assigns, :directory_group_picker)
    render_change(lv, "filter", %{"name_or_email" => "Engineer 1"})
    patched = assert_patch(lv)
    assert patched =~ "name_or_email=Engineer+1"
    assert has_element?(lv, "#member-row-#{member.membership.id}")
    assert length(:sys.get_state(lv.pid).socket.assigns.member_facts) == 1
    send(lv.pid, {:list_changed, :team, "membership.updated", member.user.id})
    render(lv)
    assert length(:sys.get_state(lv.pid).socket.assigns.member_facts) == 1
    assert :sys.get_state(lv.pid).socket.assigns.filter_params["name_or_email"] == "Engineer 1"
  end

  test "connection counts filter and focus Members on the same page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    member = Fixtures.SSO.create_directory_member(provider)

    platform =
      Fixtures.SSO.create_directory_group(provider,
        display: "Platform",
        identities: [member.identity]
      )

    security = Fixtures.SSO.create_directory_group(provider, display: "Security")
    path = ~p"/app/#{account}/settings/sso/#{provider.id}"

    {:ok, lv, _html} =
      live(conn, path <> "?synced_members_search=nobody&group_access_search=Platform")

    count = "#group-actions-#{platform.id} a[aria-label='Show Platform members']"
    count_html = lv |> element(count) |> render()
    assert count_html =~ "focus"
    assert count_html =~ "filter-synced_members_directory_group_id-choices"
    lv |> element(count) |> render_click()
    patched = assert_patch(lv)
    assert URI.parse(patched).path == path
    assert count_html =~ "#synced-members-#{provider.id}"

    assert URI.decode_query(URI.parse(patched).query) == %{
             "synced_members_directory_group_id" => platform.id,
             "group_access_search" => "Platform"
           }

    assert has_element?(lv, "#synced-member-groups-#{member.identity.id}", "Platform")

    assert has_element?(
             lv,
             "#synced-member-groups-#{member.identity.id} a[aria-current=true]",
             "Platform"
           )

    assert has_element?(
             lv,
             "#filter-synced_members_directory_group_id-choices summary",
             "Platform"
           )

    refute has_element?(lv, "#synced-member-groups-#{member.identity.id} [phx-hook=Tooltip]")
    refute has_element?(lv, "#synced-group-#{platform.id} [role=tooltip]", member.user.full_name)

    lv |> form("#group-access-search", %{group_access_search: "Security"}) |> render_change()
    assert_patch(lv)
    assert has_element?(lv, "#synced-group-#{security.id}")
    refute has_element?(lv, "#synced-group-#{platform.id}")

    lv
    |> form("#directory-members-search", %{synced_members_search: "nobody@example.test"})
    |> render_change()

    patched = assert_patch(lv)
    assert patched =~ "group_access_search=Security"
    assert has_element?(lv, "#synced-group-#{security.id}")
    assert has_element?(lv, "#synced-members-#{provider.id}", "No members match these filters")
    refute has_element?(lv, "#synced-member-groups-#{member.identity.id}")
    {attempt, id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
    send(lv.pid, {:refresh_directory, attempt, id})
    render(lv)
    assert has_element?(lv, "#synced-group-#{security.id}")
    refute has_element?(lv, "#synced-group-#{platform.id}")
    assert has_element?(lv, "#synced-members-#{provider.id}", "No members match these filters")
  end

  test "Team does not expose directory groups to viewers either", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    Fixtures.Memberships.force_role(membership, "viewer")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    member = Fixtures.SSO.create_directory_member(provider)

    Fixtures.SSO.create_directory_group(provider,
      display: "Private relationships",
      identities: [member.identity]
    )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
    refute html =~ "Private relationships"
    refute has_element?(lv, "#filter-directory_group_id-choices")
  end

  test "SSO group badges toggle the same list and stay selected outside the choice page", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    member = Fixtures.SSO.create_directory_member(provider)
    outsider = Fixtures.SSO.create_directory_member(provider)

    group =
      Fixtures.SSO.create_directory_group(provider,
        display: "Platform",
        identities: [member.identity]
      )

    Fixtures.SSO.create_directory_group(provider,
      display: "Security",
      identities: [outsider.identity]
    )

    for n <- 1..12, do: Fixtures.SSO.create_directory_group(provider, display: "Choice #{n}")
    other_provider = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)
    Fixtures.SSO.create_directory_group(other_provider, display: "Other connection secret")
    path = ~p"/app/#{account}/settings/sso/#{provider.id}"
    {:ok, lv, _html} = live(conn, path <> "?group_access_search=Security")
    badge = "#synced-member-groups-#{member.identity.id}-#{group.id}"
    dropdown = "#filter-synced_members_directory_group_id-choices"
    lv |> element(badge) |> render_click()
    patched = assert_patch(lv)
    assert patched =~ "synced_members_directory_group_id=#{group.id}"
    assert patched =~ "group_access_search=Security"
    assert has_element?(lv, badge <> "[aria-current=true]", "Platform")
    assert has_element?(lv, dropdown <> " summary", "Platform")
    assert length(:sys.get_state(lv.pid).socket.assigns.synced_members) == 1
    refute has_element?(lv, dropdown <> " [data-dropdown-panel]", provider.name)

    render_change(lv, "search_filter_options", %{
      "_target" => ["option_search", "directory_group_id"],
      "option_search" => %{"directory_group_id" => "Choice"}
    })

    picker = :sys.get_state(lv.pid).socket.assigns.directory_group_picker
    assert length(picker.options) == 11
    assert Enum.all?(picker.options, &(tuple_size(&1) == 2))
    refute has_element?(lv, dropdown <> " [data-dropdown-panel]", provider.name)
    assert picker.selected == group.id
    assert has_element?(lv, dropdown <> " summary", "Platform")
    refute has_element?(lv, dropdown, "Other connection secret")
    lv |> element(dropdown <> " button[phx-value-direction=next]") |> render_click()
    picker = :sys.get_state(lv.pid).socket.assigns.directory_group_picker
    assert length(picker.options) == 3
    {attempt, id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
    send(lv.pid, {:refresh_directory, attempt, id})
    render(lv)
    refreshed = :sys.get_state(lv.pid).socket.assigns.directory_group_picker
    assert refreshed.search == "Choice"
    assert refreshed.page == picker.page
    assert refreshed.options == picker.options

    render_click(lv, "page_filter_options", %{
      "field" => "directory_group_id",
      "direction" => "first"
    })

    assert :sys.get_state(lv.pid).socket.assigns.directory_group_picker.page == []
    assert length(:sys.get_state(lv.pid).socket.assigns.directory_group_picker.options) == 11

    lv |> element(badge) |> render_click()
    assert assert_patch(lv) == path <> "?group_access_search=Security"
    assert length(:sys.get_state(lv.pid).socket.assigns.synced_members) == 2
    refute has_element?(lv, badge <> "[aria-current=true]")
    assert has_element?(lv, dropdown <> " summary", "All")
  end

  test "SSO unavailable group filters stay visible and clearable without revealing other providers",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    Fixtures.SSO.create_directory_member(provider)
    other = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)
    group = Fixtures.SSO.create_directory_group(other, display: "Other provider group")
    path = ~p"/app/#{account}/settings/sso/#{provider.id}"

    for invalid <- [group.id, "invalid", %{"bad" => "shape"}] do
      {:ok, lv, html} =
        live(
          conn,
          path <> "?" <> Plug.Conn.Query.encode(%{"synced_members_directory_group_id" => invalid})
        )

      assert has_element?(
               lv,
               "#filter-synced_members_directory_group_id-choices summary",
               "Group unavailable"
             )

      assert :sys.get_state(lv.pid).socket.assigns.synced_members == []
      refute html =~ "Other provider group"
      lv |> element("#directory-members-search a", "Clear filters") |> render_click()
      assert_patch(lv, path)
      assert length(:sys.get_state(lv.pid).socket.assigns.synced_members) == 1
    end
  end

  test "member origin badges distinguish self-linked accounts from SCIM with plain explanations",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    linked =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id,
        provisioned_via: :oidc_link
      )

    synced = Fixtures.SSO.create_directory_member(provider)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
    assert has_element?(lv, "#member-origin-#{linked.id}-tt", "Linked")
    assert has_element?(lv, "#member-origin-#{linked.id}", "linked their existing account")
    refute has_element?(lv, "#member-origin-#{linked.id}-tt", "Synced")
    assert has_element?(lv, "#member-origin-#{synced.identity.id}-tt", "SCIM")

    assert has_element?(
             lv,
             "#member-origin-#{synced.identity.id}",
             "added this member through directory sync"
           )

    {:ok, team, _html} = live(conn, ~p"/app/#{account}/settings/team")

    assert has_element?(
             team,
             "#member-source-#{synced.membership.id}",
             "added this member through directory sync"
           )
  end

  test "SSO member group overflow is bounded and closes when membership is removed", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    member = Fixtures.SSO.create_directory_member(provider)

    for n <- 1..13 do
      Fixtures.SSO.create_directory_group(provider,
        display: "Group #{n}",
        identities: [member.identity]
      )
    end

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
    assert has_element?(lv, "#synced-member-groups-#{member.identity.id}-toggle", "+10 groups")
    render_click(lv, "toggle_member_groups", %{"user_id" => member.user.id})
    assert :sys.get_state(lv.pid).socket.assigns.member_group_list.user_id == member.user.id
    assert length(:sys.get_state(lv.pid).socket.assigns.member_group_list.groups) == 10
    render_click(lv, "page_member_groups", %{"direction" => "next"})
    assert length(:sys.get_state(lv.pid).socket.assigns.member_group_list.groups) == 3
    render_change(lv, "search_member_groups", %{"search" => "Group 13"})
    assert length(:sys.get_state(lv.pid).socket.assigns.member_group_list.groups) == 1
    Fixtures.Memberships.mark_membership_as_deleted(member.membership)
    {attempt, id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
    send(lv.pid, {:refresh_directory, attempt, id})
    render(lv)
    assert :sys.get_state(lv.pid).socket.assigns.member_group_list == nil
    render_click(lv, "search_member_groups", %{"search" => "Group"})
    assert :sys.get_state(lv.pid).socket.assigns.member_group_list == nil
  end
end
