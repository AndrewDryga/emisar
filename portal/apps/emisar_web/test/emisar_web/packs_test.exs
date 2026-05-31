defmodule EmisarWeb.PacksTest do
  use EmisarWeb.ConnCase, async: true

  alias EmisarWeb.PacksRegistry

  describe "GET /packs" do
    test "renders 200 and lists every registered pack by id + name", %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)

      assert html =~ "Action packs"
      assert html =~ "Publishing your own"

      # Each registered pack is rendered as a card — assert id + name
      # for every one so adding a pack without listing it surfaces.
      for pack <- PacksRegistry.list() do
        assert html =~ pack.id, "missing pack id #{pack.id}"
        assert html =~ pack.name, "missing pack name #{pack.name}"
      end
    end
  end

  describe "GET /packs/:id" do
    test "renders the per-pack detail page with all its actions", %{conn: conn} do
      pack = hd(PacksRegistry.list())
      html = conn |> get(~p"/packs/#{pack.id}") |> html_response(200)

      assert html =~ pack.name
      assert html =~ pack.description
      assert html =~ "v#{pack.version}"
      assert html =~ "Install"
      assert html =~ "Actions"

      # Every action id appears verbatim in the actions list.
      for action <- pack.actions do
        assert html =~ action.id, "missing action #{action.id}"
      end
    end

    test "returns a branded 404 for an unknown pack id", %{conn: conn} do
      conn = get(conn, ~p"/packs/this-pack-does-not-exist")
      assert html_response(conn, 404) =~ "Page not found"
    end
  end

  describe "GET /docs/publishing-packs" do
    test "renders the publish-your-own authoring guide", %{conn: conn} do
      html = conn |> get(~p"/docs/publishing-packs") |> html_response(200)
      assert html =~ "Publishing an action pack"
      assert html =~ "pack.yaml"
      assert html =~ "Submit to the registry"
    end
  end

  describe "sitemap" do
    test "lists /packs and a per-pack URL for every registered pack", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "https://emisar.dev/packs</loc>"
      assert body =~ "https://emisar.dev/docs/publishing-packs</loc>"

      for pack <- PacksRegistry.list() do
        assert body =~ "https://emisar.dev/packs/#{pack.id}</loc>"
      end
    end
  end

  describe "PacksRegistry" do
    test "list/0 returns alphabetically sorted packs" do
      ids = PacksRegistry.list() |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
    end

    test "get/1 returns the pack struct for a known id" do
      assert %PacksRegistry.Pack{id: "linux-core"} = PacksRegistry.get("linux-core")
    end

    test "get/1 returns nil for an unknown id" do
      assert PacksRegistry.get("nope") == nil
    end

    test "action_source_url/2 splits the action_id correctly" do
      pack = PacksRegistry.get("linux-core")
      action = Enum.find(pack.actions, &(&1.id == "linux.disk_usage"))
      url = PacksRegistry.action_source_url(pack, action)
      assert url =~ "linux-core/actions/disk_usage.yaml"
    end

    test "install_snippet/1 includes the pack id" do
      pack = PacksRegistry.get("cassandra")
      snippet = PacksRegistry.install_snippet(pack)
      assert snippet =~ "cassandra"
      assert snippet =~ "/etc/emisar/packs"
      assert snippet =~ "systemctl reload emisar"
    end
  end
end
