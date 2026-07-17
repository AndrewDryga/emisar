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

    test "renders each action's operator docs, crawlable while collapsed", %{conn: conn} do
      pack = hd(PacksRegistry.list())
      action = Enum.find(pack.actions, &(&1.description != ""))
      html = conn |> get(~p"/packs/#{pack.id}") |> html_response(200)

      # The docs live in the server-rendered DOM (inside <details>), so
      # crawlers index them without JS or interaction.
      escaped_description =
        action.description |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      assert html =~ escaped_description
      assert html =~ "<details"
      assert html =~ "Side effects"
    end

    test "the capability chips read as one parallel by-default trio", %{conn: conn} do
      # linux-core spans all three tiers, so every chip renders.
      html = conn |> get(~p"/packs/linux-core") |> html_response(200)

      assert html =~ "allowed by default"
      assert html =~ "need approval by default"
      assert html =~ "denied by default"
      refute html =~ ~r/\d+ need approval</
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

    test "every pack lists at least one action and action ids are unique across the catalog" do
      packs = PacksRegistry.list()
      assert packs != []

      all_action_ids =
        for pack <- packs, action <- pack.actions do
          assert pack.actions != [], "pack #{pack.id} has no actions"
          action.id
        end

      assert all_action_ids == Enum.uniq(all_action_ids),
             "duplicate action id across the catalog"
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

      # consul: no detect.binaries block → binaries derived from requires
      # (consul survives as a useful CLI signal; generic curl is stripped).
      assert by_id["consul"].detect.binaries == ["consul"]
      assert "consul" in by_id["consul"].detect.processes
      assert 8500 in by_id["consul"].detect.ports

      # Required CLIs stay valid suggestion signals on supervised hosts.
      assert by_id["postgres"].detect.binaries == ["psql"]
      assert "postgres" in by_id["postgres"].detect.processes
      assert by_id["docker"].detect.binaries == ["docker"]
      assert "dockerd" in by_id["docker"].detect.processes

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
               "sha256:383032ecf8048bf5b735ffcb35c8f6fa9be1a33babbf34a7ae0496ea7bd01378"

      assert PacksRegistry.get("cassandra").content_hash ==
               "sha256:807338a04b1dc7757d8d615ee9d941c62f89572311eda5390a0fbefdb77ad743"
    end

    test "tarball_url/1 returns the immutable content-addressed URL for a known id" do
      pack = PacksRegistry.get("redis")
      assert {:ok, url} = PacksRegistry.tarball_url("redis")
      # The version + content hash are baked into the immutable path, so the
      # URL a page renders is the exact bytes its --hash pin was cut against.
      assert url == pack.tarball_url
      assert url =~ "/v1/packs/redis/#{pack.version}/"
      assert url =~ String.replace(pack.content_hash, "sha256:", "")
    end

    test "tarball_url/1 is :error for an unknown id" do
      assert PacksRegistry.tarball_url("nope") == :error
    end

    test "tarball_url/2 resolves a pack's current version to its tarball" do
      pack = PacksRegistry.get("redis")
      assert PacksRegistry.tarball_url("redis", pack.version) == {:ok, pack.tarball_url}
    end

    test "tarball_url/2 is :error for a version the pack doesn't advertise" do
      # No pack yet ships history in the bundled catalog, so any non-current
      # version is unknown; the remembered-version branch is covered purely in
      # EmisarWeb.PacksRegistry.PackTest.
      assert PacksRegistry.tarball_url("redis", "9.9.9") == :error
    end

    test "tarball_url/2 is :error for an unknown id" do
      assert PacksRegistry.tarball_url("nope", "0.1.0") == :error
    end

    test "build_action parses an exec action's command template" do
      pack = PacksRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert action.command == %{
               binary: "cloud-init",
               argv: ["single", "--name={{ args.module }}", "--frequency={{ args.frequency }}"]
             }
    end

    test "a script-kind action carries no command template" do
      pack = PacksRegistry.get("cassandra")
      action = Enum.find(pack.actions, &(&1.id == "cassandra.analyze_disk_pressure"))

      assert action.kind == "script"
      assert action.command == nil
    end

    test "resolve_command/4 returns the compiled command when the pinned hash matches" do
      pack = PacksRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PacksRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               pack.content_hash,
               nil
             ) == {:ok, action.command}
    end

    test "resolve_command/4 falls back to the advertised version when no hash is pinned" do
      pack = PacksRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PacksRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               pack.version
             ) == {:ok, action.command}
    end

    test "resolve_command/4 trusts a pinned hash over the version — a hash drift is :error" do
      # The pinned hash is authoritative: even a matching advertised version
      # must not paper over a hash the runner will actually enforce differently.
      pack = PacksRegistry.get("cloud-init")

      assert PacksRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               "sha256:#{String.duplicate("0", 64)}",
               pack.version
             ) == :error
    end

    test "resolve_command/4 is :error when neither hash nor version matches" do
      assert PacksRegistry.resolve_command("cloud-init", "cloud-init.single_module", nil, "9.9.9") ==
               :error

      assert PacksRegistry.resolve_command("cloud-init", "cloud-init.single_module", nil, nil) ==
               :error
    end

    test "resolve_command/4 is :error for a script-kind action even on a hash match" do
      pack = PacksRegistry.get("cassandra")

      assert PacksRegistry.resolve_command(
               "cassandra",
               "cassandra.analyze_disk_pressure",
               pack.content_hash,
               nil
             ) == :error
    end

    test "resolve_command/4 is :error for an unknown pack or action" do
      assert PacksRegistry.resolve_command("nope", "nope.x", "sha256:abc", nil) == :error

      pack = PacksRegistry.get("cloud-init")

      assert PacksRegistry.resolve_command(
               "cloud-init",
               "cloud-init.nope",
               pack.content_hash,
               nil
             ) ==
               :error
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
      assert by_id["postgres"]["detect"]["binaries"] == ["psql"]
      assert by_id["docker"]["detect"]["binaries"] == ["docker"]
      refute Map.has_key?(by_id, "cloudflare")

      # The JSON entry exposes ONLY the lean public shape — no hash, no
      # tarball URL, no description, no internal field. Every entry, not
      # just grafana, so a leaked field can't ride in on one pack.
      for entry <- body["packs"] do
        assert entry |> Map.keys() |> Enum.sort() == ~w(detect id name os),
               "unexpected keys on suggest entry #{entry["id"]}: #{inspect(Map.keys(entry))}"
      end
    end

    test "GET /packs/:id/pack.tar.gz redirects to the immutable tarball URL", %{conn: conn} do
      conn = get(conn, ~p"/packs/redis/pack.tar.gz")

      assert redirected_to(conn, 302) == PacksRegistry.get("redis").tarball_url
    end

    test "GET /packs/:id/pack.tar.gz 404s for an unknown pack", %{conn: conn} do
      conn = get(conn, ~p"/packs/this-does-not-exist/pack.tar.gz")
      assert json_response(conn, 404)["error"] =~ "unknown pack"
    end

    test "GET /packs/:id/versions/:version/pack.tar.gz redirects the current version", %{
      conn: conn
    } do
      redis = PacksRegistry.get("redis")
      conn = get(conn, ~p"/packs/redis/versions/#{redis.version}/pack.tar.gz")

      assert redirected_to(conn, 302) == redis.tarball_url
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "GET /packs/:id/versions/:version/pack.tar.gz 404s for an unknown version", %{conn: conn} do
      conn = get(conn, ~p"/packs/redis/versions/9.9.9/pack.tar.gz")
      assert json_response(conn, 404)["error"] =~ "unknown pack redis version 9.9.9"
    end

    test "GET /packs/:id/versions/:version/pack.tar.gz 404s for an unknown pack", %{conn: conn} do
      conn = get(conn, ~p"/packs/this-does-not-exist/versions/0.1.0/pack.tar.gz")
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
               ~w(description hash id name previous_versions requires_binaries requires_os retired_below tarball version)

      pack = PacksRegistry.get("redis")
      assert entry["hash"] == pack.content_hash
      assert entry["version"] == pack.version
      assert entry["tarball"] =~ "/packs/redis/pack.tar.gz"

      for prev <- entry["previous_versions"] do
        assert prev |> Map.keys() |> Enum.sort() == ~w(hash tarball version)
      end

      # Redis's security fix retires every pre-fix version, so the current
      # version is the floor and no vulnerable history remains in the window.
      assert entry["previous_versions"] == []
      assert entry["retired_below"] == pack.version
    end

    test "GET /packs/:id/pack.tar.gz redirect is briefly cacheable", %{conn: conn} do
      # A pack version's bytes are immutable (content-addressed), so the 302
      # itself is safe to cache — clients follow it to the real bytes.
      conn = get(conn, ~p"/packs/redis/pack.tar.gz")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end
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
