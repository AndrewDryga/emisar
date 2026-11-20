defmodule EmisarWeb.Components.DirectoryGroupsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EmisarWeb.DirectoryGroups

  test "group badges escape names and filter the same table without a hover preview" do
    group = %{
      id: "11111111-1111-7111-8111-111111111111",
      provider_id: "provider",
      display: "<script>group</script>",
      provider_name: "<script>provider</script>"
    }

    html =
      render_component(&DirectoryGroups.group_badge/1,
        id: "group-badge",
        group: group,
        path: "/app/acme/settings/sso/provider",
        filter_params: %{},
        prefix: "synced_members_"
      )

    assert html =~ "&lt;script&gt;group&lt;/script&gt;"
    refute html =~ "&lt;script&gt;provider&lt;/script&gt;"
    refute html =~ "border-l"
    refute html =~ "<script>"
    refute html =~ "Tooltip"
    assert html =~ "/app/acme/settings/sso/provider?synced_members_directory_group_id=#{group.id}"
  end

  test "active group badges clear only their own filter and use the shared active tone" do
    group = %{
      id: "11111111-1111-7111-8111-111111111111",
      display: "Platform",
      provider_name: "Keycloak (dev)"
    }

    params = %{
      "synced_members_directory_group_id" => group.id,
      "synced_members_search" => "Engineer",
      "synced_members_after" => "old",
      "group_access_search" => "Security",
      "group_access_after" => "other"
    }

    html =
      render_component(&DirectoryGroups.group_badge/1,
        id: "active-group",
        group: group,
        path: "/app/acme/settings/sso/provider",
        filter_params: params,
        prefix: "synced_members_"
      )

    document = LazyHTML.from_document(html)
    [href] = document |> LazyHTML.query("a[aria-current=true]") |> LazyHTML.attribute("href")
    assert URI.parse(href).path == "/app/acme/settings/sso/provider"

    assert URI.decode_query(URI.parse(href).query) == %{
             "synced_members_search" => "Engineer",
             "group_access_search" => "Security",
             "group_access_after" => "other"
           }

    assert html =~ "text-brand-200"
    assert html =~ "Clear Platform filter"

    assert document |> LazyHTML.query("a") |> LazyHTML.attribute("aria-label") == [
             "Clear Platform filter"
           ]

    refute html =~ "Keycloak"
  end

  describe "member_groups/1 counts" do
    defp group(n), do: %{id: "group-#{n}", display: "Group #{n}"}

    defp render_member_groups(attrs) do
      render_component(
        &DirectoryGroups.member_groups/1,
        [
          id: "member-groups",
          membership_id: "membership",
          path: "/app/acme/team",
          filter_params: %{}
        ] ++ attrs
      )
    end

    defp text(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.trim()
    end

    test "the overflow toggle uses a singular for one remaining group" do
      one = render_member_groups(summary: %{count: 2, groups: [group(1)]})
      many = render_member_groups(summary: %{count: 3, groups: [group(1)]})

      assert text(one, "#member-groups-toggle") == "+1 group"
      assert text(many, "#member-groups-toggle") == "+2 groups"
    end

    test "the expanded list count uses a singular for one group" do
      list = fn count, groups ->
        %{
          membership_id: "membership",
          search: "",
          error?: false,
          groups: groups,
          page: [],
          metadata: %Emisar.Repo.Paginator.Metadata{count: count}
        }
      end

      one =
        render_member_groups(
          summary: %{count: 1, groups: [group(1)]},
          list: list.(1, [group(1)])
        )

      many =
        render_member_groups(
          summary: %{count: 2, groups: [group(1)]},
          list: list.(2, [group(1), group(2)])
        )

      assert text(one, "nav[aria-label='Member groups pages'] span") == "1 group"
      assert text(many, "nav[aria-label='Member groups pages'] span") == "2 groups"
    end
  end
end
