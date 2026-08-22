defmodule EmisarWeb.PacksTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.ActionContract
  alias Emisar.Catalog.PublishedRegistry
  alias Emisar.RawJSON
  alias Emisar.Runbooks

  describe "GET /packs" do
    test "renders 200 and lists every registered pack by id + name", %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)

      assert html =~ "Action packs"
      assert html =~ "Author your own pack"

      # Each registered pack is rendered as a card — assert id + name
      # for every one so adding a pack without listing it surfaces.
      for pack <- PublishedRegistry.list() do
        assert html =~ pack.id, "missing pack id #{pack.id}"
        assert html =~ pack.name, "missing pack name #{pack.name}"
      end
    end
  end

  describe "GET /packs/:id" do
    test "renders the per-pack detail page with all its actions", %{conn: conn} do
      pack = hd(PublishedRegistry.list())
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
      pack = hd(PublishedRegistry.list())
      action = Enum.find(pack.actions, &(&1.description != ""))
      html = conn |> get(~p"/packs/#{pack.id}") |> html_response(200)

      # The docs live in the server-rendered DOM (inside <details>), so
      # crawlers index them without JS or interaction.
      escaped_description =
        action.description |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      assert html =~ escaped_description
      assert html =~ "<details"
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
      pack = PublishedRegistry.get("cassandra")
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

    test "the content hash lives in the install command's own scroll, not a page-wide row", %{
      conn: conn
    } do
      pack = PublishedRegistry.get("cassandra")
      html = conn |> get(~p"/packs/#{pack.id}") |> html_response(200)

      # A real sha256 (`sha256:` + 64 hex) is one unbreakable 71-char token that
      # pushed /packs/:id past a 390px viewport (UI-007). It's now pinned IN the
      # command (`--hash`), not a separate free-standing row, and the command sits
      # in a locally-scrolling <pre> — so the long token scrolls the code block, not
      # the page.
      assert pack.content_hash =~ ~r/\Asha256:[0-9a-f]{64}\z/,
             "expected a real sha256 content hash to regress the overflow against"

      assert html =~ "--hash #{pack.content_hash}"
      assert html =~ ~r/<pre[^>]*overflow-x-auto/
    end

    test "the required-binaries banner shows only when the pack needs binaries", %{conn: conn} do
      with_binaries = Enum.find(PublishedRegistry.list(), &(&1.requires_binaries != []))
      without_binaries = Enum.find(PublishedRegistry.list(), &(&1.requires_binaries == []))

      assert with_binaries, "expected at least one pack with requires_binaries"
      assert without_binaries, "expected at least one pack with no requires_binaries"

      shown = conn |> get(~p"/packs/#{with_binaries.id}") |> html_response(200)
      assert shown =~ "Required binaries"

      hidden = conn |> get(~p"/packs/#{without_binaries.id}") |> html_response(200)
      refute hidden =~ "Required binaries"
    end

    test "the setup section names the pack's own credentials and marks the required ones",
         %{conn: conn} do
      # The point of carrying setup through catalog.json: an operator deciding
      # whether to install can see the credential BEFORE installing, instead of
      # only from `emisar pack info` on a host that already has the pack.
      html = conn |> get(~p"/packs/sentry") |> html_response(200)

      assert html =~ "Setup"
      assert html =~ "SENTRY_AUTH_TOKEN"
      assert html =~ "SENTRY_URL"
      assert html =~ "required"
      assert html =~ "default https://sentry.io"
      assert html =~ "sudo emisar pack verify sentry"
      assert html =~ "sentry.list_organizations"
    end

    test "a pack that needs no credentials says so instead of showing an empty section",
         %{conn: conn} do
      local = Enum.find(PublishedRegistry.list(), &(&1.setup.env == [] and &1.setup.notes != []))
      assert local, "expected at least one local-host pack with no env and some notes"

      html = conn |> get(~p"/packs/#{local.id}") |> html_response(200)

      assert html =~ "Setup"
      refute html =~ "Environment"
    end

    test "an authored backtick in a setup note renders as code, not a literal tick",
         %{conn: conn} do
      # 31 notes across 22 packs write inline code with markdown backticks;
      # printing the ticks verbatim is what this page used to do.
      html = conn |> get(~p"/packs/frr") |> html_response(200)

      assert html =~ ~r{<code[^>]*>usermod -aG frrvty emisar</code>}
      refute html =~ "`usermod"
    end

    test "the pack reference footer link carries the brand CTA affordance", %{conn: conn} do
      html = conn |> get(~p"/packs/redis") |> html_response(200)

      [pack_reference] =
        Regex.run(~r{<a[^>]*href="/docs/action-packs"[^>]*>.*?</a>}s, html)

      assert pack_reference =~ "Pack reference"
      assert pack_reference =~ "hero-arrow-right"
      assert pack_reference =~ "text-brand-400"
      assert pack_reference =~ "min-h-10"
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
      # binds to :id and resolves through PublishedRegistry.get/1 like any
      # unknown id — no filesystem reach, no crash, just the 404 page.
      conn = get(conn, "/packs/..%2F..%2Fetc%2Fpasswd")
      assert conn.status == 404
      assert html_response(conn, 404) =~ "Page not found"
    end

    test "a known pack detail page stays indexable and carries the CSP header", %{conn: conn} do
      pack = hd(PublishedRegistry.list())
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
      pack = PublishedRegistry.get("redis")

      # The card's metadata strip — version + vendor + the action count.
      assert html =~ "v#{pack.version}"
      assert html =~ pack.vendor
      assert html =~ "#{length(pack.actions)} actions"

      # The per-pack "Source" repo link opens off-site, so every external
      # anchor on the index must carry the safe-rel pair (reverse-tabnabbing).
      assert html =~ EmisarWeb.PacksRegistry.source_url(pack)

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
      assert html =~ "#{PublishedRegistry.pack_count()} packs"
    end
  end

  describe "GET /docs/publishing-packs" do
    test "renders the author-your-own authoring guide", %{conn: conn} do
      html = conn |> get(~p"/docs/publishing-packs") |> html_response(200)
      assert html =~ "Author your own pack"
      assert html =~ "pack.yaml"
      assert html =~ "Keep it private, or propose it"
    end
  end

  describe "sitemap" do
    test "lists /packs and a per-pack URL for every registered pack", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "https://emisar.dev/packs</loc>"
      assert body =~ "https://emisar.dev/docs/publishing-packs</loc>"
      assert body =~ "https://emisar.dev/compare/custom-mcp-server</loc>"
      refute body =~ "<lastmod>"

      for pack <- PublishedRegistry.list() do
        assert body =~ "https://emisar.dev/packs/#{pack.id}</loc>"
      end
    end
  end

  describe "action_source_url/2" do
    test "splits the action_id into the pack's action YAML path" do
      pack = PublishedRegistry.get("linux-core")
      action = Enum.find(pack.actions, &(&1.id == "linux.disk_usage"))
      url = EmisarWeb.PacksRegistry.action_source_url(pack, action)
      assert url =~ "linux-core/actions/disk_usage.yaml"
    end
  end

  describe "install_snippet/1" do
    test "is one integrity-pinned command — no --dest, no manual reload" do
      pack = PublishedRegistry.get("cassandra")
      snippet = EmisarWeb.PacksRegistry.install_snippet(pack)

      assert snippet =~ "emisar pack install cassandra"
      assert snippet =~ "--hash #{pack.content_hash}"
      # --dest defaults to the runner's packs dir, and the command reloads a running
      # daemon itself, so neither belongs in the copy-paste snippet.
      refute snippet =~ "--dest"
      refute snippet =~ "systemctl reload"
    end
  end

  describe "setup_segments/1" do
    test "splits an authored string into text and code runs on its backticks" do
      assert EmisarWeb.PacksRegistry.setup_segments("prefer the `frrvty` group") == [
               text: "prefer the ",
               code: "frrvty",
               text: " group"
             ]

      assert EmisarWeb.PacksRegistry.setup_segments("no code here") == [text: "no code here"]
      assert EmisarWeb.PacksRegistry.setup_segments("") == []
      assert EmisarWeb.PacksRegistry.setup_segments(nil) == []
    end

    test "an unbalanced backtick stays literal instead of swallowing the rest of the string" do
      # A pack author is not obliged to balance ticks, and the run after an
      # unmatched one is ordinary prose — rendering it as code would be wrong.
      assert EmisarWeb.PacksRegistry.setup_segments("run `usermod on the host") == [
               text: "run ",
               text: "`usermod on the host"
             ]
    end

    test "an https markdown link becomes a link segment" do
      assert EmisarWeb.PacksRegistry.setup_segments("mint it [here](https://github.com/x?a=b).") ==
               [
                 {:text, "mint it "},
                 {:link, "here", "https://github.com/x?a=b"},
                 {:text, "."}
               ]
    end

    test "only https is linkable, so a pack cannot put a hostile scheme on a public page" do
      # Packs are administrator-installed and the catalog is hashed, but third
      # parties publish packs too and this page is public and unauthenticated.
      for scheme <- ["javascript:alert(1)", "data:text/html,x", "http://plain.example"] do
        segments = EmisarWeb.PacksRegistry.setup_segments("see [x](#{scheme})")
        refute Enum.any?(segments, &match?({:link, _, _}, &1)), "#{scheme} must not link"
      end
    end

    test "a backtick inside a link's URL never opens a code span" do
      # The link is parsed first, so its URL is opaque to the backtick splitter —
      # otherwise one tick in a query string would swallow the rest of the note.
      assert EmisarWeb.PacksRegistry.setup_segments("[a](https://x.test/?q=`b`) then `c`") == [
               {:link, "a", "https://x.test/?q=`b`"},
               {:text, " then "},
               {:code, "c"}
             ]
    end

    test "every authored setup string in the live catalog renders without a stray backtick" do
      for pack <- PublishedRegistry.list(),
          text <-
            [pack.setup.summary | pack.setup.notes] ++
              Enum.map(pack.setup.env, & &1.description),
          text != nil,
          {kind, value} <- EmisarWeb.PacksRegistry.setup_segments(text),
          kind == :code do
        refute value =~ "`", "unbalanced backtick in #{pack.id}: #{text}"
      end
    end
  end

  describe "shell break-glass argument envelope" do
    # The shell pack's `script` is the largest declared arg in the catalog,
    # and its bound is derived from the shared 32 KB action-args envelope
    # (persistence changeset, MCP raw span, runbook materialization): a
    # control byte escapes to six JSON bytes worst-case, and the
    # {"script":""} wrapper adds the rest. If either side moves, this pins
    # the published pack schema to the envelope so a schema-legal script can
    # never be rejected by the control plane before dispatch.
    test "the script bound is the largest that always fits the encoded envelope" do
      envelope = Runbooks.definition_limit!(:max_action_args_bytes)
      overhead = byte_size(~s({"script":""}))

      assert shell_script_spec()["validation"]["max_length"] == div(envelope - overhead, 6)
    end

    test "the exact maximum passes the pack contract and always fits; one byte beyond fails" do
      spec = shell_script_spec()
      max_length = spec["validation"]["max_length"]
      descriptor = %{"args_schema" => %{"args" => [spec]}}

      # A script of control bytes is the escaping worst case — Jason encodes
      # each 0x01 byte as a six-byte backslash-u0001 escape.
      worst_case = String.duplicate(<<1>>, max_length)

      assert ActionContract.validate(%{"script" => worst_case}, descriptor) == :ok

      assert byte_size(Jason.encode!(%{"script" => worst_case})) <=
               Runbooks.definition_limit!(:max_action_args_bytes)

      over = String.duplicate(<<1>>, max_length + 1)

      assert {:error, %{arg: "script", code: "max_length"}} =
               ActionContract.validate(%{"script" => over}, descriptor)
    end

    test "the MCP raw-args cap carries a fully escaped maximum script" do
      max_length = shell_script_spec()["validation"]["max_length"]

      # A client is free to spell every byte as a six-byte backslash-u0001 escape; the raw args
      # span of a maximum script must still clear the MCP boundary's cap.
      assert {:ok, %{action_args: args}} =
               max_length |> escaped_tool_call() |> RawJSON.tool_call()

      assert byte_size(args) == max_length * 6 + byte_size(~s({"script":""}))

      assert (max_length + 1) |> escaped_tool_call() |> RawJSON.tool_call() ==
               {:error, :action_args_too_large}
    end
  end

  describe "registry endpoints" do
    test "GET /packs.json lists every pack with hash + tarball url", %{conn: conn} do
      body = conn |> get(~p"/packs.json") |> json_response(200)
      ids = Enum.map(body["packs"], & &1["id"])

      for pack <- PublishedRegistry.list() do
        assert pack.id in ids, "missing #{pack.id} from index"
      end

      redis = Enum.find(body["packs"], &(&1["id"] == "redis"))
      assert redis["hash"] == PublishedRegistry.get("redis").content_hash
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

    test "GET /packs/suggest.json carries only explicit evidence and the lean keys",
         %{conn: conn} do
      body = conn |> get(~p"/packs/suggest.json") |> json_response(200)
      by_id = Map.new(body["packs"], &{&1["id"], &1})

      # Runtime requirements never become detection evidence. Packs without an
      # explicit detect block are omitted; declared processes and ports remain.
      assert by_id["grafana"]["detect"]["binaries"] == []
      assert by_id["postgres"]["detect"]["binaries"] == []
      assert by_id["docker"]["detect"]["binaries"] == []
      refute Map.has_key?(by_id, "cloudflare")
      refute Map.has_key?(by_id, "git-local")
      refute Map.has_key?(by_id, "oidc-jwks")
      assert "nomad" in by_id["nomad"]["detect"]["processes"]
      assert 4646 in by_id["nomad"]["detect"]["ports"]

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

      assert redirected_to(conn, 302) == PublishedRegistry.get("redis").tarball_url
    end

    test "GET /packs/:id/pack.tar.gz 404s for an unknown pack", %{conn: conn} do
      conn = get(conn, ~p"/packs/this-does-not-exist/pack.tar.gz")
      assert json_response(conn, 404)["error"] =~ "unknown pack"
    end

    test "GET /packs/:id/versions/:version/pack.tar.gz redirects the current version", %{
      conn: conn
    } do
      redis = PublishedRegistry.get("redis")
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

      pack = PublishedRegistry.get("redis")
      assert entry["hash"] == pack.content_hash
      assert entry["version"] == pack.version
      assert entry["tarball"] =~ "/packs/redis/pack.tar.gz"

      for prev <- entry["previous_versions"] do
        assert prev |> Map.keys() |> Enum.sort() == ~w(hash tarball version)
      end

      # Redis's security fix set a retirement floor; the version window may
      # keep post-fix history, but no version below the floor — vulnerable
      # history never reappears as the pack keeps releasing.
      assert entry["retired_below"] == "0.3.9"

      for prev <- entry["previous_versions"] do
        assert Version.compare(prev["version"], entry["retired_below"]) in [:eq, :gt]
      end
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

  # The shell.run_script `script` arg spec straight from the bundled catalog
  # artifact — the same bytes the registry serves and PackBaseline pins.
  defp shell_script_spec do
    catalog =
      :emisar
      |> Application.app_dir("priv/packs/catalog.json")
      |> File.read!()
      |> Jason.decode!()

    pack = Enum.find(catalog["packs"], &(&1["id"] == "shell"))
    action = Enum.find(pack["actions"], &(&1["id"] == "shell.run_script"))
    [spec] = action["args"]
    spec
  end

  # A run_action tools/call body whose script is `length` control bytes, each
  # spelled as the six-byte backslash-u0001 escape — the widest raw span a schema-legal
  # script of that length can occupy.
  defp escaped_tool_call(length) do
    script = String.duplicate("\\u0001", length)

    ~s({"method":"tools/call","params":{"name":"run_action","arguments":{"args":{"script":") <>
      script <> ~s("}}}})
  end
end
