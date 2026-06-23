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

    test "the detail page pins the install hash and sets the meta description", %{conn: conn} do
      pack = PacksRegistry.get("cassandra")
      html = conn |> get(~p"/packs/#{pack.id}") |> html_response(200)

      # The install story is integrity-pinned: the pack's content_hash and
      # the --hash flag both render so a copy-paste install rejects a
      # tampered mirror.
      assert html =~ pack.content_hash
      assert html =~ "--hash"

      # The page's <meta name="description"> is the pack's own description
      # (so the SERP snippet describes this pack, not a generic blurb).
      assert html =~ ~s(<meta name="description" content="#{pack.description}")
    end

    test "the required-binaries banner shows only when the pack needs binaries", %{conn: conn} do
      with_binaries = Enum.find(PacksRegistry.list(), &(&1.requires_binaries != []))
      without_binaries = Enum.find(PacksRegistry.list(), &(&1.requires_binaries == []))

      assert with_binaries, "expected at least one pack with requires_binaries"
      assert without_binaries, "expected at least one pack with no requires_binaries"

      shown = conn |> get(~p"/packs/#{with_binaries.id}") |> html_response(200)
      assert shown =~ "Required binaries"

      hidden = conn |> get(~p"/packs/#{without_binaries.id}") |> html_response(200)
      refute hidden =~ "Required binaries"
    end

    test "the use-case CTA appears only on the cassandra and postgres detail pages",
         %{conn: conn} do
      # The footer links the use-case pages on every page, so assert the
      # body CTA's link TEXT ("Cassandra use case" / "Postgres use case"),
      # which the pack_detail template renders only on the matching pack.
      cassandra = conn |> get(~p"/packs/cassandra") |> html_response(200)
      assert cassandra =~ "Cassandra use case"

      postgres = conn |> get(~p"/packs/postgres") |> html_response(200)
      assert postgres =~ "Postgres use case"

      # A pack without a paired use case shows neither body CTA.
      other = conn |> get(~p"/packs/redis") |> html_response(200)
      refute other =~ "Cassandra use case"
      refute other =~ "Postgres use case"
    end

    test "every external link on a pack detail page carries the safe-rel pair", %{conn: conn} do
      # Each action id + the "View on GitHub"/"Source" links open off-site,
      # so a missing rel="noopener" is a reverse-tabnabbing hole.
      html = conn |> get(~p"/packs/redis") |> html_response(200)

      for link <- external_links(html) do
        assert link =~ ~s(rel="noopener noreferrer"),
               "external link missing safe rel on pack detail: #{link}"
      end
    end

    test "a path-traversal-ish id is a clean branded 404, never a 500", %{conn: conn} do
      # `..%2F..%2Fetc` decodes to the single segment `../../etc`, so it
      # binds to :id and resolves through PacksRegistry.get/1 like any
      # unknown id — no filesystem reach, no crash, just the 404 page.
      conn = get(conn, "/packs/..%2F..%2Fetc%2Fpasswd")
      assert conn.status == 404
      assert html_response(conn, 404) =~ "Page not found"
    end

    test "a known pack detail page stays indexable and carries the CSP header", %{conn: conn} do
      pack = hd(PacksRegistry.list())
      conn = get(conn, ~p"/packs/#{pack.id}")
      html = html_response(conn, 200)

      refute html =~ ~s(name="robots")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' 'nonce-"
    end

    test "the packs index stays indexable and carries the CSP header", %{conn: conn} do
      conn = get(conn, ~p"/packs")
      html = html_response(conn, 200)

      refute html =~ ~s(name="robots")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' 'nonce-"
    end

    test "each pack card shows version, vendor, action count, and a safe-rel source link",
         %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)
      pack = PacksRegistry.get("redis")

      # The card's metadata strip — version + vendor + the action count.
      assert html =~ "v#{pack.version}"
      assert html =~ pack.vendor
      assert html =~ "#{length(pack.actions)} actions"

      # The per-pack "Source" repo link opens off-site, so every external
      # anchor on the index must carry the safe-rel pair (reverse-tabnabbing).
      assert html =~ PacksRegistry.source_url(pack)

      for link <- external_links(html) do
        assert link =~ ~s(rel="noopener noreferrer"),
               "external link missing safe rel on /packs: #{link}"
      end
    end

    test "the packs index hero carries the authoring CTA and the live pack count",
         %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)

      # "Author your own pack" links the publishing guide.
      assert html =~ "Author your own pack"
      assert html =~ ~s(href="/docs/publishing-packs")

      # The hero count reflects the real registry size (rendered into the
      # "<n> packs · <m> declared actions" line).
      assert html =~ "#{PacksRegistry.pack_count()} packs"
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
      # grafana detects by process only — :3000 is shared with Node/dev apps.
      assert grafana.detect.ports == []

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
               "sha256:8c53a93854ca8571c13a5a62b76cd0f45808473132344e8fd38ced93904ed815"

      assert PacksRegistry.get("cassandra").content_hash ==
               "sha256:5f04e74317ed58448bf64d9c365dd0e452cb61a28aa22528457d7a0012a945af"
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
      assert grafana["detect"]["ports"] == []
      assert "grafana-server" in grafana["detect"]["processes"]
      assert grafana["detect"]["binaries"] == []
      # Lean: suggestion doesn't need the hash/tarball/description.
      refute Map.has_key?(grafana, "hash")
      refute Map.has_key?(grafana, "tarball")
    end

    test "GET /packs/suggest.json strips generic binaries and carries only the lean keys",
         %{conn: conn} do
      body = conn |> get(~p"/packs/suggest.json") |> json_response(200)
      by_id = Map.new(body["packs"], &{&1["id"], &1})

      # A curl-only pack collapses to an empty binary signal server-side
      # (the ubiquitous helpers — curl/jq/… — say nothing about the host),
      # and a remote-API-only pack with no detectable signal is omitted.
      assert by_id["grafana"]["detect"]["binaries"] == []
      refute Map.has_key?(by_id, "cloudflare")

      # The JSON entry exposes ONLY the lean public shape — no hash, no
      # tarball URL, no description, no internal field. Every entry, not
      # just grafana, so a leaked field can't ride in on one pack.
      for entry <- body["packs"] do
        assert entry |> Map.keys() |> Enum.sort() == ~w(detect id name os),
               "unexpected keys on suggest entry #{entry["id"]}: #{inspect(Map.keys(entry))}"
      end
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

    # The literal /packs.json, /packs/suggest.json, /packs/:id/pack.tar.gz
    # routes are declared before /packs/:id, so Phoenix's top-to-bottom
    # matching must dispatch them to the machine controller — never to the
    # HTML MarketingController.pack_detail (which would 404 ".json" / serve
    # an HTML page). conn.private[:phoenix_controller] is the proof.
    #
    test "the literal machine routes win over /packs/:id (route precedence)", %{conn: conn} do
      for {path, action} <- [
            {~p"/packs.json", :index},
            {~p"/packs/suggest.json", :suggest},
            {~p"/packs/redis/pack.tar.gz", :tarball}
          ] do
        conn = get(conn, path)
        assert conn.private[:phoenix_controller] == EmisarWeb.PackRegistryController
        assert conn.private[:phoenix_action] == action
      end

      # Contrast: a bare id falls through to the human detail page.
      detail = get(conn, ~p"/packs/redis")
      assert detail.private[:phoenix_controller] == EmisarWeb.MarketingController
      assert detail.private[:phoenix_action] == :pack_detail
    end

    test "GET /packs.json entries carry exactly the public catalog keys", %{conn: conn} do
      body = conn |> get(~p"/packs.json") |> json_response(200)
      entry = Enum.find(body["packs"], &(&1["id"] == "redis"))

      # The documented public shape — and nothing else. A stray internal
      # path or secret leaking into the registry index would be served to
      # every unauthenticated `emisar pack install`.
      assert entry |> Map.keys() |> Enum.sort() ==
               ~w(description hash id name requires_binaries requires_os tarball version)

      pack = PacksRegistry.get("redis")
      assert entry["hash"] == pack.content_hash
      assert entry["version"] == pack.version
      assert entry["tarball"] =~ "/packs/redis/pack.tar.gz"
    end

    test "GET /packs/:id/pack.tar.gz sets attachment filename + a short cache window",
         %{conn: conn} do
      conn = get(conn, ~p"/packs/redis/pack.tar.gz")

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="redis.tar.gz")
             ]

      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "the served tarball re-hashes to the advertised content_hash", %{conn: conn} do
      # The install-integrity contract: a runner downloads the tarball,
      # extracts the flat pack files, and recomputes the hash exactly the
      # way computePackHash does — pack.yaml + each manifest-listed action
      # (+ any referenced script), sorted by relpath, `relpath\0bytes\0`,
      # sha256. If the served bytes don't re-hash to the `hash` in
      # /packs.json, every `--hash`-pinned install would (correctly) fail.
      # redis is exec-only; cassandra references a script (and ships a
      # README + test dir the hash must ignore) — the pair covers both the
      # script-path branch and the "extra files don't change the hash" rule.
      advertised = conn |> get(~p"/packs.json") |> json_response(200)
      by_id = Map.new(advertised["packs"], &{&1["id"], &1})

      for id <- ~w(redis cassandra) do
        bin = conn |> get(~p"/packs/#{id}/pack.tar.gz") |> response(200)
        assert by_id[id]["hash"] == rehash_pack_tarball(bin), "tarball re-hash mismatch for #{id}"
      end
    end
  end

  # Mirror the runner's computePackHash over an extracted tarball's bytes,
  # so the test verifies the SERVED archive — not the disk source — re-hashes
  # to the advertised value.
  defp rehash_pack_tarball(bin) do
    {:ok, files} = :erl_tar.extract({:binary, bin}, [:memory, :compressed])
    by_rel = Map.new(files, fn {name, data} -> {to_string(name), data} end)

    manifest = YamlElixir.read_from_string!(Map.fetch!(by_rel, "pack.yaml"))
    action_rels = Map.get(manifest, "actions", []) || []

    action_entries =
      Enum.flat_map(action_rels, fn rel ->
        bytes = Map.fetch!(by_rel, rel)
        base = [{rel, bytes}]

        case get_in(YamlElixir.read_from_string!(bytes), ["execution", "script", "path"]) do
          nil -> base
          spath -> base ++ [{spath, Map.fetch!(by_rel, spath)}]
        end
      end)

    iodata =
      [{"pack.yaml", Map.fetch!(by_rel, "pack.yaml")} | action_entries]
      |> Enum.sort_by(fn {rel, _} -> rel end)
      |> Enum.map(fn {rel, data} -> [rel, <<0>>, data, <<0>>] end)

    "sha256:" <> Base.encode16(:crypto.hash(:sha256, iodata), case: :lower)
  end

  # Every external (`href="http…"`) anchor in rendered HTML, so a test can
  # assert the whole set carries the safe-rel pair (mirrors the helper in
  # marketing_test.exs — the packs pages are a separate suite).
  defp external_links(html) do
    ~r{<a\s[^>]*href="https?://[^>]*>}
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
  end
end
