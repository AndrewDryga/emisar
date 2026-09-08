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
end
