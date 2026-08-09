defmodule EmisarWeb.RunbookImportLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runbooks

  test "imports pasted canonical JSON as a draft and opens the editor", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    definition = Emisar.Fixtures.Runbooks.default_definition()

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/import")

    assert html =~ "Drop a JSON file here or choose one"
    assert html =~ "or paste JSON"
    assert has_element?(lv, "#runbook-import.max-w-3xl:not(.mx-auto)")
    refute has_element?(lv, "#runbook-import.border")

    lv
    |> form("#runbook-import-form", %{
      "import" => %{
        "title" => "Imported readiness",
        "json" => Jason.encode!(definition)
      }
    })
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    assert path =~ ~r{^/app/#{account.slug}/runbooks/[0-9a-f-]+/edit$}
    assert flash["info"] == "Runbook imported as a draft."

    assert {:ok, [runbook], _metadata} =
             Runbooks.list_runbooks(owner_subject(user, account), page: [limit: 10])

    assert runbook.title == "Imported readiness"
    # An import lands as the unpublished change, never as something live.
    assert runbook.live_version == nil
    assert runbook.definition == nil
    assert runbook.draft_definition == definition
  end

  test "uploads or drops one bounded JSON file and derives a useful title", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    encoded = Jason.encode!(Emisar.Fixtures.Runbooks.default_definition())
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/import")

    upload =
      file_input(lv, "#runbook-import-form", :runbook_json, [
        %{
          name: "maintenance-window.json",
          content: encoded,
          size: byte_size(encoded),
          type: "application/json"
        }
      ])

    assert render_upload(upload, "maintenance-window.json") =~ "maintenance-window.json"
    assert has_element?(lv, "#selected-runbook-json", "maintenance-window.json")
    assert has_element?(lv, "#runbook-import-title[value='Maintenance window']")

    lv
    |> form("#runbook-import-form", %{
      "import" => %{"title" => "Maintenance window", "json" => ""}
    })
    |> render_submit()

    assert_redirect(lv)

    assert {:ok, [runbook], _metadata} =
             Runbooks.list_runbooks(owner_subject(user, account), page: [limit: 10])

    assert runbook.title == "Maintenance window"
    assert runbook.live_version == nil
    assert runbook.draft_definition == Fixtures.Runbooks.default_definition()
  end

  test "keeps pasted input and shows actionable inline errors", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/import")

    html =
      lv
      |> form("#runbook-import-form", %{
        "import" => %{"title" => "", "json" => "{"}
      })
      |> render_submit()

    assert html =~ "Title is required."
    assert html =~ "Enter a valid JSON object."
    assert has_element?(lv, "#runbook-import-json", "{")
  end

  test "requires exactly one JSON source", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    encoded = Jason.encode!(Emisar.Fixtures.Runbooks.default_definition())
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/import")

    upload =
      file_input(lv, "#runbook-import-form", :runbook_json, [
        %{
          name: "runbook.json",
          content: encoded,
          size: byte_size(encoded),
          type: "application/json"
        }
      ])

    render_upload(upload, "runbook.json")

    html =
      lv
      |> form("#runbook-import-form", %{
        "import" => %{"title" => "Two sources", "json" => encoded}
      })
      |> render_submit()

    assert html =~ "Use either the selected file or pasted JSON, not both."

    assert {:ok, [], _metadata} =
             Runbooks.list_runbooks(owner_subject(user, account), page: [limit: 10])
  end

  test "rejects crafted non-string form values without crashing", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/import")

    html =
      render_submit(lv, "import_runbook", %{
        "import" => %{"title" => %{"nested" => "value"}, "json" => ["not", "json"]}
      })

    assert html =~ "Title is required."
    assert html =~ "Choose a JSON file or paste the canonical JSON."
  end

  test "rejects oversized and non-JSON file selections", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/import")

    content = String.duplicate("x", Runbooks.definition_limit!(:max_definition_bytes) + 1)

    oversized =
      file_input(lv, "#runbook-import-form", :runbook_json, [
        %{
          name: "large.json",
          content: content,
          size: byte_size(content),
          type: "application/json"
        }
      ])

    assert {:error, _reason} = render_upload(oversized, "large.json")
    assert render(lv) =~ "The JSON file must be 64 KB or smaller."

    html =
      render_submit(lv, "import_runbook", %{
        "import" => %{"title" => "Too large", "json" => content}
      })

    assert html =~ "JSON exceeds the 65536 byte limit."
  end

  test "redirects a viewer and imports nothing", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    viewer = Fixtures.Users.create_user()

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    destination = ~p"/app/#{account}/runbooks"

    assert {:error, {:live_redirect, %{to: ^destination, flash: flash}}} =
             build_conn()
             |> log_in_user(viewer)
             |> live(~p"/app/#{account}/runbooks/import")

    assert flash["error"] =~ "permission"
  end
end
