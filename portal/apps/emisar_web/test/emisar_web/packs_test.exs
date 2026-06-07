defmodule EmisarWeb.PacksTest do
  use EmisarWeb.ConnCase, async: true

  alias EmisarWeb.PacksRegistry

  describe "GET /packs" do
    test "renders 200 and lists every registered pack by id + name", %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)

      assert html =~ "Action packs"
      assert html =~ "Author your own pack"

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
    test "renders the author-your-own authoring guide", %{conn: conn} do
      html = conn |> get(~p"/docs/publishing-packs") |> html_response(200)
      assert html =~ "Author your own pack"
      assert html =~ "pack.yaml"
      assert html =~ "propose it to the registry"
    end
  end

  describe "sitemap" do
    test "lists /packs and a per-pack URL for every registered pack", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "https://emisar.dev/packs</loc>"
      assert body =~ "https://emisar.dev/docs/publishing-packs</loc>"
      assert body =~ "https://emisar.dev/compare/custom-mcp-server</loc>"
      refute body =~ "<lastmod>"

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

    test "install_snippet/1 includes the pack id, pack install, and the --hash pin" do
      pack = PacksRegistry.get("cassandra")
      snippet = PacksRegistry.install_snippet(pack)
      assert snippet =~ "cassandra"
      assert snippet =~ "/etc/emisar/packs"
      assert snippet =~ "emisar pack install"
      assert snippet =~ "--hash #{pack.content_hash}"
      assert snippet =~ "systemctl reload emisar"
    end

    test "every pack has a well-formed sha256 content hash" do
      for pack <- PacksRegistry.list() do
        assert pack.content_hash =~ ~r/^sha256:[0-9a-f]{64}$/,
               "bad content_hash for #{pack.id}: #{inspect(pack.content_hash)}"
      end
    end

    test "suggest_index strips generic helpers and omits undetectable packs" do
      by_id = Map.new(PacksRegistry.suggest_index(), &{&1.id, &1})

      # grafana: curl stripped server-side → no binary signal; detected by
      # its server process and listening port instead.
      grafana = by_id["grafana"]
      assert grafana.detect.binaries == []
      assert "grafana-server" in grafana.detect.processes
      assert 3000 in grafana.detect.ports

      # consul: no detect block → binaries derived from requires (consul,
      # which is service-specific, survives; a generic helper would not).
      assert by_id["consul"].detect.binaries == ["consul"]

      # cloudflare: requires only curl and declares no detect → all-empty
      # signal → omitted entirely (a remote-API pack isn't host-detectable).
      refute Map.has_key?(by_id, "cloudflare")

      # Lean shape: only id/name/os/detect — no hash/tarball/description.
      assert grafana |> Map.keys() |> Enum.sort() == [:detect, :id, :name, :os]
    end

    # Golden values captured from the Go runner's `emisar pack validate`
    # (runner/internal/packs computePackHash). If a pack's bytes change,
    # both the Go hash and this expectation must move together — a
    # mismatch here means the portal's Elixir hash has drifted from the
    # runner's, which would make every `--hash` install fail for users.
    # redis is exec-only; cassandra includes a script-kind action, so
    # the pair covers both hash code paths.
    test "content_hash matches the Go runner byte-for-byte (golden values)" do
      assert PacksRegistry.get("redis").content_hash ==
               "sha256:ccb7ba7d4929e73ced666676a7527e497140994a8961bd1a370ab023a84ad054"

      assert PacksRegistry.get("cassandra").content_hash ==
               "sha256:e3a4aa8dee0b3eea000ac622e2d73232ada728e4b0c9bf956f34ff35a9c613e5"
    end

    test "tarball/1 returns a gzip tarball with flat pack files" do
      assert {:ok, bin} = PacksRegistry.tarball("redis")
      # gzip magic bytes
      assert <<0x1F, 0x8B, _::binary>> = bin

      {:ok, files} = :erl_tar.extract({:binary, bin}, [:memory, :compressed])
      names = Enum.map(files, fn {name, _} -> to_string(name) end)
      assert "pack.yaml" in names
      assert Enum.any?(names, &String.starts_with?(&1, "actions/"))
    end

    test "tarball/1 is :error for an unknown id" do
      assert PacksRegistry.tarball("nope") == :error
    end
  end

  describe "registry endpoints" do
    test "GET /packs.json lists every pack with hash + tarball url", %{conn: conn} do
      body = conn |> get(~p"/packs.json") |> json_response(200)
      ids = Enum.map(body["packs"], & &1["id"])

      for pack <- PacksRegistry.list() do
        assert pack.id in ids, "missing #{pack.id} from index"
      end

      redis = Enum.find(body["packs"], &(&1["id"] == "redis"))
      assert redis["hash"] == PacksRegistry.get("redis").content_hash
      assert redis["tarball"] =~ "/packs/redis/pack.tar.gz"
    end

    test "GET /packs/suggest.json returns the lean detect index", %{conn: conn} do
      body = conn |> get(~p"/packs/suggest.json") |> json_response(200)
      ids = Enum.map(body["packs"], & &1["id"])

      assert "grafana" in ids
      refute "cloudflare" in ids

      grafana = Enum.find(body["packs"], &(&1["id"] == "grafana"))
      assert grafana["detect"]["ports"] == [3000]
      assert "grafana-server" in grafana["detect"]["processes"]
      assert grafana["detect"]["binaries"] == []
      # Lean: suggestion doesn't need the hash/tarball/description.
      refute Map.has_key?(grafana, "hash")
      refute Map.has_key?(grafana, "tarball")
    end

    test "GET /packs/:id/pack.tar.gz serves a gzip tarball", %{conn: conn} do
      conn = get(conn, ~p"/packs/redis/pack.tar.gz")
      assert response_content_type(conn, :gzip)
      bin = response(conn, 200)
      assert <<0x1F, 0x8B, _::binary>> = bin
    end

    test "GET /packs/:id/pack.tar.gz 404s for an unknown pack", %{conn: conn} do
      conn = get(conn, ~p"/packs/this-does-not-exist/pack.tar.gz")
      assert json_response(conn, 404)["error"] =~ "unknown pack"
    end
  end
end
